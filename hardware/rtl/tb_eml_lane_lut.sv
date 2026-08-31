`timescale 1ns/1ps
module tb_eml_lane_lut;
    logic clk = 0;
    logic rst_n = 0;
    logic in_valid = 0;
    logic signed [31:0] a_q16 = 0;
    logic signed [31:0] b_q16 = 0;
    logic out_valid;
    logic out_domain_error;
    logic signed [31:0] y_q16;

    eml_lane_lut dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .a_q16(a_q16), .b_q16(b_q16),
        .out_valid(out_valid), .out_domain_error(out_domain_error), .y_q16(y_q16)
    );

    always #5 clk = ~clk;

    task automatic check_ok(
        input logic signed [31:0] a,
        input logic signed [31:0] b,
        input logic signed [31:0] expected
    );
        begin
            @(negedge clk);
            in_valid = 1'b1;
            a_q16 = a;
            b_q16 = b;
            @(posedge clk);
            #1;
            if (!out_valid) $fatal(1, "missing out_valid");
            if (out_domain_error) $fatal(1, "unexpected domain error");
            if (y_q16 !== expected)
                $fatal(1, "mismatch a=%0d b=%0d got=%0d expected=%0d", a, b, y_q16, expected);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic check_domain(
        input logic signed [31:0] a,
        input logic signed [31:0] b
    );
        begin
            @(negedge clk);
            in_valid = 1'b1;
            a_q16 = a;
            b_q16 = b;
            @(posedge clk);
            #1;
            if (!out_valid || !out_domain_error)
                $fatal(1, "domain error was not reported");
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        check_ok(32'sd0,       32'sd65536,  32'sd65536);   // EML(0,1) = 1
        check_ok(32'sd65536,   32'sd65536,  32'sd178145);  // EML(1,1)
        check_ok(32'sd0,       32'sd131072, 32'sd20110);   // EML(0,2)
        check_ok(-32'sd65536,  32'sd32768,  32'sd69535);   // EML(-1,0.5)
        check_ok(32'sd16384,   32'sd98304,  32'sd57577);   // EML(0.25,1.5)
        check_domain(32'sd262145, 32'sd65536);              // a > +4
        check_domain(32'sd0, 32'sd8191);                    // b < 0.125

        $display("XPU_V2_EML_LANE_RTL_PASS");
        $finish;
    end
endmodule
