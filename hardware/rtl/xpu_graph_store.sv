// SHTENCO XPU V2.1 — bounded graph metadata store.
//
// The loader lowers the XPU2 graph binary into per-node metadata before RUN.
// The proof tile currently executes EML nodes; source/constant node values are
// preloaded into the value store and injected as completions by the boot path.

module xpu_graph_store #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES)
) (
    input  logic                         clk,

    input  logic                         cfg_node_we,
    input  logic [NODE_W-1:0]            cfg_node,
    input  logic [7:0]                   cfg_opcode,
    input  logic [NODE_W-1:0]            cfg_src_a,
    input  logic [NODE_W-1:0]            cfg_src_b,

    input  logic [NODE_W-1:0]            read_node [0:LANES-1],
    output logic [7:0]                   read_opcode [0:LANES-1],
    output logic [NODE_W-1:0]            read_src_a [0:LANES-1],
    output logic [NODE_W-1:0]            read_src_b [0:LANES-1]
);

    logic [7:0] opcode_mem [0:NODES-1];
    logic [NODE_W-1:0] src_a_mem [0:NODES-1];
    logic [NODE_W-1:0] src_b_mem [0:NODES-1];
    integer lane;

    always_comb begin
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            read_opcode[lane] = opcode_mem[read_node[lane]];
            read_src_a[lane] = src_a_mem[read_node[lane]];
            read_src_b[lane] = src_b_mem[read_node[lane]];
        end
    end

    always_ff @(posedge clk) begin
        if (cfg_node_we) begin
            opcode_mem[cfg_node] <= cfg_opcode;
            src_a_mem[cfg_node] <= cfg_src_a;
            src_b_mem[cfg_node] <= cfg_src_b;
        end
    end

endmodule
