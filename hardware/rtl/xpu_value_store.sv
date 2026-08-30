// SHTENCO XPU V2.1 — bounded value-state store for the FPGA proof tile.
//
// The proof implementation uses a register array so all LANES may retire a
// result in the same cycle and operand reads remain combinational. This is NOT
// the final SRAM macro architecture. V2.2 should bank the value store and make
// bank conflicts visible to the scheduler.

module xpu_value_store #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         loader_we,
    input  logic [NODE_W-1:0]            loader_node,
    input  logic signed [31:0]           loader_value,

    input  logic [LANES-1:0]             retire_valid,
    input  logic [NODE_W-1:0]            retire_node [0:LANES-1],
    input  logic signed [31:0]           retire_value [0:LANES-1],

    input  logic [NODE_W-1:0]            read_a_node [0:LANES-1],
    input  logic [NODE_W-1:0]            read_b_node [0:LANES-1],
    output logic signed [31:0]           read_a_value [0:LANES-1],
    output logic signed [31:0]           read_b_value [0:LANES-1]
);

    logic signed [31:0] value_mem [0:NODES-1];
    integer i;

    always_comb begin
        for (i = 0; i < LANES; i = i + 1) begin
            read_a_value[i] = value_mem[read_a_node[i]];
            read_b_value[i] = value_mem[read_b_node[i]];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer lane;
        integer node;
        if (!rst_n) begin
            for (node = 0; node < NODES; node = node + 1)
                value_mem[node] <= 32'sd0;
        end else begin
            if (loader_we)
                value_mem[loader_node] <= loader_value;
            for (lane = 0; lane < LANES; lane = lane + 1)
                if (retire_valid[lane])
                    value_mem[retire_node[lane]] <= retire_value[lane];
        end
    end

endmodule
