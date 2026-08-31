// SHTENCO XPU V2.3 — one-stage time-triggered multicast plane.
//
// A value carries no route id. For every (plane, phase), the compiler programs
// an output mask. The switch replicates the 32-bit value to the selected
// outputs. Multiple instances form the hierarchical radix network.

module xpu_static_multicast_plane_v23 #(
    parameter integer PLANES = 8,
    parameter integer RADIX = 4,
    parameter integer SLOTS = 256,
    parameter integer PLANE_W = (PLANES <= 1) ? 1 : $clog2(PLANES),
    parameter integer SLOT_W = (SLOTS <= 1) ? 1 : $clog2(SLOTS)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         cfg_we,
    input  logic [PLANE_W-1:0]           cfg_plane,
    input  logic [SLOT_W-1:0]            cfg_phase,
    input  logic [RADIX-1:0]             cfg_output_mask,

    input  logic [SLOT_W-1:0]            phase,
    input  logic [PLANES-1:0]            in_valid,
    input  logic signed [31:0]           in_value [0:PLANES-1],

    input  logic [RADIX-1:0]             out_ready [0:PLANES-1],
    output logic [RADIX-1:0]             out_valid [0:PLANES-1],
    output logic signed [31:0]           out_value [0:PLANES-1][0:RADIX-1],

    output logic                         fault_backpressure
);

    logic [RADIX-1:0] route_mask [0:PLANES-1][0:SLOTS-1];
    logic backpressure_c;
    integer plane;
    integer outp;

    always_comb begin
        backpressure_c = 1'b0;
        for (plane = 0; plane < PLANES; plane = plane + 1) begin
            out_valid[plane] = '0;
            for (outp = 0; outp < RADIX; outp = outp + 1) begin
                out_value[plane][outp] = in_value[plane];
                if (in_valid[plane] && route_mask[plane][phase][outp]) begin
                    out_valid[plane][outp] = 1'b1;
                    if (!out_ready[plane][outp])
                        backpressure_c = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_backpressure <= 1'b0;
        end else begin
            if (cfg_we)
                route_mask[cfg_plane][cfg_phase] <= cfg_output_mask;
            if (backpressure_c)
                fault_backpressure <= 1'b1;
        end
    end

endmodule
