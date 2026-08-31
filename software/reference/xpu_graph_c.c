/*
 * SHTENCO XPU V2 — independent C validator/executor for the XPU2 graph binary.
 *
 * Purpose: cross-language conformance. This code intentionally does not share
 * parser or EML interpolation implementation with xpu_graph.py.
 *
 * Host reference only. OpenSSL is used for SHA-256 integrity validation.
 */
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/sha.h>

#define XPU_HEADER_BYTES 32u
#define XPU_NODE_BYTES 16u
#define XPU_DIGEST_BYTES 32u
#define XPU_VERSION 2u
#define XPU_PROFILE_EML_Q16_LUT_V2 1u
#define XPU_LUT_SAMPLES 1025u
#define XPU_LUT_INTERVALS 1024u
#define XPU_STEP_SHIFT 9u
#define XPU_STEP_MASK 511u
#define XPU_A_MIN_RAW (-262144)
#define XPU_A_MAX_RAW 262144
#define XPU_B_MIN_RAW 8192
#define XPU_B_MAX_RAW 532480

#define OP_INPUT 1u
#define OP_CONST_Q16 2u
#define OP_EML 3u

struct xpu_node {
    uint8_t opcode;
    uint8_t flags;
    int32_t arg0;
    int32_t arg1;
    uint32_t aux;
};

struct xpu_graph {
    uint32_t node_count;
    uint32_t input_count;
    uint32_t output_count;
    struct xpu_node *nodes;
    uint32_t *outputs;
};

static uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static int32_t rd_i32(const uint8_t *p)
{
    return (int32_t)rd32(p);
}

static void free_graph(struct xpu_graph *g)
{
    if (g == NULL) {
        return;
    }
    free(g->nodes);
    free(g->outputs);
    memset(g, 0, sizeof(*g));
}

static int read_file(const char *path, uint8_t **out, size_t *out_len)
{
    FILE *f = fopen(path, "rb");
    long n;
    uint8_t *buf;
    if (f == NULL) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }
    if (fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0 ||
        fseek(f, 0, SEEK_SET) != 0) {
        fprintf(stderr, "seek %s failed\n", path);
        fclose(f);
        return -1;
    }
    buf = (uint8_t *)malloc((size_t)n ? (size_t)n : 1u);
    if (buf == NULL) {
        fclose(f);
        return -1;
    }
    if ((size_t)n != 0u && fread(buf, 1u, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "read %s failed\n", path);
        free(buf);
        fclose(f);
        return -1;
    }
    fclose(f);
    *out = buf;
    *out_len = (size_t)n;
    return 0;
}

static int verify_sha256(const uint8_t *blob, size_t len)
{
    uint8_t digest[SHA256_DIGEST_LENGTH];
    if (len < XPU_DIGEST_BYTES) {
        return -1;
    }
    if (SHA256(blob, len - XPU_DIGEST_BYTES, digest) == NULL) {
        return -1;
    }
    return memcmp(digest, blob + len - XPU_DIGEST_BYTES,
                  XPU_DIGEST_BYTES) == 0 ? 0 : -1;
}

