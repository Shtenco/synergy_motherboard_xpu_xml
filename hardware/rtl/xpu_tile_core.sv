// SHTENCO XPU V2.1 — first closed-loop bounded EML dataflow tile.
//
// Loader phase:
//   - program graph metadata, pending dependency counts and outgoing edges
//   - preload INPUT/CONST node values
//   - inject source nodes with seed_complete_valid
//
// Run phase:
//   completion -> dependency walker -> ready scheduler -> graph/value lookup
//   -> EML lanes -> value retire -> completion
//
// The design intentionally keeps all tables bounded and externally visible.
// It is a proof architecture, not the final high-throughput SRAM/NoC topology.

module xpu_tile_core #(
    parameter integer NODES = 256,
    parameter integer EDGES = 1024,
    parameter integer LANES = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES),
    parameter integer EDGE_W = (EDGES <= 1) ? 1 : $clog2(EDGES),
    parameter integer DEP_W = 8,
    parameter integer COUNT_W = (EDGES <= 1) ? 1 : $clog2(EDGES + 1),
    parameter EXP_MEMH = "hardware/rtl/generated/exp_q16.memh",
    parameter LN_MEMH  = "hardware/rtl/generated/ln_q16.memh"
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // Graph metadata loader.
    input  logic                         cfg_node_we,
    input  logic [NODE_W-1:0]            cfg_node,
    input  logic [7:0]                   cfg_opcode,
    input  logic [NODE_W-1:0]            cfg_src_a,
    input  logic [NODE_W-1:0]            cfg_src_b,

    // Initial source/constant value loader.
    input  logic                         cfg_value_we,
    input  logic [NODE_W-1:0]            cfg_value_node,
    input  logic signed [31:0]           cfg_value,

    // Dependency/edge loader.
    input  logic                         cfg_pending_we,
    input  logic [NODE_W-1:0]            cfg_pending_node,
    input  logic [DEP_W-1:0]             cfg_pending_value,
    input  logic                         cfg_node_edges_we,
    input  logic [NODE_W-1:0]            cfg_node_edges_node,
    input  logic [EDGE_W-1:0]            cfg_edge_start,
    input  logic [COUNT_W-1:0]           cfg_edge_count,
    input  logic                         cfg_edge_we,
    input  logic [EDGE_W-1:0]            cfg_edge_index,
    input  logic [NODE_W-1:0]            cfg_edge_dst,

    // Source/constant nodes become complete after their value is loaded.
    input  logic                         seed_complete_valid,
    input  logic [NODE_W-1:0]            seed_complete_node,

    // Host/debug observation of value state.
    input  logic [NODE_W-1:0]            debug_node,
    output logic signed [31:0]           debug_value,

    output logic                         halted,
    output logic                         fault_bad_opcode,
    output logic                         fault_domain,
    output logic                         fault_dependency_underflow,

    output logic [63:0]                  issue_count,
    output logic [63:0]                  lane_idle_cycles,
    output logic [63:0]                  ready_empty_cycles,
    output logic [63:0]                  accepted_completions,
    output logic [63:0]                  dependency_backpressure_cycles,
    output logic [63:0]                  edges_released,
    output logic [63:0]                  ready_nodes_emitted,
    output logic [63:0]                  ready_backpressure_cycles
);

    localparam logic [7:0] OP_EML = 8'd3;

    logic dep_ready_valid;
    logic [NODE_W-1:0] dep_ready_node;

    logic [LANES-1:0] issue_valid;
    logic [NODE_W-1:0] issue_node [0:LANES-1];
    logic [LANES-1:0] lane_busy;

    logic [7:0] issue_opcode [0:LANES-1];
    logic [NODE_W-1:0] issue_src_a [0:LANES-1];
    logic [NODE_W-1:0] issue_src_b [0:LANES-1];

    logic signed [31:0] operand_a [0:LANES-1];
    logic signed [31:0] operand_b [0:LANES-1];

    logic [LANES-1:0] eml_in_valid;
    logic [LANES-1:0] eml_out_valid;
    logic [LANES-1:0] eml_domain_error;
    logic signed [31:0] eml_y [0:LANES-1];
    logic [NODE_W-1:0] lane_node_q [0:LANES-1];

    logic [LANES-1:0] successful_retire;

    logic completion_valid;
    logic [NODE_W-1:0] completion_node;
    logic completion_ready;

    integer lane;

    assign halted = fault_bad_opcode | fault_domain | fault_dependency_underflow;

    always_comb begin
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            eml_in_valid[lane] = issue_valid[lane] && (issue_opcode[lane] == OP_EML) && !halted;
            successful_retire[lane] = eml_out_valid[lane] && !eml_domain_error[lane];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        if (!rst_n) begin
            fault_bad_opcode <= 1'b0;
            fault_domain <= 1'b0;
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
        end
    end

    xpu_graph_store #(
        .NODES(NODES), .LANES(LANES), .NODE_W(NODE_W)
    ) graph_store (
        .clk(clk),
        .cfg_node_we(cfg_node_we),
        .cfg_node(cfg_node),
        .cfg_opcode(cfg_opcode),
        .cfg_src_a(cfg_src_a),
        .cfg_src_b(cfg_src_b),
        .read_node(issue_node),
        .read_opcode(issue_opcode),
        .read_src_a(issue_src_a),
        .read_src_b(issue_src_b)
    );

    xpu_value_store #(
        .NODES(NODES), .LANES(LANES), .NODE_W(NODE_W)
    ) value_store (
        .clk(clk),
        .rst_n(rst_n),
        .loader_we(cfg_value_we),
        .loader_node(cfg_value_node),
        .loader_value(cfg_value),
        .retire_valid(successful_retire),
        .retire_node(lane_node_q),
        .retire_value(eml_y),
        .read_a_node(issue_src_a),
        .read_b_node(issue_src_b),
        .read_a_value(operand_a),
        .read_b_value(operand_b),
        .debug_node(debug_node),
        .debug_value(debug_value)
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

    xpu_completion_bitmap #(
        .NODES(NODES), .LANES(LANES), .NODE_W(NODE_W)
    ) completions (
        .clk(clk),
        .rst_n(rst_n),
        .lane_done(successful_retire),
        .lane_done_node(lane_node_q),
        .seed_complete_valid(seed_complete_valid),
        .seed_complete_node(seed_complete_node),
        .complete_valid(completion_valid),
        .complete_node(completion_node),
        .complete_ready(completion_ready),
        .accepted_completions(accepted_completions),
        .dependency_backpressure_cycles(dependency_backpressure_cycles)
    );

    xpu_dependency_engine #(
        .NODES(NODES), .EDGES(EDGES), .NODE_W(NODE_W), .EDGE_W(EDGE_W),
        .DEP_W(DEP_W), .COUNT_W(COUNT_W)
    ) deps (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_pending_we(cfg_pending_we),
        .cfg_pending_node(cfg_pending_node),
        .cfg_pending_value(cfg_pending_value),
        .cfg_node_edges_we(cfg_node_edges_we),
        .cfg_node_edges_node(cfg_node_edges_node),
        .cfg_edge_start(cfg_edge_start),
        .cfg_edge_count(cfg_edge_count),
        .cfg_edge_we(cfg_edge_we),
        .cfg_edge_index(cfg_edge_index),
        .cfg_edge_dst(cfg_edge_dst),
        .complete_valid(completion_valid),
        .complete_node(completion_node),
        .complete_ready(completion_ready),
        .ready_out_valid(dep_ready_valid),
        .ready_out_node(dep_ready_node),
        .ready_out_ready(1'b1),
        .fault_underflow(fault_dependency_underflow),
        .edges_released(edges_released),
        .ready_nodes_emitted(ready_nodes_emitted),
        .ready_backpressure_cycles(ready_backpressure_cycles)
    );

    xpu_ready_scheduler #(
        .NODES(NODES), .LANES(LANES), .NODE_W(NODE_W)
    ) scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .halt(halted),
        .ready_in_valid(dep_ready_valid),
        .ready_in_node(dep_ready_node),
        .seed_ready_valid(1'b0),
        .seed_ready_node('0),
        // Domain-error lanes are freed, but their node is NOT sent to the
        // completion accumulator, so dependents remain blocked fail-closed.
        .lane_done(eml_out_valid),
        .issue_valid(issue_valid),
        .issue_node(issue_node),
        .lane_busy(lane_busy),
        .issue_count(issue_count),
        .lane_idle_cycles(lane_idle_cycles),
        .ready_empty_cycles(ready_empty_cycles)
    );

endmodule
