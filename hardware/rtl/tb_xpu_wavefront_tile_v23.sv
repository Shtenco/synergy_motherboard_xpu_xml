`timescale 1ns/1ps

module tb_xpu_wavefront_tile_v23;
    localparam integer NODES = 16;
    localparam integer LANES = 8;
    localparam integer PORTS = 24;
    localparam integer BANKS = 32;
    localparam integer SLOTS = 16;
    localparam integer NODE_W = 4;
    localparam integer LANE_W = 3;
    localparam integer PORT_W = 5;
    localparam integer SLOT_W = 4;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic cfg_sched_we;
    logic [LANE_W-1:0] cfg_sched_lane;
    logic [SLOT_W-1:0] cfg_sched_phase;
    logic cfg_sched_valid;
    logic [NODE_W-1:0] cfg_sched_node;

    logic cfg_map_we;
    logic [PORT_W-1:0] cfg_map_port;
    logic [SLOT_W-1:0] cfg_map_phase;
    logic cfg_map_valid;
    logic [NODE_W-1:0] cfg_map_node;
    logic cfg_map_slot;

    logic start;
    logic loop_enable;
    logic [SLOT_W-1:0] period_last;

    logic [PORTS-1:0] fabric_in_valid;
    logic signed [31:0] fabric_in_value [0:PORTS-1];
    logic [LANES-1:0] fabric_out_valid;
    logic signed [31:0] fabric_out_value [0:LANES-1];
    logic [NODE_W-1:0] fabric_out_node_debug [0:LANES-1];

    logic running;
    logic [SLOT_W-1:0] phase;
    logic halted;
    logic fault_missing_operand;
    logic fault_domain;
    logic fault_bank_conflict;
    logic fault_unmapped_data;
    logic [63:0] accepted_input_values;
    logic [63:0] issued_eml_ops;

    logic got_node3;
    logic got_node4;

    integer i;

    xpu_wavefront_tile_v23 #(
        .NODES(NODES), .LANES(LANES), .PORTS(PORTS), .BANKS(BANKS),
        .SLOTS(SLOTS), .NODE_W(NODE_W), .LANE_W(LANE_W),
        .PORT_W(PORT_W), .SLOT_W(SLOT_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_sched_we(cfg_sched_we), .cfg_sched_lane(cfg_sched_lane),
        .cfg_sched_phase(cfg_sched_phase), .cfg_sched_valid(cfg_sched_valid),
        .cfg_sched_node(cfg_sched_node),
        .cfg_map_we(cfg_map_we), .cfg_map_port(cfg_map_port),
        .cfg_map_phase(cfg_map_phase), .cfg_map_valid(cfg_map_valid),
        .cfg_map_node(cfg_map_node), .cfg_map_slot(cfg_map_slot),
        .start(start), .loop_enable(loop_enable), .period_last(period_last),
        .fabric_in_valid(fabric_in_valid), .fabric_in_value(fabric_in_value),
        .fabric_out_valid(fabric_out_valid), .fabric_out_value(fabric_out_value),
        .fabric_out_node_debug(fabric_out_node_debug),
        .running(running), .phase(phase), .halted(halted),
        .fault_missing_operand(fault_missing_operand), .fault_domain(fault_domain),
        .fault_bank_conflict(fault_bank_conflict),
        .fault_unmapped_data(fault_unmapped_data),
        .accepted_input_values(accepted_input_values),
        .issued_eml_ops(issued_eml_ops)
    );

    task automatic write_sched(
        input [LANE_W-1:0] lane,
        input [SLOT_W-1:0] ph,
        input [NODE_W-1:0] node
    );
        begin
            @(negedge clk);
            cfg_sched_we = 1'b1;
            cfg_sched_lane = lane;
            cfg_sched_phase = ph;
            cfg_sched_valid = 1'b1;
            cfg_sched_node = node;
            @(negedge clk);
            cfg_sched_we = 1'b0;
        end
    endtask

    task automatic write_map(
        input [PORT_W-1:0] port,
        input [SLOT_W-1:0] ph,
        input [NODE_W-1:0] node,
        input slot
    );
        begin
            @(negedge clk);
            cfg_map_we = 1'b1;
            cfg_map_port = port;
            cfg_map_phase = ph;
            cfg_map_valid = 1'b1;
            cfg_map_node = node;
            cfg_map_slot = slot;
            @(negedge clk);
            cfg_map_we = 1'b0;
        end
    endtask

    always_comb begin
        fabric_in_valid = '0;
        for (i = 0; i < PORTS; i = i + 1)
            fabric_in_value[i] = 32'sd0;

        // Initial inputs for node3 arrive in phase 0.
        if (running && phase == 0) begin
            fabric_in_valid[0] = 1'b1;
            fabric_in_value[0] = 32'sd16384; // 0.25 Q16.16
            fabric_in_valid[1] = 1'b1;
            fabric_in_value[1] = 32'sd98304; // 1.5 Q16.16
        end

        // Node3's registered EML result is physically present during phase 2.
        // Feed it directly through the static fabric; no software-style
        // got_node3 state participates in the datapath timing.
        if (running && phase == 2 && fabric_out_valid[0] &&
            fabric_out_node_debug[0] == 4'd3) begin
            fabric_in_valid[0] = 1'b1;
            fabric_in_value[0] = fabric_out_value[0];
            fabric_in_valid[1] = 1'b1;
            fabric_in_value[1] = 32'sd65536; // node4.B = 1.0 Q16.16
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            got_node3 <= 1'b0;
            got_node4 <= 1'b0;
        end else begin
            if (fabric_out_valid[0]) begin
                if (fabric_out_node_debug[0] == 4'd3) begin
                    if (fabric_out_value[0] !== 32'sd57577) begin
                        $display("XPU_V23_FAIL node3=%0d", fabric_out_value[0]);
                        $fatal(1);
                    end
                    got_node3 <= 1'b1;
                end else if (fabric_out_node_debug[0] == 4'd4) begin
                    if (fabric_out_value[0] !== 32'sd157774) begin
                        $display("XPU_V23_FAIL node4=%0d", fabric_out_value[0]);
                        $fatal(1);
                    end
                    got_node4 <= 1'b1;
                end
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        cfg_sched_we = 1'b0;
        cfg_sched_lane = '0;
        cfg_sched_phase = '0;
        cfg_sched_valid = 1'b0;
        cfg_sched_node = '0;
        cfg_map_we = 1'b0;
        cfg_map_port = '0;
        cfg_map_phase = '0;
        cfg_map_valid = 1'b0;
        cfg_map_node = '0;
        cfg_map_slot = 1'b0;
        start = 1'b0;
        loop_enable = 1'b0;
        period_last = 4'd4;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Compiler schedule: node3 at phase1, node4 at phase3.
        write_sched(3'd0, 4'd1, 4'd3);
        write_sched(3'd0, 4'd3, 4'd4);

        // Time-is-tag ingress map.
        write_map(5'd0, 4'd0, 4'd3, 1'b0);
        write_map(5'd1, 4'd0, 4'd3, 1'b1);
        write_map(5'd0, 4'd2, 4'd4, 1'b0);
        write_map(5'd1, 4'd2, 4'd4, 1'b1);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        repeat (12) @(posedge clk);

        if (halted || fault_missing_operand || fault_domain ||
            fault_bank_conflict || fault_unmapped_data) begin
            $display("XPU_V23_FAIL fault halt=%0d miss=%0d domain=%0d bank=%0d map=%0d",
                     halted, fault_missing_operand, fault_domain,
                     fault_bank_conflict, fault_unmapped_data);
            $fatal(1);
        end
        if (!got_node3 || !got_node4) begin
            $display("XPU_V23_FAIL outputs node3=%0d node4=%0d", got_node3, got_node4);
            $fatal(1);
        end
        if (issued_eml_ops !== 64'd2 || accepted_input_values !== 64'd4) begin
            $display("XPU_V23_FAIL counters issues=%0d accepted=%0d",
                     issued_eml_ops, accepted_input_values);
            $fatal(1);
        end

        $display("XPU_V23_WAVEFRONT_TILE_PASS issues=%0d accepted=%0d",
                 issued_eml_ops, accepted_input_values);
        $finish;
    end
endmodule
