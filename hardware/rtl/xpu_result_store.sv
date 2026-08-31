// SHTENCO XPU V2.2 — simple result observation store.
// Keeps latest node result for host/debug/conformance reads.

module xpu_result_store #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [LANES-1:0]             write_valid,
    input  logic [NODE_W-1:0]            write_node [0:LANES-1],
    input  logic signed [31:0]           write_value [0:LANES-1],
    input  logic [NODE_W-1:0]            debug_node,
    output logic signed [31:0]           debug_value
);

    logic signed [31:0] mem [0:NODES-1];

    assign debug_value = mem[debug_node];

    always_ff @(posedge clk or negedge rst_n) begin
        integer lane;
        integer node;
        if (!rst_n) begin
            for (node = 0; node < NODES; node = node + 1)
                mem[node] <= 32'sd0;
        end else begin
            for (lane = 0; lane < LANES; lane = lane + 1)
                if (write_valid[lane])
                    mem[write_node[lane]] <= write_value[lane];
        end
    end

endmodule
