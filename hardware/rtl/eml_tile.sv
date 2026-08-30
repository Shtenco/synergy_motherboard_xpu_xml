// SHTENCO XPU V2 proof tile.
// Establishes a replicated EML-lane boundary and vector-valid semantics.
// Ready-node scheduling and local operand queues are separate modules in the
// next step; this file intentionally keeps arithmetic replication inspectable.

module eml_tile #(
    parameter integer LANES = 8,
    parameter EXP_MEMH = "hardware/rtl/generated/exp_q16.memh",
    parameter LN_MEMH  = "hardware/rtl/generated/ln_q16.memh"
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [LANES-1:0]             in_valid,
    input  logic signed [31:0]            a_q16 [0:LANES-1],
    input  logic signed [31:0]            b_q16 [0:LANES-1],
    output logic [LANES-1:0]             out_valid,
    output logic [LANES-1:0]             out_domain_error,
    output logic signed [31:0]           y_q16 [0:LANES-1]
);
    genvar i;
    generate
        for (i = 0; i < LANES; i = i + 1) begin : g_lane
            eml_lane_lut #(
                .EXP_MEMH(EXP_MEMH),
                .LN_MEMH(LN_MEMH)
            ) lane (
                .clk(clk),
                .rst_n(rst_n),
                .in_valid(in_valid[i]),
                .a_q16(a_q16[i]),
                .b_q16(b_q16[i]),
                .out_valid(out_valid[i]),
                .out_domain_error(out_domain_error[i]),
                .y_q16(y_q16[i])
            );
        end
    endgenerate
endmodule
