// SHTENCO XPU V2.2 — bounded ready-node scheduler proof RTL.
//
// Supports both:
// - scalar ready_in from the V2.1 dependency reference path;
// - parallel ready_set_bits from V2.2 operand banks.
//
// Up to LANES ready nodes can issue per cycle. lane_done allows same-cycle
// retire+reissue. halt stops new issues without destroying scheduler state.

module xpu_ready_scheduler #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         halt,

    input  logic                         ready_in_valid,
    input  logic [NODE_W-1:0]            ready_in_node,
    input  logic [NODES-1:0]             ready_set_bits,

    input  logic                         seed_ready_valid,
    input  logic [NODE_W-1:0]            seed_ready_node,

    input  logic [LANES-1:0]             lane_done,

    output logic [LANES-1:0]             issue_valid,
    output logic [NODE_W-1:0]            issue_node [0:LANES-1],
    output logic [LANES-1:0]             lane_busy,

    output logic [63:0]                  issue_count,
    output logic [63:0]                  lane_idle_cycles,
    output logic [63:0]                  ready_empty_cycles
);

    logic [NODES-1:0] ready_bits;
    logic [NODES-1:0] selected_bits;
    logic [LANES-1:0] busy_q;
    logic [NODES-1:0] scan_bits;
    integer lane;
    integer node;
    logic found;
    logic any_ready;
    logic any_available_lane;
    integer issues_this_cycle;
    integer idle_lanes_this_cycle;

    assign lane_busy = busy_q;

    always_comb begin
        issue_valid = '0;
        selected_bits = '0;
        scan_bits = ready_bits;
        issues_this_cycle = 0;
        idle_lanes_this_cycle = 0;

        for (lane = 0; lane < LANES; lane = lane + 1) begin
            issue_node[lane] = '0;
            found = 1'b0;
            if (!halt && (!busy_q[lane] || lane_done[lane])) begin
                for (node = 0; node < NODES; node = node + 1) begin
                    if (!found && scan_bits[node]) begin
                        issue_valid[lane] = 1'b1;
                        issue_node[lane] = node[NODE_W-1:0];
                        selected_bits[node] = 1'b1;
                        scan_bits[node] = 1'b0;
                        found = 1'b1;
                        issues_this_cycle = issues_this_cycle + 1;
                    end
                end
                if (!found)
                    idle_lanes_this_cycle = idle_lanes_this_cycle + 1;
            end
        end

        any_ready = |ready_bits;
        any_available_lane = !halt && |((~busy_q) | lane_done);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        logic [NODES-1:0] next_ready;
        logic [LANES-1:0] next_busy;
        if (!rst_n) begin
            ready_bits         <= '0;
            busy_q             <= '0;
            issue_count        <= 64'd0;
            lane_idle_cycles   <= 64'd0;
            ready_empty_cycles <= 64'd0;
        end else begin
            next_ready = (ready_bits & ~selected_bits) | ready_set_bits;
            if (ready_in_valid)
                next_ready[ready_in_node] = 1'b1;
            if (seed_ready_valid)
                next_ready[seed_ready_node] = 1'b1;
            ready_bits <= next_ready;

            next_busy = busy_q;
            for (i = 0; i < LANES; i = i + 1) begin
                if (lane_done[i])
                    next_busy[i] = 1'b0;
                if (issue_valid[i])
                    next_busy[i] = 1'b1;
            end
            busy_q <= next_busy;

            issue_count <= issue_count + issues_this_cycle;
            lane_idle_cycles <= lane_idle_cycles + idle_lanes_this_cycle;
            if (any_available_lane && !any_ready)
                ready_empty_cycles <= ready_empty_cycles + 64'd1;
        end
    end

endmodule
