// SHTENCO XPU V2.2 — bank-arbitrated operand store.
//
// Incoming routed tokens carry {consumer node, operand slot, Q16.16 value}.
// One token per bank is accepted per cycle; colliding ports observe ready=0 and
// must retry from their route/injection queue. A node becomes ready when the
// arriving token fills its missing A/B operand slot.
//
// This is the first distributed dependency-resolution primitive: no central
// pending-counter update is required for static binary EML nodes.

module xpu_operand_store #(
    parameter integer NODES = 256,
    parameter integer PORTS = 8,
    parameter integer LANES = 8,
    parameter integer BANKS = 8,
    parameter integer NODE_W = (NODES <= 1) ? 1 : $clog2(NODES)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic [PORTS-1:0]             token_valid,
    input  logic [NODE_W-1:0]            token_node [0:PORTS-1],
    input  logic                         token_slot [0:PORTS-1], // 0=A, 1=B
    input  logic signed [31:0]           token_value [0:PORTS-1],
    output logic [PORTS-1:0]             token_ready,

    // Parallel ready events feed xpu_ready_scheduler.ready_set_bits.
    output logic [NODES-1:0]             ready_set_bits,

    // Issuing a node consumes both operand-valid bits for this generation.
    input  logic [LANES-1:0]             consume_valid,
    input  logic [NODE_W-1:0]            consume_node [0:LANES-1],

    input  logic [NODE_W-1:0]            read_node [0:LANES-1],
    output logic signed [31:0]           read_a [0:LANES-1],
    output logic signed [31:0]           read_b [0:LANES-1],

    output logic [63:0]                  accepted_tokens,
    output logic [63:0]                  bank_conflict_stalls,
    output logic [63:0]                  ready_events
);

    logic signed [31:0] operand_a [0:NODES-1];
    logic signed [31:0] operand_b [0:NODES-1];
    logic [NODES-1:0] valid_a;
    logic [NODES-1:0] valid_b;

    logic [BANKS-1:0] bank_taken;
    integer p;
    integer lane;
    integer bank;
    integer accepted_this_cycle;
    integer stalled_this_cycle;
    integer ready_this_cycle;

    always_comb begin
        token_ready = '0;
        ready_set_bits = '0;
        bank_taken = '0;
        accepted_this_cycle = 0;
        stalled_this_cycle = 0;
        ready_this_cycle = 0;

        // Deterministic lowest-port priority inside each bank.
        for (p = 0; p < PORTS; p = p + 1) begin
            if (token_valid[p]) begin
                bank = token_node[p] % BANKS;
                if (!bank_taken[bank]) begin
                    bank_taken[bank] = 1'b1;
                    token_ready[p] = 1'b1;
                    accepted_this_cycle = accepted_this_cycle + 1;
                    if ((!token_slot[p] && valid_b[token_node[p]]) ||
                        ( token_slot[p] && valid_a[token_node[p]])) begin
                        ready_set_bits[token_node[p]] = 1'b1;
                        ready_this_cycle = ready_this_cycle + 1;
                    end
                end else begin
                    stalled_this_cycle = stalled_this_cycle + 1;
                end
            end
        end

        for (lane = 0; lane < LANES; lane = lane + 1) begin
            read_a[lane] = operand_a[read_node[lane]];
            read_b[lane] = operand_b[read_node[lane]];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        integer n;
        if (!rst_n) begin
            valid_a <= '0;
            valid_b <= '0;
            accepted_tokens <= 64'd0;
            bank_conflict_stalls <= 64'd0;
            ready_events <= 64'd0;
            for (n = 0; n < NODES; n = n + 1) begin
                operand_a[n] <= 32'sd0;
                operand_b[n] <= 32'sd0;
            end
        end else begin
            // Clear consumed generation first; accepted new tokens later in the
            // same edge take precedence and can start the next generation.
            for (i = 0; i < LANES; i = i + 1) begin
                if (consume_valid[i]) begin
                    valid_a[consume_node[i]] <= 1'b0;
                    valid_b[consume_node[i]] <= 1'b0;
                end
            end

            for (i = 0; i < PORTS; i = i + 1) begin
                if (token_valid[i] && token_ready[i]) begin
                    if (token_slot[i]) begin
                        operand_b[token_node[i]] <= token_value[i];
                        valid_b[token_node[i]] <= 1'b1;
                    end else begin
                        operand_a[token_node[i]] <= token_value[i];
                        valid_a[token_node[i]] <= 1'b1;
                    end
                end
            end

            accepted_tokens <= accepted_tokens + accepted_this_cycle;
            bank_conflict_stalls <= bank_conflict_stalls + stalled_this_cycle;
            ready_events <= ready_events + ready_this_cycle;
        end
    end

endmodule