static int parse_graph(const uint8_t *blob, size_t len, struct xpu_graph *g)
{
    uint16_t version;
    uint16_t profile;
    uint32_t node_count;
    uint32_t input_count;
    uint32_t output_count;
    uint32_t flags;
    uint32_t node_bytes;
    uint32_t reserved;
    uint64_t payload_expected;
    uint32_t i;
    size_t off;

    memset(g, 0, sizeof(*g));
    if (len < XPU_HEADER_BYTES + XPU_DIGEST_BYTES) {
        fprintf(stderr, "XPU_C_FAIL truncated graph\n");
        return -1;
    }
    if (memcmp(blob, "XPU2", 4u) != 0) {
        fprintf(stderr, "XPU_C_FAIL bad magic\n");
        return -1;
    }
    if (verify_sha256(blob, len) != 0) {
        fprintf(stderr, "XPU_C_FAIL SHA-256 mismatch\n");
        return -1;
    }

    version = rd16(blob + 4u);
    profile = rd16(blob + 6u);
    node_count = rd32(blob + 8u);
    input_count = rd32(blob + 12u);
    output_count = rd32(blob + 16u);
    flags = rd32(blob + 20u);
    node_bytes = rd32(blob + 24u);
    reserved = rd32(blob + 28u);

    if (version != XPU_VERSION || profile != XPU_PROFILE_EML_Q16_LUT_V2 ||
        flags != 0u || node_bytes != XPU_NODE_BYTES || reserved != 0u) {
        fprintf(stderr, "XPU_C_FAIL unsupported header\n");
        return -1;
    }
    if (node_count == 0u || output_count == 0u) {
        fprintf(stderr, "XPU_C_FAIL empty graph/output set\n");
        return -1;
    }

    payload_expected = (uint64_t)XPU_HEADER_BYTES +
                       (uint64_t)node_count * XPU_NODE_BYTES +
                       (uint64_t)output_count * 4u;
    if (payload_expected + XPU_DIGEST_BYTES != (uint64_t)len) {
        fprintf(stderr, "XPU_C_FAIL length/header mismatch\n");
        return -1;
    }

    g->nodes = (struct xpu_node *)calloc(node_count, sizeof(*g->nodes));
    g->outputs = (uint32_t *)calloc(output_count, sizeof(*g->outputs));
    if (g->nodes == NULL || g->outputs == NULL) {
        free_graph(g);
        return -1;
    }
    g->node_count = node_count;
    g->input_count = input_count;
    g->output_count = output_count;

    off = XPU_HEADER_BYTES;
    for (i = 0; i < node_count; ++i, off += XPU_NODE_BYTES) {
        const uint8_t *p = blob + off;
        struct xpu_node *n = &g->nodes[i];
        uint16_t node_reserved = rd16(p + 2u);
        n->opcode = p[0];
        n->flags = p[1];
        n->arg0 = rd_i32(p + 4u);
        n->arg1 = rd_i32(p + 8u);
        n->aux = rd32(p + 12u);

        if (node_reserved != 0u) {
            fprintf(stderr, "XPU_C_FAIL node %" PRIu32 " reserved != 0\n", i);
            free_graph(g);
            return -1;
        }
        if (n->opcode == OP_INPUT) {
            if (n->arg0 < 0 || (uint32_t)n->arg0 >= input_count) {
                fprintf(stderr, "XPU_C_FAIL input node %" PRIu32 " slot\n", i);
                free_graph(g);
                return -1;
            }
        } else if (n->opcode == OP_CONST_Q16) {
            /* Any signed i32 is a valid raw Q16.16 constant. */
        } else if (n->opcode == OP_EML) {
            if (n->arg0 < 0 || n->arg1 < 0 ||
                (uint32_t)n->arg0 >= i || (uint32_t)n->arg1 >= i) {
                fprintf(stderr, "XPU_C_FAIL EML node %" PRIu32 " not topological\n", i);
                free_graph(g);
                return -1;
            }
        } else {
            fprintf(stderr, "XPU_C_FAIL node %" PRIu32 " unknown opcode %u\n",
                    i, (unsigned)n->opcode);
            free_graph(g);
            return -1;
        }
    }

    for (i = 0; i < output_count; ++i, off += 4u) {
        g->outputs[i] = rd32(blob + off);
        if (g->outputs[i] >= node_count) {
            fprintf(stderr, "XPU_C_FAIL output index out of range\n");
            free_graph(g);
            return -1;
        }
    }
    return 0;
}

static int load_memh(const char *path, int32_t table[XPU_LUT_SAMPLES])
{
    FILE *f = fopen(path, "r");
    char line[128];
    uint32_t i = 0;
    if (f == NULL) {
        fprintf(stderr, "open LUT %s: %s\n", path, strerror(errno));
        return -1;
    }
    while (fgets(line, sizeof(line), f) != NULL) {
        char *end = NULL;
        unsigned long raw;
        if (i >= XPU_LUT_SAMPLES) {
            fclose(f);
            return -1;
        }
        errno = 0;
        raw = strtoul(line, &end, 16);
        if (errno != 0 || end == line || raw > UINT32_MAX) {
            fclose(f);
            return -1;
        }
        table[i++] = (int32_t)(uint32_t)raw;
    }
    fclose(f);
    if (i != XPU_LUT_SAMPLES) {
        fprintf(stderr, "LUT %s has %" PRIu32 " rows, expected %u\n",
                path, i, XPU_LUT_SAMPLES);
        return -1;
    }
    return 0;
}

/* Portable floor(x / 512), matching arithmetic right shift used by the RTL. */
static int64_t floor_div_512(int64_t x)
{
    if (x >= 0) {
        return x / 512;
    }
    return -(((-x) + 511) / 512);
}

static int64_t interp_q16(const int32_t table[XPU_LUT_SAMPLES],
                          int32_t raw, int32_t minimum)
{
    int64_t delta = (int64_t)raw - (int64_t)minimum;
    uint32_t index = (uint32_t)(delta >> XPU_STEP_SHIFT);
    uint32_t frac = (uint32_t)delta & XPU_STEP_MASK;
    int64_t y0;
    int64_t y1;
    if (index >= XPU_LUT_INTERVALS) {
        return table[XPU_LUT_INTERVALS];
    }
    y0 = table[index];
    y1 = table[index + 1u];
    return y0 + floor_div_512((y1 - y0) * (int64_t)frac);
}

