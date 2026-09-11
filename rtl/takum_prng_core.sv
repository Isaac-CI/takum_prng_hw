// -----------------------------------------------------------------------------
// takum_prng_core
//
// PRNG caotico takum32: mapa tenda acoplado ao mapa seno (Bhaskara), com as
// saidas de cada mapa perturbadas por um LFSR de Galois e trocadas entre si a
// cada iteracao.
//
// UMA ALU, SEQUENCIADA. A escolha de arquitetura aqui e ditada pela BRAM: um
// takum_log_adder carrega 53 RAMB36 de tabelas Gauss-log, entao replicar ALUs
// custa BRAM linearmente -- quatro delas ja seriam 212 dos 312 tiles de uma
// ZCU104. Com uma unica ALU compartilhada e uma maquina de estados, o PRNG
// inteiro cabe nos mesmos 53. O preco e vazao, e ela sobra: sao 11 operacoes
// por iteracao, cada uma segurando os operandos por ALU_LATENCY+1 ciclos,
// mais 4 ciclos de LFSR/perturbacao/emissao -- 48 ciclos por iteracao, ~26
// bits de saida por iteracao, cerca de 40 Mbit/s a 75 MHz.
//
// TEMPO CONSTANTE. Os dois ramos do mapa tenda sao sempre calculados, e as
// duas divisoes de salvaguarda (1/x) sao sempre emitidas mesmo quando nao
// serao usadas. Uma iteracao leva sempre o mesmo numero de ciclos,
// independente dos dados -- alem de simplificar a FSM, isso evita que o
// tempo de execucao vaze informacao sobre o estado interno.
//
// MICROCODIGO (cada passo e uma operacao da ALU):
//
//   tenda:  0  A = 1 - T
//           1  T = MU * (T < 0.5 ? T : A)
//   seno:   2  A = 1 - S
//           3  B = S * A                 -> u
//           4  A = C16 * B               -> 16u
//           5  B = C4 * B                -> 4u
//           6  B = C5 - B                -> 5 - 4u
//           7  A = A / B                 -> 16u/(5-4u)
//           8  S = R * A
//   depois: LFSR, perturba T, 1/T, perturba S, 1/S, emite e troca.
// -----------------------------------------------------------------------------
module takum_prng_core
    import takum_prng_pkg::*;
