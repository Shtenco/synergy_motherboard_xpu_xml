// SHTENCO XPU V2.3 — closed-loop static-wavefront EML tile.
//
// Fixed-latency EML nodes are fired from a compiler-generated per-lane schedule.
// Operand destinations are selected by ingress phase tables, so static-path
// values need no runtime route/node tag. There is no ready bitmap and no
// dependency walker in this module.

module xpu_wavefront_tile_v23 #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer PORTS = 24,
    parameter integer BANKS = 32,
    parameter integer SLOTS = 256,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES),
    parameter integer LANE_W = (LANES <= 1) ? 1 : $clog2(LANES),
    parameter integer PORT_W = (PORTS <= 1) ? 1 : $clog2(PORTS),
    parameter integer SLOT_W = (SLOTS <= 1) ? 1 : $clog2(SLOTS),
    parameter EXP_MEMH = "hardware/rtl/generated/exp_q16.memh",
    parameter LN_MEMH  = "hardware/rtl/generated/ln_q16.memh"
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // Per-lane node schedule.
    input  logic                         cfg_sched_we,
    input  logic [LANE_W-1:0]            cfg_sched_lane,
    input  logic [SLOT_W-1:0]            cfg_sched_phase,
    input  logic                         cfg_sched_valid,
    input  logic [NODE_W-1:0]            cfg_sched_node,

    // Phase-addressed ingress destination map.
    input  logic                         cfg_map_we,
    input  logic [PORT_W-1:0]            cfg_map_port,
    input  logic [SLOT_W-1:0]            cfg_map_phase,
    input  logic                         cfg_map_valid,
    input  logic [NODE_W-1:0]            cfg_map_node,
    input  logic                         cfg_map_slot,

    input  logic                         start,
    input  logic                         loop_enable,
    input  logic [SLOT_W-1:0]            period_last,

    // Tagless static-fabric values. Phase selects their destinations.
    input  logic [PORTS-1:0]             fabric_in_valid,
    input  logic signed [31:0]           fabric_in_value [0:PORTS-1],

    // One produced value per arithmetic lane/cycle. External static multicast
    // stages use the current result phase to select precompiled output masks.
    output logic [LANES-1:0]             fabric_out_valid,
    output logic signed [31:0]           fabric_out_value [0:LANES-1],
    output logic [NODE_W-1:0]            fabric_out_node_debug [0:LANES-1],

    output logic                         running,
    output logic [SLOT_W-1:0]            phase,
    output logic                         halted,
    output logic                         fault_missing_operand,
    output logic                         fault_domain,
    output logic                         fault_bank_conflict,
    output logic                         fault_unmapped_data,
    output logic [63:0]                  accepted_input_values,
    output logic [63:0]                  issued_eml_ops
);

    logic [LANES-1:0] issue_valid;
    logic [NODE_W-1:0] issue_node [0:LANES-1];
    logic signed [31:0] operand_a [0:LANES-1];
    logic signed [31:0] operand_b [0:LANES-1];
    logic [LANES-1:0] operand_a_valid;
    logic [LANES-1:0] operand_b_valid;
    logic [LANES-1:0] eml_in_valid;
    logic [LANES-1:0] eml_out_valid;
    logic [LANES-1:0] eml_domain_error;
    logic signed [31:0] eml_y [0:LANES-1];
    logic [NODE_W-1:0] lane_node_q [0:LANES-1];
    logic missing_operand_c;
    integer lane;
    integer issues_c;

    assign halted = fault_missing_operand | fault_domain |
                    fault_bank_conflict | fault_unmapped_data;

    always_comb begin
        missing_operand_c = 1'b0;
        issues_c = 0;
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            if (issue_valid[lane] && (!operand_a_valid[lane] || !operand_b_valid[lane]))
                missing_operand_c = 1'b1;

            eml_in_valid[lane] = issue_valid[lane] &&
                                 operand_a_valid[lane] && operand_b_valid[lane] &&
                                 !halted;

            fabric_out_valid[lane] = eml_out_valid[lane] &&
                                     !eml_domain_error[lane] && !halted;
            fabric_out_value[lane] = eml_y[lane];
            fabric_out_node_debug[lane] = lane_node_q[lane];

            if (eml_in_valid[lane])
                issues_c = issues_c + 1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        if (!rst_n) begin
            fault_missing_operand <= 1'b0;
            fault_domain <= 1'b0;
            issued_eml_ops <= 64'd0;
            for (i = 0; i < LANES; i = i + 1)
                lane_node_q[i] <= '0;
        end else begin
            if (missing_operand_c)
                fault_missing_operand <= 1'b1;

            for (i = 0; i < LANES; i = i + 1) begin
                if (eml_out_valid[i] && eml_domain_error[i])
                    fault_domain <= 1'b1;
                if (eml_in_valid[i])
                    lane_node_q[i] <= issue_node[i];
            end
            issued_eml_ops <= issued_eml_ops + issues_c;
        end
    end

    xpu_wavefront_schedule_v23 #(
        .NODES(NODES), .LANES(LANES), .SLOTS(SLOTS),
        .NODE_W(NODE_W), .LANE_W(LANE_W), .SLOT_W(SLOT_W)
    ) schedule (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_we(cfg_sched_we),
        .cfg_lane(cfg_sched_lane),
        .cfg_slot(cfg_sched_phase),
        .cfg_valid(cfg_sched_valid),
        .cfg_node(cfg_sched_node),
        .start(start),
        .halt(halted),
        .loop_enable(loop_enable),
        .period_last(period_last),
        .running(running),
        .phase(phase),
        .issue_valid(issue_valid),
        .issue_node(issue_node)
    );

    xpu_wavefront_ingress_v23 #(
        .NODES(NODES), .PORTS(PORTS), .BANKS(BANKS), .LANES(LANES),
        .SLOTS(SLOTS), .NODE_W(NODE_W), .PORT_W(PORT_W), .SLOT_W(SLOT_W)
    ) ingress (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_map_we(cfg_map_we),
        .cfg_map_port(cfg_map_port),
        .cfg_map_phase(cfg_map_phase),
        .cfg_map_valid(cfg_map_valid),
        .cfg_map_node(cfg_map_node),
        .cfg_map_slot(cfg_map_slot),
        .phase(phase),
        .data_valid(fabric_in_valid),
        .data_value(fabric_in_value),
        .consume_valid(eml_in_valid),
        .consume_node(issue_node),
        .read_node(issue_node),
        .read_a(operand_a),
        .read_b(operand_b),
        .read_a_valid(operand_a_valid),
        .read_b_valid(operand_b_valid),
        .fault_bank_conflict(fault_bank_conflict),
        .fault_unmapped_data(fault_unmapped_data),
        .accepted_values(accepted_input_values)
    );

    eml_tile #(
        .LANES(LANES), .EXP_MEMH(EXP_MEMH), .LN_MEMH(LN_MEMH)
    ) eml (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(eml_in_valid),
        .a_q16(operand_a),
        .b_q16(operand_b),
        .out_valid(eml_out_valid),
        .out_domain_error(eml_domain_error),
        .y_q16(eml_y)
    );

endmodule
