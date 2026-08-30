// SHTENCO XPU V2.1 — completion accumulator.
//
// Multiple lanes may complete in one cycle. A flat bitmap absorbs those events
// and exposes one node completion at a time to the scalar dependency walker.
// This deliberately decouples arithmetic completion bandwidth from the first
// bounded dependency-engine implementation.

module xpu_completion_bitmap #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic [LANES-1:0]             lane_done,
    input  logic [NODE_W-1:0]            lane_done_node [0:LANES-1],

    output logic                         complete_valid,
    output logic [NODE_W-1:0]            complete_node,
    input  logic                         complete_ready,

    output logic [63:0]                  accepted_lane_completions,
    output logic [63:0]                  dependency_backpressure_cycles
);

    logic [NODES-1:0] pending_bits;
    logic found;
    integer n;
    integer lane;
    integer accepts_this_cycle;

    always_comb begin
        complete_valid = 1'b0;
        complete_node = '0;
        found = 1'b0;
        for (n = 0; n < NODES; n = n + 1) begin
            if (!found && pending_bits[n]) begin
                complete_valid = 1'b1;
                complete_node = n[NODE_W-1:0];
                found = 1'b1;
            end
        end

        accepts_this_cycle = 0;
        for (lane = 0; lane < LANES; lane = lane + 1)
            if (lane_done[lane])
                accepts_this_cycle = accepts_this_cycle + 1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        logic [NODES-1:0] next_pending;
        if (!rst_n) begin
            pending_bits                   <= '0;
            accepted_lane_completions      <= 64'd0;
            dependency_backpressure_cycles <= 64'd0;
        end else begin
            next_pending = pending_bits;
            if (complete_valid && complete_ready)
                next_pending[complete_node] = 1'b0;
            for (i = 0; i < LANES; i = i + 1)
                if (lane_done[i])
                    next_pending[lane_done_node[i]] = 1'b1;
            pending_bits <= next_pending;

            accepted_lane_completions <= accepted_lane_completions + accepts_this_cycle;
            if (complete_valid && !complete_ready)
                dependency_backpressure_cycles <= dependency_backpressure_cycles + 64'd1;
        end
    end

endmodule
