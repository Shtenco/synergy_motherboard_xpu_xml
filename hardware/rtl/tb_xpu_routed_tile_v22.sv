`timescale 1ns/1ps

module tb_xpu_routed_tile_v22;
    localparam integer NODES = 16;
    localparam integer LANES = 2;
    localparam integer BANKS = 4;
    localparam integer NODE_W = 4;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic cfg_node_we;
    logic [NODE_W-1:0] cfg_node;
    logic [7:0] cfg_opcode;

    logic cfg_route_we;
    logic [NODE_W-1:0] cfg_route_producer;
    logic [1:0] cfg_route_count;
    logic [NODE_W-1:0] cfg_route_dst0, cfg_route_dst1;
    logic cfg_route_slot0, cfg_route_slot1;

    logic inject_valid;
    logic [NODE_W-1:0] inject_node;
    logic inject_slot;
    logic signed [31:0] inject_value;
    logic inject_ready;

    logic [NODE_W-1:0] debug_node;
    logic signed [31:0] debug_value;
    logic halted, fault_bad_opcode, fault_domain, fault_route_stall;
    logic [63:0] issue_count, lane_idle_cycles, ready_empty_cycles;
    logic [63:0] accepted_tokens, bank_conflict_stalls, ready_events, route_tokens_emitted;

    always #5 clk = ~clk;

    xpu_routed_tile_v22 #(
        .NODES(NODES), .LANES(LANES), .BANKS(BANKS), .NODE_W(NODE_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_node_we(cfg_node_we), .cfg_node(cfg_node), .cfg_opcode(cfg_opcode),
        .cfg_route_we(cfg_route_we), .cfg_route_producer(cfg_route_producer),
        .cfg_route_count(cfg_route_count), .cfg_route_dst0(cfg_route_dst0),
        .cfg_route_slot0(cfg_route_slot0), .cfg_route_dst1(cfg_route_dst1),
        .cfg_route_slot1(cfg_route_slot1),
        .inject_valid(inject_valid), .inject_node(inject_node), .inject_slot(inject_slot),
        .inject_value(inject_value), .inject_ready(inject_ready),
        .debug_node(debug_node), .debug_value(debug_value),
        .halted(halted), .fault_bad_opcode(fault_bad_opcode),
        .fault_domain(fault_domain), .fault_route_stall(fault_route_stall),
        .issue_count(issue_count), .lane_idle_cycles(lane_idle_cycles),
        .ready_empty_cycles(ready_empty_cycles), .accepted_tokens(accepted_tokens),
        .bank_conflict_stalls(bank_conflict_stalls), .ready_events(ready_events),
        .route_tokens_emitted(route_tokens_emitted)
    );

    task automatic write_node(input [NODE_W-1:0] n, input [7:0] op);
        begin
            @(negedge clk);
            cfg_node = n; cfg_opcode = op; cfg_node_we = 1'b1;
            @(negedge clk); cfg_node_we = 1'b0;
        end
    endtask

    task automatic write_route(input [NODE_W-1:0] producer,
                               input [1:0] count,
                               input [NODE_W-1:0] dst0, input slot0,
                               input [NODE_W-1:0] dst1, input slot1);
        begin
            @(negedge clk);
            cfg_route_producer = producer; cfg_route_count = count;
            cfg_route_dst0 = dst0; cfg_route_slot0 = slot0;
            cfg_route_dst1 = dst1; cfg_route_slot1 = slot1;
            cfg_route_we = 1'b1;
            @(negedge clk); cfg_route_we = 1'b0;
        end
    endtask

    task automatic inject(input [NODE_W-1:0] n, input slot, input signed [31:0] value);
        begin
            @(negedge clk);
            inject_node = n; inject_slot = slot; inject_value = value; inject_valid = 1'b1;
            while (!inject_ready)
                @(negedge clk);
            @(negedge clk);
            inject_valid = 1'b0;
        end
    endtask

    initial begin
        cfg_node_we = 0; cfg_node = 0; cfg_opcode = 0;
        cfg_route_we = 0; cfg_route_producer = 0; cfg_route_count = 0;
        cfg_route_dst0 = 0; cfg_route_dst1 = 0; cfg_route_slot0 = 0; cfg_route_slot1 = 0;
        inject_valid = 0; inject_node = 0; inject_slot = 0; inject_value = 0;
        debug_node = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Semantic graph:
        // node3 = EML(x=.25, b=1.5)
        // node4 = EML(node3, 1)
        write_node(4'd3, 8'd3);
        write_node(4'd4, 8'd3);

        // node3 result feeds node4 operand A; node4 is final.
        write_route(4'd3, 2'd1, 4'd4, 1'b0, 4'd0, 1'b0);
        write_route(4'd4, 2'd0, 4'd0, 1'b0, 4'd0, 1'b0);

        // .xpur lowering of INPUT/CONST nodes becomes initial tokens.
        inject(4'd3, 1'b0, 32'sd16384); // x = 0.25
        inject(4'd3, 1'b1, 32'sd98304); // b = 1.5
        inject(4'd4, 1'b1, 32'sd65536); // constant 1.0

        repeat (30) @(negedge clk);

        if (halted || fault_bad_opcode || fault_domain || fault_route_stall) begin
            $display("XPU_V22_ROUTED_FAIL fault halted=%0d badop=%0d domain=%0d route=%0d",
                     halted, fault_bad_opcode, fault_domain, fault_route_stall);
            $fatal(1);
        end

        debug_node = 4'd3;
        #1;
        if (debug_value !== 32'sd57577) begin
            $display("XPU_V22_ROUTED_FAIL node3=%0d expected=57577", debug_value);
            $fatal(1);
        end

        debug_node = 4'd4;
        #1;
        if (debug_value !== 32'sd157774) begin
            $display("XPU_V22_ROUTED_FAIL node4=%0d expected=157774", debug_value);
            $fatal(1);
        end

        if (issue_count !== 64'd2 || route_tokens_emitted !== 64'd1 ||
            accepted_tokens !== 64'd4 || ready_events !== 64'd2 ||
            bank_conflict_stalls !== 64'd0) begin
            $display("XPU_V22_ROUTED_FAIL counters issue=%0d route=%0d tokens=%0d ready=%0d conflicts=%0d",
                     issue_count, route_tokens_emitted, accepted_tokens, ready_events,
                     bank_conflict_stalls);
            $fatal(1);
        end

        $display("XPU_V22_ROUTED_TILE_PASS node3=57577 node4=157774 issues=%0d route_tokens=%0d",
                 issue_count, route_tokens_emitted);
        $finish;
    end
endmodule