static int32_t sat_i32(int64_t x)
{
    if (x > INT32_MAX) {
        return INT32_MAX;
    }
    if (x < INT32_MIN) {
        return INT32_MIN;
    }
    return (int32_t)x;
}

static int eml_lut(int32_t a, int32_t b,
                   const int32_t exp_lut[XPU_LUT_SAMPLES],
                   const int32_t ln_lut[XPU_LUT_SAMPLES], int32_t *out)
{
    int64_t e;
    int64_t l;
    if (a < XPU_A_MIN_RAW || a > XPU_A_MAX_RAW ||
        b < XPU_B_MIN_RAW || b > XPU_B_MAX_RAW) {
        return -1;
    }
    e = interp_q16(exp_lut, a, XPU_A_MIN_RAW);
    l = interp_q16(ln_lut, b, XPU_B_MIN_RAW);
    *out = sat_i32(e - l);
    return 0;
}

static int execute_graph(const struct xpu_graph *g, const int32_t *inputs,
                         const int32_t exp_lut[XPU_LUT_SAMPLES],
                         const int32_t ln_lut[XPU_LUT_SAMPLES],
                         int32_t *out_values)
{
    int32_t *values = (int32_t *)calloc(g->node_count, sizeof(*values));
    uint32_t i;
    if (values == NULL) {
        return -1;
    }
    for (i = 0; i < g->node_count; ++i) {
        const struct xpu_node *n = &g->nodes[i];
        if (n->opcode == OP_INPUT) {
            values[i] = inputs[(uint32_t)n->arg0];
        } else if (n->opcode == OP_CONST_Q16) {
            values[i] = n->arg0;
        } else if (n->opcode == OP_EML) {
            if (eml_lut(values[(uint32_t)n->arg0], values[(uint32_t)n->arg1],
                        exp_lut, ln_lut, &values[i]) != 0) {
                fprintf(stderr, "XPU_C_FAIL EML domain at node %" PRIu32 "\n", i);
                free(values);
                return -1;
            }
        }
    }
    for (i = 0; i < g->output_count; ++i) {
        out_values[i] = values[g->outputs[i]];
    }
    free(values);
    return 0;
}

static int parse_i32(const char *s, int32_t *out)
{
    char *end = NULL;
    long long v;
    errno = 0;
    v = strtoll(s, &end, 0);
    if (errno != 0 || end == s || *end != '\0' || v < INT32_MIN || v > INT32_MAX) {
        return -1;
    }
    *out = (int32_t)v;
    return 0;
}

int main(int argc, char **argv)
{
    uint8_t *blob = NULL;
    size_t blob_len = 0;
    struct xpu_graph graph;
    int32_t exp_lut[XPU_LUT_SAMPLES];
    int32_t ln_lut[XPU_LUT_SAMPLES];
    int32_t *inputs = NULL;
    int32_t *outputs = NULL;
    uint32_t i;
    int rc = 1;

    if (argc < 4) {
        fprintf(stderr, "usage: %s graph.xpu exp_q16.memh ln_q16.memh [raw_input ...]\n", argv[0]);
        return 2;
    }
    memset(&graph, 0, sizeof(graph));
    if (read_file(argv[1], &blob, &blob_len) != 0 ||
        load_memh(argv[2], exp_lut) != 0 ||
        load_memh(argv[3], ln_lut) != 0 ||
        parse_graph(blob, blob_len, &graph) != 0) {
        goto out;
    }
    if ((uint32_t)(argc - 4) != graph.input_count) {
        fprintf(stderr, "XPU_C_FAIL expected %" PRIu32 " raw inputs, got %d\n",
                graph.input_count, argc - 4);
        goto out;
    }

    inputs = (int32_t *)calloc(graph.input_count ? graph.input_count : 1u,
                               sizeof(*inputs));
    outputs = (int32_t *)calloc(graph.output_count, sizeof(*outputs));
    if (inputs == NULL || outputs == NULL) {
        goto out;
    }
    for (i = 0; i < graph.input_count; ++i) {
        if (parse_i32(argv[4 + i], &inputs[i]) != 0) {
            fprintf(stderr, "XPU_C_FAIL bad input %" PRIu32 "\n", i);
            goto out;
        }
    }
    if (execute_graph(&graph, inputs, exp_lut, ln_lut, outputs) != 0) {
        goto out;
    }

    printf("XPU_V2_GRAPH_C_PASS bytes=%zu nodes=%" PRIu32 " outputs=",
           blob_len, graph.node_count);
    for (i = 0; i < graph.output_count; ++i) {
        printf("%s%" PRId32, i ? "," : "", outputs[i]);
    }
    putchar('\n');
    rc = 0;

out:
    free(inputs);
    free(outputs);
    free_graph(&graph);
    free(blob);
    return rc;
}