#(
    parameter int    ALU_LATENCY = 3,     // takum_log_alu com EXTRA_STAGE=1
    parameter int    EXTRA_STAGE = 1,
    parameter string LUT_DIR     = "rtl/lns/lut/"
) (
    input  logic            clk_i,
    input  logic            rst_i,        // sincrono, ativo alto

    // Back-pressure do consumidor. Um PRNG nao pode descartar amostras, entao
    // quando o empacotador nao tem espaco a FSM simplesmente segura em
    // ST_EMIT ate ter -- o estado interno nao avanca, nada se perde.
    input  logic            ready_i,

    output logic            valid_o,      // pulso de um ciclo
    output logic [5:0]      nbits_o,      // 0..WF; 0 quando houve colapso
    output logic [WF-1:0]   data_o
);

    // ---- estado -------------------------------------------------------------
    logic [N-1:0] r_t, r_s, r_a, r_b;
    logic [31:0]  lfsr;
    logic [2:0]   idx_t, idx_s;

    logic [5:0]     mb_t, mb_s;
    logic [WF-1:0]  mt, ms;
    logic           need_inv_t, need_inv_s;

    // ---- maquina de estados -------------------------------------------------
    typedef enum logic [2:0] {
        ST_MAPS,    // passos 0..8 do microcodigo
        ST_LFSR,
        ST_PERT_T,
        ST_INV_T,
        ST_PERT_S,
        ST_INV_S,
        ST_EMIT
    } state_t;

    state_t     state;
    logic [3:0] step;
    logic [3:0] wait_cnt;

    // Um passo de ALU: os operandos ficam estaveis por ALU_LATENCY ciclos e o
    // resultado e capturado no ultimo. A ALU e um pipeline sem back-pressure,
    // entao segurar a entrada e suficiente.
    // A saida da ALU no ciclo t reflete a entrada de t - ALU_LATENCY. Com os
    // operandos estaveis a partir do ciclo 0 deste passo, o resultado so e
    // valido no ciclo ALU_LATENCY -- capturar antes pegaria o passo anterior.
    logic alu_done;
    assign alu_done = (wait_cnt == ALU_LATENCY[3:0]);

    // ---- operandos da ALU (microcodigo) -------------------------------------
    logic [2:0]   alu_op;
    logic [N-1:0] alu_a, alu_b, alu_y;

    logic t_lt_half;
    assign t_lt_half = $signed(r_t) < $signed(C_HALF);

    always_comb begin
        alu_op = OP_MUL;
        alu_a  = C_ONE;
        alu_b  = r_t;
        case (state)
            ST_MAPS:
                case (step)
                    4'd0: begin alu_op = OP_SUB; alu_a = C_ONE; alu_b = r_t;                     end
                    4'd1: begin alu_op = OP_MUL; alu_a = C_MU;  alu_b = t_lt_half ? r_t : r_a;   end
                    4'd2: begin alu_op = OP_SUB; alu_a = C_ONE; alu_b = r_s;                     end
                    4'd3: begin alu_op = OP_MUL; alu_a = r_s;   alu_b = r_a;                     end
                    4'd4: begin alu_op = OP_MUL; alu_a = C_R16; alu_b = r_b;                     end
                    4'd5: begin alu_op = OP_MUL; alu_a = C_C4;  alu_b = r_b;                     end
                    4'd6: begin alu_op = OP_SUB; alu_a = C_C5;  alu_b = r_b;                     end
                    // O quociente JA E S': o ganho r do mapa seno esta dobrado
                    // em C_R16, entao nao ha mais um passo 8 multiplicando por
                    // 0,9 -- ver o comentario de C_R16 em takum_prng_pkg.
                    4'd7: begin alu_op = OP_DIV; alu_a = r_a;   alu_b = r_b;                     end
                    default: ;
                endcase
            ST_INV_T: begin alu_op = OP_DIV; alu_a = C_ONE; alu_b = r_t; end
            ST_INV_S: begin alu_op = OP_DIV; alu_a = C_ONE; alu_b = r_s; end
            default: ;
        endcase
    end

    takum_log_alu #(
        .N           (N),
        .EXTRA_STAGE (EXTRA_STAGE),
        .LUT_DIR     (LUT_DIR)
    ) u_alu (
        .clk_i    (clk_i),
        .op_i     (alu_op),
        .a_i      (alu_a),
        .b_i      (alu_b),
        .result_o (alu_y)
    );

    // ---- LFSR de Galois, LFSR_STEPS passos por iteracao ----------------------
    function automatic logic [31:0] lfsr_advance(input logic [31:0] s);
        logic [31:0] v;
        begin
            v = s;
            for (int k = 0; k < LFSR_STEPS; k++)
                v = v[0] ? ((v >> 1) ^ LFSR_POLY) : (v >> 1);
            lfsr_advance = v;
        end
    endfunction

    // ---- perturbacao (combinacional, um por mapa) ---------------------------
    logic          col_t, col_s;
    logic [5:0]    pmb_t, pmb_s;
    logic [WF-1:0] pmt, pms;
    logic [N-1:0]  px_t, px_s;
    logic          pinv_t, pinv_s;

    takum_prng_perturb u_pert_t (
        .x_i(r_t), .lfsr_i(lfsr), .seed_i(SEEDS[idx_t]),
        .collapse_o(col_t), .m_bits_o(pmb_t), .m_out_o(pmt),
        .x_o(px_t), .need_inv_o(pinv_t)
    );

    takum_prng_perturb u_pert_s (
        .x_i(r_s), .lfsr_i(lfsr), .seed_i(SEEDS[idx_s]),
        .collapse_o(col_s), .m_bits_o(pmb_s), .m_out_o(pms),
        .x_o(px_s), .need_inv_o(pinv_s)
    );

    // ---- saida: min(m_bits) bits de (mt ^ ms ^ lfsr) -------------------------
    logic [5:0]    out_bits_c;
    logic [WF-1:0] out_mask_c, out_data_c;
    assign out_bits_c = (mb_t < mb_s) ? mb_t : mb_s;
    assign out_mask_c = ({WF{1'b1}}) >> (WF - out_bits_c);
    assign out_data_c = (mt ^ ms ^ lfsr[WF-1:0]) & out_mask_c;

    // ---- sequenciamento ------------------------------------------------------
    always_ff @(posedge clk_i) begin
        valid_o <= 1'b0;

        if (rst_i) begin
            state    <= ST_MAPS;
            step     <= 4'd0;
            wait_cnt <= 4'd0;
            r_t      <= T_INIT;
            r_s      <= S_INIT;
            r_a      <= '0;
            r_b      <= '0;
            lfsr     <= LFSR_INIT;
            idx_t    <= 3'd0;
            idx_s    <= 3'd0;
            need_inv_t <= 1'b0;
            need_inv_s <= 1'b0;
            mb_t     <= 6'd0;
            mb_s     <= 6'd0;
            mt       <= '0;
            ms       <= '0;
            nbits_o  <= 6'd0;
            data_o   <= '0;
        end else begin
            case (state)
                // ---- passos 0..8: os dois mapas -------------------------
                ST_MAPS: begin
                    if (!alu_done) begin
                        wait_cnt <= wait_cnt + 4'd1;
                    end else begin
                        wait_cnt <= 4'd0;
                        case (step)
                            4'd0: r_a <= alu_y;
                            4'd1: r_t <= alu_y;
                            4'd2: r_a <= alu_y;
                            4'd3: r_b <= alu_y;
                            4'd4: r_a <= alu_y;
                            4'd5: r_b <= alu_y;
                            4'd6: r_b <= alu_y;
                            4'd7: r_s <= alu_y;
                            default: ;
                        endcase
                        if (step == 4'd7) begin
                            step  <= 4'd0;
                            state <= ST_LFSR;
                        end else begin
                            step <= step + 4'd1;
                        end
                    end
                end

                // ---- LFSR ------------------------------------------------
                ST_LFSR: begin
                    lfsr  <= lfsr_advance(lfsr);
                    state <= ST_PERT_T;
                end

                // ---- perturba T -----------------------------------------
                ST_PERT_T: begin
                    r_t        <= px_t;
                    mb_t       <= pmb_t;
                    mt         <= pmt;
                    need_inv_t <= pinv_t;
                    if (col_t) idx_t <= idx_t + 3'd1;
                    state      <= ST_INV_T;
                    wait_cnt   <= 4'd0;
                end

                // ---- 1/T, emitida sempre (tempo constante) ---------------
                ST_INV_T: begin
                    if (!alu_done) begin
                        wait_cnt <= wait_cnt + 4'd1;
                    end else begin
                        wait_cnt <= 4'd0;
                        if (need_inv_t) r_t <= alu_y;
                        state <= ST_PERT_S;
                    end
                end

                // ---- perturba S -----------------------------------------
                ST_PERT_S: begin
                    r_s        <= px_s;
                    mb_s       <= pmb_s;
                    ms         <= pms;
                    need_inv_s <= pinv_s;
                    if (col_s) idx_s <= idx_s + 3'd1;
                    state      <= ST_INV_S;
                    wait_cnt   <= 4'd0;
                end

                ST_INV_S: begin
                    if (!alu_done) begin
                        wait_cnt <= wait_cnt + 4'd1;
                    end else begin
                        wait_cnt <= 4'd0;
                        if (need_inv_s) r_s <= alu_y;
                        state <= ST_EMIT;
                    end
                end

                // ---- saida e troca ---------------------------------------
                ST_EMIT: begin
                    if (ready_i) begin
                        nbits_o <= out_bits_c;
                        data_o  <= out_data_c;
                        valid_o <= 1'b1;
                        // troca T e S: e ela que faz o acoplamento 2D
                        r_t     <= r_s;
                        r_s     <= r_t;
                        state   <= ST_MAPS;
                        step    <= 4'd0;
                        wait_cnt<= 4'd0;
                    end
                end

                default: state <= ST_MAPS;
            endcase
        end
    end

endmodule : takum_prng_core
