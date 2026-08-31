// SHTENCO XPU V2.2 — two-way static route table.
//
// Fast-path contract: every producer has 0, 1 or 2 direct route entries.
// Higher graph fanout is lowered by the compiler into replication trees or the
// dynamic/fallback path. This keeps local route emission bounded and explicit.

module xpu_route_table2 #(
    parameter integer NODES = 256,
    parameter integer LANES = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES)
) (
    input  logic                         clk,

    input  logic                         cfg_we,
    input  logic [NODE_W-1:0]            cfg_producer,
    input  logic [1:0]                   cfg_count,
    input  logic [NODE_W-1:0]            cfg_dst0,
    input  logic                         cfg_slot0,
    input  logic [NODE_W-1:0]            cfg_dst1,
    input  logic                         cfg_slot1,

    input  logic [NODE_W-1:0]            producer_node [0:LANES-1],
    output logic [1:0]                   route_count [0:LANES-1],
    output logic [NODE_W-1:0]            route_dst0 [0:LANES-1],
    output logic                         route_slot0 [0:LANES-1],
    output logic [NODE_W-1:0]            route_dst1 [0:LANES-1],
    output logic                         route_slot1 [0:LANES-1]
);

    logic [1:0] count_mem [0:NODES-1];
    logic [NODE_W-1:0] dst0_mem [0:NODES-1];
    logic [NODE_W-1:0] dst1_mem [0:NODES-1];
    logic slot0_mem [0:NODES-1];
    logic slot1_mem [0:NODES-1];
    integer lane;

    always_comb begin
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            route_count[lane] = count_mem[producer_node[lane]];
            route_dst0[lane] = dst0_mem[producer_node[lane]];
            route_slot0[lane] = slot0_mem[producer_node[lane]];
            route_dst1[lane] = dst1_mem[producer_node[lane]];
            route_slot1[lane] = slot1_mem[producer_node[lane]];
        end
    end

    always_ff @(posedge clk) begin
        if (cfg_we) begin
            count_mem[cfg_producer] <= cfg_count;
            dst0_mem[cfg_producer] <= cfg_dst0;
            slot0_mem[cfg_producer] <= cfg_slot0;
            dst1_mem[cfg_producer] <= cfg_dst1;
            slot1_mem[cfg_producer] <= cfg_slot1;
        end
    end

endmodule
