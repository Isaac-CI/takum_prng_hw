// -----------------------------------------------------------------------------
// takum_prng_core_multi
//
// NSTREAMS geradores takum32 independentes intercalados no mesmo hardware, num
// PROCESSADOR EM BARRIL: a cada ciclo um fluxo e servido, avancando um passo do
// seu programa, e os demais ficam parados sem custar nada.
//
// POR QUE ISSO GANHA. No nucleo fundido de um fluxo so, das 23 celulas de uma
// iteracao nove sao espera pura -- tres subtracoes, cada uma parada tres ciclos
// enquanto a unidade Gauss-log trabalha. A ALU fica ociosa 39% do tempo. Com
// varios fluxos, essas lacunas sao preenchidas por trabalho de outro gerador.
//
// O ENCAIXE QUE DECIDE NSTREAMS = 3. A latencia do somador Gauss-log e
// LAT_ADD = 2 + EXTRA_STAGE = 3, e com tres fluxos o proximo turno de um fluxo
// chega exatamente tres ciclos depois. Um SUB emitido no turno de um fluxo tem
// o resultado pronto no instante em que esse fluxo volta a ser servido: a
// espera nao e reduzida, ela DESAPARECE. Mais fluxos nao ajudariam -- a ALU
// emite uma operacao por ciclo e cada iteracao precisa de dez, entao quatro
// fluxos passariam a disputar a porta de emissao em vez de preencher lacunas.
// O assert abaixo trava essa relacao.
//
// ENCAMINHAMENTO. No turno em que o resultado do SUB chega, o fluxo precisa ao
// mesmo tempo grava-lo e emitir o passo seguinte, que frequentemente e quem o
// consome (passo 0 -> 1, 2 -> 3, 6 -> 7). Ler o registrador nesse ciclo pegaria
// o valor velho, entao r_a/r_b efetivos vem de res_add_o quando ha um SUB em
// voo para aquele destino. Sem isso cada SUB custaria dois turnos e a iteracao
// subiria de 14 para 17.
//
// CONTAGEM. Catorze passos por iteracao -- oito do microcodigo dos mapas, mais
// LFSR, perturba T, 1/T, perturba S, 1/S e emite -- um turno cada, e um turno a
// cada NSTREAMS ciclos:
//
//   14 turnos x 3 ciclos = 42 ciclos por fluxo, 3 fluxos em paralelo
//   -> 14 ciclos por iteracao agregados, contra 23 do fluxo unico
//
// TEMPO CONSTANTE, preservado e agora mais forte: o turno de cada fluxo e
// funcao apenas do contador de ciclos, e todo passo dura um turno
// independentemente dos dados. Nem a duracao nem o INSTANTE de cada emissao
// dependem do estado interno.
//
// ORDEM DA SAIDA. Os tres fluxos partem juntos e sao servidos em ordem de
// indice, entao alcancam ST_EMIT em ordem de indice: a saida e o entrelacamento
// fluxo 0, fluxo 1, fluxo 2, fluxo 0, ... Como so o fluxo do turno avanca, nunca
// ha dois emitindo no mesmo ciclo e nao e preciso arbitrar a porta.
// -----------------------------------------------------------------------------
module takum_prng_core_multi
    import takum_prng_pkg::*;
    import takum_log_pkg::*;
    import takum_log_internal_pkg::*;
