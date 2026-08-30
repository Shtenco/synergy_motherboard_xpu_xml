// SHTENCO XPU V2.2 — parallel static route emitter.
//
// Each retiring lane may emit up to two consumer tokens in the same cycle.
// The destination operand store provides per-token ready. Any rejected token is
// surfaced as route_stall/fault in this proof fast path; V2.3 will add retry FIFOs.

module xpu_route_emit2 #(
    parameter integer LANES = 8,
    parameter integer NODE_W = 8,
    parameter integer PORTS = LANES * 2
) (
    input  logic [LANES-1:0]             producer_valid,
    input  logic [NODE_W-1:0]            producer_node [0:LANES-1],
    input  logic signed [31:0]           producer_value [0:LANES-1],

    input  logic [1:0]                   route_count [0:LANES-1],
    input  logic [NODE_W-1:0]            route_dst0 [0:LANES-1],
    input  logic                         route_slot0 [0:LANES-1],
    input  logic [NODE_W-1:0]            route_dst1 [0:LANES-1],
    input  logic                         route_slot1 [0:LANES-1],

    output logic [PORTS-1:0]             token_valid,
    output logic [NODE_W-1:0]            token_node [0:PORTS-1],
    output logic                         token_slot [0:PORTS-1],
    output logic signed [31:0]           token_value [0:PORTS-1],
    input  logic [PORTS-1:0]             token_ready,

    output logic                         route_stall,
    output logic [31:0]                  emitted_tokens_this_cycle
);

    integer lane;
    integer p0;
    integer p1;

    always_comb begin
        token_valid = '0;
        route_stall = 1'b0;
        emitted_tokens_this_cycle = 32'd0;
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            p0 = lane * 2;
            p1 = lane * 2 + 1;

            token_node[p0] = route_dst0[lane];
            token_slot[p0] = route_slot0[lane];
            token_value[p0] = producer_value[lane];

            token_node[p1] = route_dst1[lane];
            token_slot[p1] = route_slot1[lane];
            token_value[p1] = producer_value[lane];

            if (producer_valid[lane] && route_count[lane] >= 2'd1) begin
                token_valid[p0] = 1'b1;
                if (token_ready[p0])
                    emitted_tokens_this_cycle = emitted_tokens_this_cycle + 32'd1;
                else
                    route_stall = 1'b1;
            end

            if (producer_valid[lane] && route_count[lane] >= 2'd2) begin
                token_valid[p1] = 1'b1;
                if (token_ready[p1])
                    emitted_tokens_this_cycle = emitted_tokens_this_cycle + 32'd1;
                else
                    route_stall = 1'b1;
            end
        end
    end

endmodule
