`timescale 1ns/1ps

module tb_xpu_tile_core;
    localparam integer NODES = 16;
    localparam integer EDGES = 16;
    localparam integer LANES = 2;
    localparam integer NODE_W = 4;
    localparam integer EDGE_W = 4;
    localparam integer DEP_W = 4;
    localparam integer COUNT_W = 5;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic cfg_node_we;
    logic [NODE_W-1:0] cfg_node;
    logic [7:0] cfg_opcode;
    logic [NODE_W-1:0] cfg_src_a, cfg_src_b;

    logic cfg_value_we;
    logic [NODE_W-1:0] cfg_value_node;
    logic signed [31:0] cfg_value;

    logic cfg_pending_we;
    logic [NODE_W-1:0] cfg_pending_node;
    logic [DEP_W-1:0] cfg_pending_value;
    logic cfg_node_edges_we;
    logic [NODE_W-1:0] cfg_node_edges_node;
    logic [EDGE_W-1:0] cfg_edge_start;
    logic [COUNT_W-1:0] cfg_edge_count;
    logic cfg_edge_we;
    logic [EDGE_W-1:0] cfg_edge_index;
    logic [NODE_W-1:0] cfg_edge_dst;

    logic seed_complete_valid;
    logic [NODE_W-1:0] seed_complete_node;

    logic [NODE_W-1:0] debug_node;
    logic signed [31:0] debug_value;
    logic halted;
    logic fault_bad_opcode, fault_domain, fault_dependency_underflow;
    logic [63:0] issue_count, lane_idle_cycles, ready_empty_cycles;
    logic [63:0] accepted_completions, dependency_backpressure_cycles;
    logic [63:0] edges_released, ready_nodes_emitted, ready_backpressure_cycles;

    always #5 clk = ~clk;

    xpu_tile_core #(
        .NODES(NODES), .EDGES(EDGES), .LANES(LANES),
        .NODE_W(NODE_W), .EDGE_W(EDGE_W), .DEP_W(DEP_W), .COUNT_W(COUNT_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_node_we(cfg_node_we), .cfg_node(cfg_node), .cfg_opcode(cfg_opcode),
        .cfg_src_a(cfg_src_a), .cfg_src_b(cfg_src_b),
        .cfg_value_we(cfg_value_we), .cfg_value_node(cfg_value_node), .cfg_value(cfg_value),
        .cfg_pending_we(cfg_pending_we), .cfg_pending_node(cfg_pending_node),
        .cfg_pending_value(cfg_pending_value),
        .cfg_node_edges_we(cfg_node_edges_we), .cfg_node_edges_node(cfg_node_edges_node),
        .cfg_edge_start(cfg_edge_start), .cfg_edge_count(cfg_edge_count),
        .cfg_edge_we(cfg_edge_we), .cfg_edge_index(cfg_edge_index), .cfg_edge_dst(cfg_edge_dst),
        .seed_complete_valid(seed_complete_valid), .seed_complete_node(seed_complete_node),
        .debug_node(debug_node), .debug_value(debug_value),
        .halted(halted), .fault_bad_opcode(fault_bad_opcode), .fault_domain(fault_domain),
        .fault_dependency_underflow(fault_dependency_underflow),
        .issue_count(issue_count), .lane_idle_cycles(lane_idle_cycles),
        .ready_empty_cycles(ready_empty_cycles), .accepted_completions(accepted_completions),
        .dependency_backpressure_cycles(dependency_backpressure_cycles),
        .edges_released(edges_released), .ready_nodes_emitted(ready_nodes_emitted),
        .ready_backpressure_cycles(ready_backpressure_cycles)
    );

    task automatic write_node(input [NODE_W-1:0] n, input [7:0] op,
                              input [NODE_W-1:0] a, input [NODE_W-1:0] b);
        begin
            @(negedge clk);
            cfg_node = n; cfg_opcode = op; cfg_src_a = a; cfg_src_b = b; cfg_node_we = 1'b1;
            @(negedge clk); cfg_node_we = 1'b0;
        end
    endtask

    task automatic write_value(input [NODE_W-1:0] n, input signed [31:0] v);
        begin
            @(negedge clk);
            cfg_value_node = n; cfg_value = v; cfg_value_we = 1'b1;
            @(negedge clk); cfg_value_we = 1'b0;
        end
    endtask

    task automatic write_pending(input [NODE_W-1:0] n, input [DEP_W-1:0] v);
        begin
            @(negedge clk);
            cfg_pending_node = n; cfg_pending_value = v; cfg_pending_we = 1'b1;
            @(negedge clk); cfg_pending_we = 1'b0;
        end
    endtask

    task automatic write_node_edges(input [NODE_W-1:0] n,
                                    input [EDGE_W-1:0] start,
                                    input [COUNT_W-1:0] count);
        begin
            @(negedge clk);
            cfg_node_edges_node = n; cfg_edge_start = start; cfg_edge_count = count;
            cfg_node_edges_we = 1'b1;
            @(negedge clk); cfg_node_edges_we = 1'b0;
        end
    endtask

    task automatic write_edge(input [EDGE_W-1:0] idx, input [NODE_W-1:0] dst);
        begin
            @(negedge clk);
            cfg_edge_index = idx; cfg_edge_dst = dst; cfg_edge_we = 1'b1;
            @(negedge clk); cfg_edge_we = 1'b0;
        end
    endtask

    task automatic seed_complete(input [NODE_W-1:0] n);
        begin
            @(negedge clk);
            seed_complete_node = n; seed_complete_valid = 1'b1;
            @(negedge clk); seed_complete_valid = 1'b0;
        end
    endtask

    initial begin
        cfg_node_we = 0; cfg_value_we = 0; cfg_pending_we = 0;
        cfg_node_edges_we = 0; cfg_edge_we = 0; seed_complete_valid = 0;
        cfg_node = 0; cfg_opcode = 0; cfg_src_a = 0; cfg_src_b = 0;
        cfg_value_node = 0; cfg_value = 0;
        cfg_pending_node = 0; cfg_pending_value = 0;
        cfg_node_edges_node = 0; cfg_edge_start = 0; cfg_edge_count = 0;
        cfg_edge_index = 0; cfg_edge_dst = 0; seed_complete_node = 0;
        debug_node = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Demo graph mirrors software/reference/xpu_graph.py:
        // node0 = x=.25; node1 = b=1.5; node2 = const 1
        // node3 = EML(0,1); node4 = EML(3,2)
        write_node(4'd3, 8'd3, 4'd0, 4'd1);
        write_node(4'd4, 8'd3, 4'd3, 4'd2);

        write_value(4'd0, 32'sd16384);
        write_value(4'd1, 32'sd98304);
        write_value(4'd2, 32'sd65536);

        write_pending(4'd0, 4'd0);
        write_pending(4'd1, 4'd0);
        write_pending(4'd2, 4'd0);
        write_pending(4'd3, 4'd2);
        write_pending(4'd4, 4'd2);

        write_node_edges(4'd0, 4'd0, 5'd1);
        write_node_edges(4'd1, 4'd1, 5'd1);
        write_node_edges(4'd2, 4'd2, 5'd1);
        write_node_edges(4'd3, 4'd3, 5'd1);
        write_node_edges(4'd4, 4'd4, 5'd0);

        write_edge(4'd0, 4'd3);
        write_edge(4'd1, 4'd3);
        write_edge(4'd2, 4'd4);
        write_edge(4'd3, 4'd4);

        seed_complete(4'd0);
        seed_complete(4'd1);
        seed_complete(4'd2);

        repeat (100) @(negedge clk);

        if (halted || fault_bad_opcode || fault_domain || fault_dependency_underflow) begin
            $display("XPU_V21_TILE_FAIL fault halted=%0d badop=%0d domain=%0d dep=%0d",
                     halted, fault_bad_opcode, fault_domain, fault_dependency_underflow);
            $fatal(1);
        end

        debug_node = 4'd3;
        #1;
        if (debug_value !== 32'sd57577) begin
            $display("XPU_V21_TILE_FAIL node3 got=%0d expected=57577", debug_value);
            $fatal(1);
        end

        debug_node = 4'd4;
        #1;
        if (debug_value !== 32'sd157774) begin
            $display("XPU_V21_TILE_FAIL node4 got=%0d expected=157774", debug_value);
            $fatal(1);
        end

        if (issue_count !== 64'd2 || edges_released !== 64'd4) begin
            $display("XPU_V21_TILE_FAIL counters issues=%0d edges=%0d", issue_count, edges_released);
            $fatal(1);
        end

        $display("XPU_V21_TILE_PASS node3=57577 node4=157774 issues=%0d edges=%0d completions=%0d",
                 issue_count, edges_released, accepted_completions);
        $finish;
    end
endmodule
