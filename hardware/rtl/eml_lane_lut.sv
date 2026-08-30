// SHTENCO XPU V2 - LUT/interpolated EML lane proof RTL.
// Numeric contract:
//   signed Q16.16
//   EML(a,b) = exp(a) - ln(b)
//   a in [-4.0, +4.0]
//   b in [0.125, 8.125]
//   1024 intervals, 1/128 step, linear interpolation.
// This is FPGA proof RTL, not the final ASIC transcendental datapath.

module eml_lane_lut #(
    parameter EXP_MEMH = "hardware/rtl/generated/exp_q16.memh",
    parameter LN_MEMH  = "hardware/rtl/generated/ln_q16.memh"
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    in_valid,
    input  logic signed [31:0]      a_q16,
    input  logic signed [31:0]      b_q16,
    output logic                    out_valid,
    output logic                    out_domain_error,
    output logic signed [31:0]      y_q16
);

    localparam integer LUT_INTERVALS = 1024;
    localparam logic signed [31:0] A_MIN = -32'sd262144; // -4 * 65536
    localparam logic signed [31:0] A_MAX =  32'sd262144; // +4 * 65536
    localparam logic signed [31:0] B_MIN =  32'sd8192;   // 0.125 * 65536
    localparam logic signed [31:0] B_MAX =  32'sd532480; // 8.125 * 65536

    logic signed [31:0] exp_lut [0:LUT_INTERVALS];
    logic signed [31:0] ln_lut  [0:LUT_INTERVALS];

    initial begin
        $readmemh(EXP_MEMH, exp_lut);
        $readmemh(LN_MEMH,  ln_lut);
    end

    function automatic logic signed [63:0] interp_q16(
        input logic signed [31:0] y0,
        input logic signed [31:0] y1,
        input logic        [8:0]  frac
    );
        logic signed [63:0] delta;
        logic signed [63:0] product;
        logic signed [9:0]  frac_s;
        begin
            delta   = $signed(y1) - $signed(y0);
            frac_s  = $signed({1'b0, frac});
            product = delta * frac_s;
            interp_q16 = $signed(y0) + (product >>> 9);
        end
    endfunction

    function automatic logic signed [31:0] sat32(
        input logic signed [63:0] x
    );
        begin
            if (x > 64'sd2147483647)
                sat32 = 32'sh7fffffff;
            else if (x < -64'sd2147483648)
                sat32 = 32'sh80000000;
            else
                sat32 = x[31:0];
        end
    endfunction

    logic domain_c;
    logic signed [63:0] exp_c;
    logic signed [63:0] ln_c;
    logic signed [63:0] y_c;
    integer a_idx;
    integer b_idx;
    integer signed a_delta;
    integer signed b_delta;
    logic [8:0] a_frac;
    logic [8:0] b_frac;

    always_comb begin
        domain_c = 1'b0;
        exp_c = 64'sd0;
        ln_c  = 64'sd0;
        y_c   = 64'sd0;
        a_idx = 0;
        b_idx = 0;
        a_delta = 0;
        b_delta = 0;
        a_frac = 9'd0;
        b_frac = 9'd0;

        if (($signed(a_q16) < $signed(A_MIN)) ||
            ($signed(a_q16) > $signed(A_MAX)) ||
            ($signed(b_q16) < $signed(B_MIN)) ||
            ($signed(b_q16) > $signed(B_MAX))) begin
            domain_c = 1'b1;
        end else begin
            a_delta = $signed(a_q16) - $signed(A_MIN);
            b_delta = $signed(b_q16) - $signed(B_MIN);

            if ($signed(a_q16) == $signed(A_MAX)) begin
                exp_c = $signed(exp_lut[LUT_INTERVALS]);
            end else begin
                a_idx = a_delta >>> 9;
                a_frac = a_delta[8:0];
                exp_c = interp_q16(exp_lut[a_idx], exp_lut[a_idx + 1], a_frac);
            end

            if ($signed(b_q16) == $signed(B_MAX)) begin
                ln_c = $signed(ln_lut[LUT_INTERVALS]);
            end else begin
                b_idx = b_delta >>> 9;
                b_frac = b_delta[8:0];
                ln_c = interp_q16(ln_lut[b_idx], ln_lut[b_idx + 1], b_frac);
            end

            y_c = exp_c - ln_c;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid        <= 1'b0;
            out_domain_error <= 1'b0;
            y_q16            <= 32'sd0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                out_domain_error <= domain_c;
                y_q16 <= domain_c ? 32'sd0 : sat32(y_c);
            end else begin
                out_domain_error <= 1'b0;
            end
        end
    end

endmodule