#(
    parameter int    EXTRA_STAGE = 1,
    parameter int    FAST_REG    = 0,
    parameter string LUT_DIR     = "rtl/lns/lut/"
) (
    input  logic            clk_i,
    input  logic            rst_i,
    input  logic            ready_i,
    output logic            valid_o,
    output logic [5:0]      nbits_o,
    output logic [WF-1:0]   data_o
);

    localparam int LAT_ADD  = 2 + EXTRA_STAGE;
    localparam int LAT_FAST = FAST_REG;
    localparam int SW       = $clog2(NSTREAMS);

    // O desenho depende de o periodo do barril casar com a latencia do somador.
    // Se alguem mexer em EXTRA_STAGE ou NSTREAMS sem mexer no outro, o
    // resultado do SUB deixaria de chegar no turno certo -- silenciosamente.
    initial begin
        if (NSTREAMS != LAT_ADD) begin
            $error("takum_prng_core_multi: NSTREAMS (%0d) deve ser igual a LAT_ADD (%0d)",
                   NSTREAMS, LAT_ADD);
            $finish;
        end
        if (LAT_FAST != 0) begin
            $error("takum_prng_core_multi: exige FAST_REG=0 (caminho rapido combinacional)");
            $finish;
        end
    end

    // ---- turno ----------------------------------------------------------------
    logic [SW-1:0] turn;

    // ---- estado por fluxo ------------------------------------------------------
    logic [N-1:0]  r_t  [0:NSTREAMS-1];
    logic [N-1:0]  r_s  [0:NSTREAMS-1];
    log_int_t      r_a  [0:NSTREAMS-1];
    log_int_t      r_b  [0:NSTREAMS-1];
    logic [31:0]   lfsr [0:NSTREAMS-1];
    logic [2:0]    idx_t[0:NSTREAMS-1];
    logic [2:0]    idx_s[0:NSTREAMS-1];
    logic [5:0]    mb_t [0:NSTREAMS-1];
    logic [5:0]    mb_s [0:NSTREAMS-1];
    logic [WF-1:0] mt   [0:NSTREAMS-1];
    logic [WF-1:0] ms   [0:NSTREAMS-1];
    logic          need_inv_t [0:NSTREAMS-1];
    logic          need_inv_s [0:NSTREAMS-1];

    typedef enum logic [2:0] {
        ST_MAPS, ST_LFSR, ST_PERT_T, ST_INV_T, ST_PERT_S, ST_INV_S, ST_EMIT
    } state_t;

    state_t     state [0:NSTREAMS-1];
    logic [3:0] step  [0:NSTREAMS-1];

    typedef enum logic [1:0] { DST_A, DST_B, DST_T, DST_S } dst_t;

    // SUB em voo: destino a gravar quando o resultado chegar, no proximo turno.
    logic  pend_sub [0:NSTREAMS-1];
    dst_t  pend_dst [0:NSTREAMS-1];

    // ---- fluxo do turno --------------------------------------------------------
    logic [N-1:0] c_r_t, c_r_s;
    log_int_t     c_r_a, c_r_b;
    logic [31:0]  c_lfsr;
    state_t       c_state;
    logic [3:0]   c_step;

    assign c_r_t   = r_t  [turn];
    assign c_r_s   = r_s  [turn];
    assign c_lfsr  = lfsr [turn];
    assign c_state = state[turn];
    assign c_step  = step [turn];

    // ---- ALU -------------------------------------------------------------------
    logic     op_sub, op_div;
    dst_t     dst;
    log_int_t alu_a, alu_b, res_fast, res_add, res_cur;

    takum_log_alu_fused #(
        .N           (N),
        .EXTRA_STAGE (EXTRA_STAGE),
        .FAST_REG    (FAST_REG),
        .LUT_DIR     (LUT_DIR)
    ) u_alu (
        .clk_i      (clk_i),
        .en_i       (1'b1),       // o barril nunca para: cada turno chega na hora
        .sub_i      (op_sub),
        .div_i      (op_div),
        .a_i        (alu_a),
        .b_i        (alu_b),
        .res_fast_o (res_fast),
        .res_add_o  (res_add)
    );

    // Encaminhamento: enquanto um SUB esta em voo para r_a ou r_b deste fluxo, o
    // valor corrente daquele registrador e o que sai do somador AGORA, nao o que
    // esta gravado.
    logic fwd_a, fwd_b;
    assign fwd_a = pend_sub[turn] && (pend_dst[turn] == DST_A);
    assign fwd_b = pend_sub[turn] && (pend_dst[turn] == DST_B);

    assign c_r_a = fwd_a ? res_add : r_a[turn];
    assign c_r_b = fwd_b ? res_add : r_b[turn];

    // ---- microcodigo -----------------------------------------------------------
    logic [N-1:0] a_tk, b_tk;
    logic         a_is_int, b_is_int;
    log_int_t     a_int_src, b_int_src;

    logic t_lt_half;
    assign t_lt_half = $signed(c_r_t) < $signed(C_HALF);

    always_comb begin
        op_sub    = 1'b0;
        op_div    = 1'b0;
        dst       = DST_A;
        a_tk      = C_ONE;
        b_tk      = c_r_t;
        a_is_int  = 1'b0;
        b_is_int  = 1'b0;
        a_int_src = c_r_a;
        b_int_src = c_r_b;

        case (c_state)
            ST_MAPS:
                case (c_step)
                    4'd0: begin op_sub = 1'b1; a_tk = C_ONE; b_tk = c_r_t; dst = DST_A; end
                    4'd1: begin
                        a_tk = C_MU;
                        if (t_lt_half) begin b_tk = c_r_t; end
                        else           begin b_is_int = 1'b1; b_int_src = c_r_a; end
                        dst = DST_T;
                    end
                    4'd2: begin op_sub = 1'b1; a_tk = C_ONE; b_tk = c_r_s; dst = DST_A; end
                    4'd3: begin a_tk = c_r_s; b_is_int = 1'b1; b_int_src = c_r_a; dst = DST_B; end
                    4'd4: begin a_tk = C_R16; b_is_int = 1'b1; b_int_src = c_r_b; dst = DST_A; end
                    4'd5: begin a_tk = C_C4;  b_is_int = 1'b1; b_int_src = c_r_b; dst = DST_B; end
                    4'd6: begin op_sub = 1'b1; a_tk = C_C5; b_is_int = 1'b1; b_int_src = c_r_b; dst = DST_B; end
                    // O quociente ja e S': o ganho r esta dobrado em C_R16.
                    4'd7: begin op_div = 1'b1; a_is_int = 1'b1; a_int_src = c_r_a;
                                b_is_int = 1'b1; b_int_src = c_r_b; dst = DST_S; end
                    default: ;
                endcase
            ST_INV_T: begin op_div = 1'b1; a_tk = C_ONE; b_tk = c_r_t; dst = DST_T; end
            ST_INV_S: begin op_div = 1'b1; a_tk = C_ONE; b_tk = c_r_s; dst = DST_S; end
            default: ;
        endcase
    end

    log_int_t a_tk_int, b_tk_int;
    takum_log_internal_from_takum #(.N(N)) u_cvt_a (.bits_i(a_tk), .o(a_tk_int));
    takum_log_internal_from_takum #(.N(N)) u_cvt_b (.bits_i(b_tk), .o(b_tk_int));

    assign alu_a = a_is_int ? a_int_src : a_tk_int;
    assign alu_b = b_is_int ? b_int_src : b_tk_int;

    assign res_cur = res_fast;   // SUB nunca e capturado no mesmo turno

    logic [N-1:0] res_takum, add_takum;
    takum_log_internal_to_takum #(.N(N)) u_cvt_res (.i(res_cur), .bits_o(res_takum));
    takum_log_internal_to_takum #(.N(N)) u_cvt_add (.i(res_add),  .bits_o(add_takum));

    // ---- LFSR -------------------------------------------------------------------
    function automatic logic [31:0] lfsr_advance(input logic [31:0] s);
        logic [31:0] v;
        begin
            v = s;
            for (int k = 0; k < LFSR_STEPS; k++)
                v = v[0] ? ((v >> 1) ^ LFSR_POLY) : (v >> 1);
            lfsr_advance = v;
        end
    endfunction

    // ---- perturbacao, so do fluxo do turno ---------------------------------------
    logic          col_t, col_s;
    logic [5:0]    pmb_t, pmb_s;
    logic [WF-1:0] pmt, pms;
    logic [N-1:0]  px_t, px_s;
    logic          pinv_t, pinv_s;

    takum_prng_perturb u_pert_t (
        .x_i(c_r_t), .lfsr_i(c_lfsr), .seed_i(SEEDS[idx_t[turn]]),
        .collapse_o(col_t), .m_bits_o(pmb_t), .m_out_o(pmt),
        .x_o(px_t), .need_inv_o(pinv_t)
    );

    takum_prng_perturb u_pert_s (
        .x_i(c_r_s), .lfsr_i(c_lfsr), .seed_i(SEEDS[idx_s[turn]]),
        .collapse_o(col_s), .m_bits_o(pmb_s), .m_out_o(pms),
        .x_o(px_s), .need_inv_o(pinv_s)
    );

    logic [5:0]    out_bits_c;
    logic [WF-1:0] out_mask_c, out_data_c;
    assign out_bits_c = (mb_t[turn] < mb_s[turn]) ? mb_t[turn] : mb_s[turn];
    assign out_mask_c = ({WF{1'b1}}) >> (WF - out_bits_c);
    assign out_data_c = (mt[turn] ^ ms[turn] ^ c_lfsr[WF-1:0]) & out_mask_c;

    // ---- sequenciamento -----------------------------------------------------------
    always_ff @(posedge clk_i) begin
        valid_o <= 1'b0;

        if (rst_i) begin
            turn <= '0;
            for (int k = 0; k < NSTREAMS; k++) begin
                r_t[k]        <= T_INIT_M[k];
                r_s[k]        <= S_INIT_M[k];
                r_a[k]        <= INT_ZERO;
                r_b[k]        <= INT_ZERO;
                lfsr[k]       <= LFSR_INIT_M[k];
                idx_t[k]      <= 3'd0;
                idx_s[k]      <= 3'd0;
                mb_t[k]       <= 6'd0;
                mb_s[k]       <= 6'd0;
                mt[k]         <= '0;
                ms[k]         <= '0;
                need_inv_t[k] <= 1'b0;
                need_inv_s[k] <= 1'b0;
                state[k]      <= ST_MAPS;
                step[k]       <= 4'd0;
                pend_sub[k]   <= 1'b0;
                pend_dst[k]   <= DST_A;
            end
            nbits_o <= 6'd0;
            data_o  <= '0;
        end else begin
            turn <= (turn == SW'(NSTREAMS-1)) ? '0 : turn + SW'(1);

            // Grava o SUB que estava em voo. O encaminhamento acima ja entregou
            // esse mesmo valor aos operandos deste turno, entao gravar aqui e
            // usar la nao competem.
            if (pend_sub[turn]) begin
                case (pend_dst[turn])
                    DST_A: r_a[turn] <= res_add;
                    DST_B: r_b[turn] <= res_add;
                    DST_T: r_t[turn] <= add_takum;
                    DST_S: r_s[turn] <= add_takum;
                endcase
                pend_sub[turn] <= 1'b0;
            end

            case (c_state)
                ST_MAPS: begin
                    if (op_sub) begin
                        // Emite e segue: o resultado chega no proximo turno.
                        pend_sub[turn] <= 1'b1;
                        pend_dst[turn] <= dst;
                    end else begin
                        case (dst)
                            DST_A: r_a[turn] <= res_cur;
                            DST_B: r_b[turn] <= res_cur;
                            DST_T: r_t[turn] <= res_takum;
                            DST_S: r_s[turn] <= res_takum;
                        endcase
                    end
                    if (c_step == 4'd7) begin
                        step[turn]  <= 4'd0;
                        state[turn] <= ST_LFSR;
                    end else begin
                        step[turn] <= c_step + 4'd1;
                    end
                end

                ST_LFSR: begin
                    lfsr[turn]  <= lfsr_advance(c_lfsr);
                    state[turn] <= ST_PERT_T;
                end

                ST_PERT_T: begin
                    r_t[turn]        <= px_t;
                    mb_t[turn]       <= pmb_t;
                    mt[turn]         <= pmt;
                    need_inv_t[turn] <= pinv_t;
                    if (col_t) idx_t[turn] <= idx_t[turn] + 3'd1;
                    state[turn]      <= ST_INV_T;
                end

                ST_INV_T: begin
                    if (need_inv_t[turn]) r_t[turn] <= res_takum;
                    state[turn] <= ST_PERT_S;
                end

                ST_PERT_S: begin
                    r_s[turn]        <= px_s;
                    mb_s[turn]       <= pmb_s;
                    ms[turn]         <= pms;
                    need_inv_s[turn] <= pinv_s;
                    if (col_s) idx_s[turn] <= idx_s[turn] + 3'd1;
                    state[turn]      <= ST_INV_S;
                end

                ST_INV_S: begin
                    if (need_inv_s[turn]) r_s[turn] <= res_takum;
                    state[turn] <= ST_EMIT;
                end

                ST_EMIT: begin
                    if (ready_i) begin
                        nbits_o     <= out_bits_c;
                        data_o      <= out_data_c;
                        valid_o     <= 1'b1;
                        r_t[turn]   <= r_s[turn];   // troca: o acoplamento 2D
                        r_s[turn]   <= r_t[turn];
                        state[turn] <= ST_MAPS;
                        step[turn]  <= 4'd0;
                    end
                end

                default: state[turn] <= ST_MAPS;
            endcase
        end
    end

endmodule : takum_prng_core_multi
