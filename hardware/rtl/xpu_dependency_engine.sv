// SHTENCO XPU V2.1 — bounded dependency engine proof RTL.
//
// Graph loader programs:
//   pending_count[node]      initial unresolved dependencies
//   edge_start[node]         first outgoing edge in edge_dst[]
//   edge_count[node]         number of outgoing edges
//   edge_dst[edge]           destination node
//
// A completed node is accepted when the engine is idle. Outgoing edges are
// walked one per cycle. When a destination's pending count transitions 1 -> 0,
// that destination is emitted on ready_out.
//
// This scalar edge walker is intentionally a correctness/reference block. It is
// expected to become a bottleneck in wide tiles; V2.2 should bank/replicate it.

module xpu_dependency_engine #(
    parameter integer NODES = 256,
    parameter integer EDGES = 1024,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES),
    parameter integer EDGE_W = (EDGES <= 1) ? 1 : $clog2(EDGES),
    parameter integer DEP_W = 8,
    parameter integer COUNT_W = (EDGES <= 1) ? 1 : $clog2(EDGES + 1)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // Loader/configuration ports; only use while the graph is quiescent.
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

    // One completed node at a time from the completion accumulator.
    input  logic                         complete_valid,
    input  logic [NODE_W-1:0]            complete_node,
    output logic                         complete_ready,

    // A destination whose final dependency was released.
    output logic                         ready_out_valid,
    output logic [NODE_W-1:0]            ready_out_node,
    input  logic                         ready_out_ready,

    output logic                         fault_underflow,
    output logic [63:0]                  edges_released,
    output logic [63:0]                  ready_nodes_emitted,
    output logic [63:0]                  ready_backpressure_cycles
);

    logic [DEP_W-1:0] pending_count [0:NODES-1];
    logic [EDGE_W-1:0] edge_start [0:NODES-1];
    logic [COUNT_W-1:0] edge_count [0:NODES-1];
    logic [NODE_W-1:0] edge_dst [0:EDGES-1];

    logic walk_active;
    logic [EDGE_W-1:0] walk_pos;
    logic [COUNT_W-1:0] walk_left;
    logic ready_hold_valid;
    logic [NODE_W-1:0] ready_hold_node;

    assign complete_ready = !walk_active && !ready_hold_valid;
    assign ready_out_valid = ready_hold_valid;
    assign ready_out_node = ready_hold_node;

    always_ff @(posedge clk or negedge rst_n) begin
        logic [NODE_W-1:0] dst;
        logic [DEP_W-1:0] before;
        if (!rst_n) begin
            walk_active               <= 1'b0;
            walk_pos                  <= '0;
            walk_left                 <= '0;
            ready_hold_valid          <= 1'b0;
            ready_hold_node           <= '0;
            fault_underflow           <= 1'b0;
            edges_released            <= 64'd0;
            ready_nodes_emitted       <= 64'd0;
            ready_backpressure_cycles <= 64'd0;
        end else begin
            // Configuration is deliberately simple and fail-obvious. Runtime
            // software must not write graph tables after execution starts.
            if (cfg_pending_we)
                pending_count[cfg_pending_node] <= cfg_pending_value;
            if (cfg_node_edges_we) begin
                edge_start[cfg_node_edges_node] <= cfg_edge_start;
                edge_count[cfg_node_edges_node] <= cfg_edge_count;
            end
            if (cfg_edge_we)
                edge_dst[cfg_edge_index] <= cfg_edge_dst;

            if (ready_hold_valid) begin
                if (ready_out_ready) begin
                    ready_hold_valid <= 1'b0;
                    ready_nodes_emitted <= ready_nodes_emitted + 64'd1;
                end else begin
                    ready_backpressure_cycles <= ready_backpressure_cycles + 64'd1;
                end
            end else if (walk_active) begin
                dst = edge_dst[walk_pos];
                before = pending_count[dst];
                if (before == {DEP_W{1'b0}}) begin
                    fault_underflow <= 1'b1;
                end else begin
                    pending_count[dst] <= before - {{(DEP_W-1){1'b0}}, 1'b1};
                    edges_released <= edges_released + 64'd1;
                    if (before == {{(DEP_W-1){1'b0}}, 1'b1}) begin
                        ready_hold_valid <= 1'b1;
                        ready_hold_node <= dst;
                    end
                end

                walk_pos <= walk_pos + {{(EDGE_W-1){1'b0}}, 1'b1};
                if (walk_left == {{(COUNT_W-1){1'b0}}, 1'b1}) begin
                    walk_left <= '0;
                    walk_active <= 1'b0;
                end else begin
                    walk_left <= walk_left - {{(COUNT_W-1){1'b0}}, 1'b1};
                end
            end else if (complete_valid) begin
                walk_pos <= edge_start[complete_node];
                walk_left <= edge_count[complete_node];
                if (edge_count[complete_node] != {COUNT_W{1'b0}})
                    walk_active <= 1'b1;
            end
        end
    end

endmodule
