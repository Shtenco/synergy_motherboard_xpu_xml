// SHTENCO XPU V2.1 — bounded ready-node scheduler proof RTL.
//
// - NODES is intentionally small enough for a ready bitmap in the FPGA proof.
// - Up to LANES ready nodes can issue per cycle to currently idle lanes.
// - Incoming ready notifications set bits; issued nodes clear bits.
// - Lane completion clears the corresponding busy bit.
//
// A production scheduler will replace the flat bitmap with hierarchical/banked
// queues, priorities and work stealing. This module freezes the first observable
// issue contract and counters.

module xpu_ready_scheduler #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // A node whose dependency count reached zero.
    input  logic                         ready_in_valid,
    input  logic [NODE_W-1:0]            ready_in_node,

    // Optional direct loader path for source/constant nodes.
    input  logic                         seed_ready_valid,
    input  logic [NODE_W-1:0]            seed_ready_node,

    // Arithmetic/control lanes report completion independently.
    input  logic [LANES-1:0]             lane_done,

    // Issue interface. Node ids are stable for the full cycle when valid.
    output logic [LANES-1:0]             issue_valid,
    output logic [NODE_W-1:0]            issue_node [0:LANES-1],
    output logic [LANES-1:0]             lane_busy,

    // Proof counters for future FPGA performance attribution.
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
    logic any_idle;
    integer issues_this_cycle;
    integer idle_lanes_this_cycle;

    assign lane_busy = busy_q;

    always_comb begin
        issue_valid = '0;
        selected_bits = '0;
        scan_bits = ready_bits;
        issues_this_cycle = 0;
        idle_lanes_this_cycle = 0;

        // New ready events are visible on the following cycle. This keeps the
        // contract deterministic and avoids a combinational path through the
        // dependency engine into lane operand selection.
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            issue_node[lane] = '0;
            found = 1'b0;
            if (!busy_q[lane]) begin
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
        any_idle = |(~busy_q);
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
            next_ready = ready_bits & ~selected_bits;
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
            if (any_idle && !any_ready)
                ready_empty_cycles <= ready_empty_cycles + 64'd1;
        end
    end

endmodule
