// SHTENCO XPU V2.3 — time-triggered per-lane wavefront schedule.
//
// No dependency walker and no runtime ready search. The compiler writes a
// local node-id sequence for every lane. At phase t the configured node either
// fires or the slot is a compile-time bubble.

module xpu_wavefront_schedule_v23 #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer SLOTS = 256,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES),
    parameter integer LANE_W = (LANES <= 1) ? 1 : $clog2(LANES),
    parameter integer SLOT_W = (SLOTS <= 1) ? 1 : $clog2(SLOTS)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         cfg_we,
    input  logic [LANE_W-1:0]            cfg_lane,
    input  logic [SLOT_W-1:0]            cfg_slot,
    input  logic                         cfg_valid,
    input  logic [NODE_W-1:0]            cfg_node,

    input  logic                         start,
    input  logic                         halt,
    input  logic                         loop_enable,
    input  logic [SLOT_W-1:0]            period_last,

    output logic                         running,
    output logic [SLOT_W-1:0]            phase,
    output logic [LANES-1:0]             issue_valid,
    output logic [NODE_W-1:0]            issue_node [0:LANES-1]
);

    logic sched_valid [0:LANES-1][0:SLOTS-1];
    logic [NODE_W-1:0] sched_node [0:LANES-1][0:SLOTS-1];
    integer lane;

    always_comb begin
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            issue_valid[lane] = running && !halt && sched_valid[lane][phase];
            issue_node[lane] = sched_node[lane][phase];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0;
            phase <= '0;
        end else begin
            if (cfg_we) begin
                sched_valid[cfg_lane][cfg_slot] <= cfg_valid;
                sched_node[cfg_lane][cfg_slot] <= cfg_node;
            end

            if (start) begin
                running <= 1'b1;
                phase <= '0;
            end else if (running && !halt) begin
                if (phase == period_last) begin
                    if (loop_enable)
                        phase <= '0;
                    else begin
                        running <= 1'b0;
                        phase <= phase;
                    end
                end else begin
                    phase <= phase + {{(SLOT_W-1){1'b0}}, 1'b1};
                end
            end
        end
    end

endmodule
