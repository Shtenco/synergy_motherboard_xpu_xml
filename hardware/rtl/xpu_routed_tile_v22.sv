// SHTENCO XPU V2.2 — routed-token EML tile.
//
// This is the scalable static-DAG direction:
//   initial token / lane result
//     -> two-way compiled route table
//     -> banked operand slots
//     -> parallel ready bitmap
//     -> multi-issue scheduler
//     -> EML lanes
//     -> routed result
//
// There is no central dependency-counter walker in the static fast path.

module xpu_routed_tile_v22 #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer BANKS = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES),
    parameter integer ROUTE_PORTS = LANES * 2,
    parameter integer TOKEN_PORTS = ROUTE_PORTS + 1,
    parameter EXP_MEMH = "hardware/rtl/generated/exp_q16.memh",
    parameter LN_MEMH  = "hardware/rtl/generated/ln_q16.memh"
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // EML node metadata. Source nodes are lowered to initial tokens in .xpur.
    input  logic                         cfg_node_we,
    input  logic [NODE_W-1:0]            cfg_node,
    input  logic [7:0]                   cfg_opcode,

    // Up to two direct static routes per producer.
    input  logic                         cfg_route_we,
    input  logic [NODE_W-1:0]            cfg_route_producer,
    input  logic [1:0]                   cfg_route_count,
    input  logic [NODE_W-1:0]            cfg_route_dst0,
    input  logic                         cfg_route_slot0,
    input  logic [NODE_W-1:0]            cfg_route_dst1,
    input  logic                         cfg_route_slot1,

    // Loader/host injects initial/source tokens one at a time.
    input  logic                         inject_valid,
    input  logic [NODE_W-1:0]            inject_node,
    input  logic                         inject_slot,
    input  logic signed [31:0]           inject_value,
    output logic                         inject_ready,

    input  logic [NODE_W-1:0]            debug_node,
    output logic signed [31:0]           debug_value,

    output logic                         halted,
    output logic                         fault_bad_opcode,
    output logic                         fault_domain,
    output logic                         fault_route_stall,

    output logic [63:0]                  issue_count,
    output logic [63:0]                  lane_idle_cycles,
    output logic [63:0]                  ready_empty_cycles,
    output logic [63:0]                  accepted_tokens,
    output logic [63:0]                  bank_conflict_stalls,
    output logic [63:0]                  ready_events,
    output logic [63:0]                  route_tokens_emitted
);

    localparam logic [7:0] OP_EML = 8'd3;

    logic [LANES-1:0] issue_valid;
    logic [NODE_W-1:0] issue_node [0:LANES-1];
    logic [LANES-1:0] lane_busy;
    logic [NODES-1:0] ready_set_bits;

    logic [7:0] issue_opcode [0:LANES-1];
    logic [NODE_W-1:0] unused_src_a [0:LANES-1];
    logic [NODE_W-1:0] unused_src_b [0:LANES-1];

    logic signed [31:0] operand_a [0:LANES-1];
    logic signed [31:0] operand_b [0:LANES-1];

    logic [LANES-1:0] eml_in_valid;
    logic [LANES-1:0] eml_out_valid;
    logic [LANES-1:0] eml_domain_error;
    logic signed [31:0] eml_y [0:LANES-1];
    logic [NODE_W-1:0] lane_node_q [0:LANES-1];
    logic [LANES-1:0] successful_retire;

    logic [1:0] route_count [0:LANES-1];
    logic [NODE_W-1:0] route_dst0 [0:LANES-1];
    logic route_slot0 [0:LANES-1];
    logic [NODE_W-1:0] route_dst1 [0:LANES-1];
    logic route_slot1 [0:LANES-1];

    logic [ROUTE_PORTS-1:0] route_token_valid;
    logic [NODE_W-1:0] route_token_node [0:ROUTE_PORTS-1];
    logic route_token_slot [0:ROUTE_PORTS-1];
    logic signed [31:0] route_token_value [0:ROUTE_PORTS-1];
    logic [ROUTE_PORTS-1:0] route_token_ready;
    logic route_stall_now;
    logic [31:0] emitted_now;

    logic [TOKEN_PORTS-1:0] operand_token_valid;
    logic [NODE_W-1:0] operand_token_node [0:TOKEN_PORTS-1];
    logic operand_token_slot [0:TOKEN_PORTS-1];
    logic signed [31:0] operand_token_value [0:TOKEN_PORTS-1];
    logic [TOKEN_PORTS-1:0] operand_token_ready;

    integer lane;
    integer port;

    assign halted = fault_bad_opcode | fault_domain | fault_route_stall;
    assign inject_ready = operand_token_ready[TOKEN_PORTS-1];

    always_comb begin
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            eml_in_valid[lane] = issue_valid[lane] &&
                                 (issue_opcode[lane] == OP_EML) && !halted;
            successful_retire[lane] = eml_out_valid[lane] &&
                                      !eml_domain_error[lane] && !halted;
        end

        operand_token_valid = '0;
        for (port = 0; port < ROUTE_PORTS; port = port + 1) begin
            operand_token_valid[port] = route_token_valid[port];
            operand_token_node[port] = route_token_node[port];
            operand_token_slot[port] = route_token_slot[port];
            operand_token_value[port] = route_token_value[port];
            route_token_ready[port] = operand_token_ready[port];
        end

        operand_token_valid[TOKEN_PORTS-1] = inject_valid;
        operand_token_node[TOKEN_PORTS-1] = inject_node;
        operand_token_slot[TOKEN_PORTS-1] = inject_slot;
        operand_token_value[TOKEN_PORTS-1] = inject_value;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        if (!rst_n) begin
            fault_bad_opcode <= 1'b0;
            fault_domain <= 1'b0;
            fault_route_stall <= 1'b0;
            route_tokens_emitted <= 64'd0;
            for (i = 0; i < LANES; i = i + 1)
                lane_node_q[i] <= '0;
        end else begin
            for (i = 0; i < LANES; i = i + 1) begin
                if (issue_valid[i] && issue_opcode[i] != OP_EML)
                    fault_bad_opcode <= 1'b1;
                if (eml_out_valid[i] && eml_domain_error[i])
                    fault_domain <= 1'b1;
                if (eml_in_valid[i])
                    lane_node_q[i] <= issue_node[i];
            end
            if (route_stall_now)
                fault_route_stall <= 1'b1;
            route_tokens_emitted <= route_tokens_emitted + emitted_now;
        end
    end

    xpu_graph_store #(
        .NODES(NODES), .LANES(LANES), .NODE_W(NODE_W)
    ) graph_store (
        .clk(clk),
        .cfg_node_we(cfg_node_we),
        .cfg_node(cfg_node),
        .cfg_opcode(cfg_opcode),
        .cfg_src_a('0),
        .cfg_src_b('0),
        .read_node(issue_node),
        .read_opcode(issue_opcode),
        .read_src_a(unused_src_a),
        .read_src_b(unused_src_b)
    );

    xpu_ready_scheduler #(
        .NODES(NODES), .LANES(LANES), .NODE_W(NODE_W)
    ) scheduler (
        .clk(clk), .rst_n(rst_n), .halt(halted),
        .ready_in_valid(1'b0), .ready_in_node('0),
        .ready_set_bits(ready_set_bits),
        .seed_ready_valid(1'b0), .seed_ready_node('0),
        .lane_done(eml_out_valid),
        .issue_valid(issue_valid), .issue_node(issue_node), .lane_busy(lane_busy),
        .issue_count(issue_count), .lane_idle_cycles(lane_idle_cycles),
        .ready_empty_cycles(ready_empty_cycles)
    );

    xpu_operand_store #(
        .NODES(NODES), .PORTS(TOKEN_PORTS), .LANES(LANES), .BANKS(BANKS), .NODE_W(NODE_W)
    ) operands (
        .clk(clk), .rst_n(rst_n),
        .token_valid(operand_token_valid),
        .token_node(operand_token_node),
        .token_slot(operand_token_slot),
        .token_value(operand_token_value),
        .token_ready(operand_token_ready),
        .ready_set_bits(ready_set_bits),
        .consume_valid(eml_in_valid),
        .consume_node(issue_node),
        .read_node(issue_node),
        .read_a(operand_a), .read_b(operand_b),
        .accepted_tokens(accepted_tokens),
        .bank_conflict_stalls(bank_conflict_stalls),
        .ready_events(ready_events)
    );

    eml_tile #(
        .LANES(LANES), .EXP_MEMH(EXP_MEMH), .LN_MEMH(LN_MEMH)
    ) eml (
        .clk(clk), .rst_n(rst_n),
        .in_valid(eml_in_valid), .a_q16(operand_a), .b_q16(operand_b),
        .out_valid(eml_out_valid), .out_domain_error(eml_domain_error), .y_q16(eml_y)
    );

    xpu_result_store #(
        .NODES(NODES), .LANES(LANES), .NODE_W(NODE_W)
    ) results (
        .clk(clk), .rst_n(rst_n),
        .write_valid(successful_retire), .write_node(lane_node_q), .write_value(eml_y),
        .debug_node(debug_node), .debug_value(debug_value)
    );

    xpu_route_table2 #(
        .NODES(NODES), .LANES(LANES), .NODE_W(NODE_W)
    ) routes (
        .clk(clk),
        .cfg_we(cfg_route_we), .cfg_producer(cfg_route_producer),
        .cfg_count(cfg_route_count), .cfg_dst0(cfg_route_dst0), .cfg_slot0(cfg_route_slot0),
        .cfg_dst1(cfg_route_dst1), .cfg_slot1(cfg_route_slot1),
        .producer_node(lane_node_q),
        .route_count(route_count), .route_dst0(route_dst0), .route_slot0(route_slot0),
        .route_dst1(route_dst1), .route_slot1(route_slot1)
    );

    xpu_route_emit2 #(
        .LANES(LANES), .NODE_W(NODE_W), .PORTS(ROUTE_PORTS)
    ) route_emit (
        .producer_valid(successful_retire), .producer_node(lane_node_q), .producer_value(eml_y),
        .route_count(route_count), .route_dst0(route_dst0), .route_slot0(route_slot0),
        .route_dst1(route_dst1), .route_slot1(route_slot1),
        .token_valid(route_token_valid), .token_node(route_token_node),
        .token_slot(route_token_slot), .token_value(route_token_value),
        .token_ready(route_token_ready), .route_stall(route_stall_now),
        .emitted_tokens_this_cycle(emitted_now)
    );

endmodule
