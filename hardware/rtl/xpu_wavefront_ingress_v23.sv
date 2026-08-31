// SHTENCO XPU V2.3 — phase-addressed operand ingress.
//
// Static fast-path tokens carry only the Q16.16 value. Destination node and
// operand slot are selected by (phase, ingress port), i.e. time is the tag.
// The compiler must make bank writes conflict-free. Any collision is a sticky
// schedule fault rather than a retry path.

module xpu_wavefront_ingress_v23 #(
    parameter integer NODES = 256,
    parameter integer PORTS = 24,
    parameter integer BANKS = 32,
    parameter integer LANES = 8,
    parameter integer SLOTS = 256,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES),
    parameter integer PORT_W = (PORTS <= 1) ? 1 : $clog2(PORTS),
    parameter integer SLOT_W = (SLOTS <= 1) ? 1 : $clog2(SLOTS)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         cfg_map_we,
    input  logic [PORT_W-1:0]            cfg_map_port,
    input  logic [SLOT_W-1:0]            cfg_map_phase,
    input  logic                         cfg_map_valid,
    input  logic [NODE_W-1:0]            cfg_map_node,
    input  logic                         cfg_map_slot, // 0=A, 1=B

    input  logic [SLOT_W-1:0]            phase,
    input  logic [PORTS-1:0]             data_valid,
    input  logic signed [31:0]           data_value [0:PORTS-1],

    input  logic [LANES-1:0]             consume_valid,
    input  logic [NODE_W-1:0]            consume_node [0:LANES-1],

    input  logic [NODE_W-1:0]            read_node [0:LANES-1],
    output logic signed [31:0]           read_a [0:LANES-1],
    output logic signed [31:0]           read_b [0:LANES-1],
    output logic [LANES-1:0]             read_a_valid,
    output logic [LANES-1:0]             read_b_valid,

    output logic                         fault_bank_conflict,
    output logic                         fault_unmapped_data,
    output logic [63:0]                  accepted_values
);

    logic map_valid [0:PORTS-1][0:SLOTS-1];
    logic [NODE_W-1:0] map_node [0:PORTS-1][0:SLOTS-1];
    logic map_slot [0:PORTS-1][0:SLOTS-1];

    logic signed [31:0] operand_a [0:NODES-1];
    logic signed [31:0] operand_b [0:NODES-1];
    logic [NODES-1:0] valid_a;
    logic [NODES-1:0] valid_b;

    logic [BANKS-1:0] bank_taken;
    logic [PORTS-1:0] accept_port;
    logic conflict_c;
    logic unmapped_c;
    integer p;
    integer lane;
    integer bank;
    integer accepts_c;

    always_comb begin
        bank_taken = '0;
        accept_port = '0;
        conflict_c = 1'b0;
        unmapped_c = 1'b0;
        accepts_c = 0;

        for (p = 0; p < PORTS; p = p + 1) begin
            if (data_valid[p]) begin
                if (!map_valid[p][phase]) begin
                    unmapped_c = 1'b1;
                end else begin
                    bank = map_node[p][phase] % BANKS;
                    if (bank_taken[bank]) begin
                        conflict_c = 1'b1;
                    end else begin
                        bank_taken[bank] = 1'b1;
                        accept_port[p] = 1'b1;
                        accepts_c = accepts_c + 1;
                    end
                end
            end
        end

        for (lane = 0; lane < LANES; lane = lane + 1) begin
            read_a[lane] = operand_a[read_node[lane]];
            read_b[lane] = operand_b[read_node[lane]];
            read_a_valid[lane] = valid_a[read_node[lane]];
            read_b_valid[lane] = valid_b[read_node[lane]];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        integer n;
        if (!rst_n) begin
            valid_a <= '0;
            valid_b <= '0;
            fault_bank_conflict <= 1'b0;
            fault_unmapped_data <= 1'b0;
            accepted_values <= 64'd0;
            for (n = 0; n < NODES; n = n + 1) begin
                operand_a[n] <= 32'sd0;
                operand_b[n] <= 32'sd0;
            end
        end else begin
            if (cfg_map_we) begin
                map_valid[cfg_map_port][cfg_map_phase] <= cfg_map_valid;
                map_node[cfg_map_port][cfg_map_phase] <= cfg_map_node;
                map_slot[cfg_map_port][cfg_map_phase] <= cfg_map_slot;
            end

            for (i = 0; i < LANES; i = i + 1) begin
                if (consume_valid[i]) begin
                    valid_a[consume_node[i]] <= 1'b0;
                    valid_b[consume_node[i]] <= 1'b0;
                end
            end

            for (i = 0; i < PORTS; i = i + 1) begin
                if (accept_port[i]) begin
                    if (map_slot[i][phase]) begin
                        operand_b[map_node[i][phase]] <= data_value[i];
                        valid_b[map_node[i][phase]] <= 1'b1;
                    end else begin
                        operand_a[map_node[i][phase]] <= data_value[i];
                        valid_a[map_node[i][phase]] <= 1'b1;
                    end
                end
            end

            if (conflict_c)
                fault_bank_conflict <= 1'b1;
            if (unmapped_c)
                fault_unmapped_data <= 1'b1;
            accepted_values <= accepted_values + accepts_c;
        end
    end

endmodule
