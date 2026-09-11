// -----------------------------------------------------------------------------
// takum_prng_core_fused
//
// Mesmo PRNG caotico takum32 de takum_prng_core -- mapa tenda acoplado ao mapa
// seno de Bhaskara, perturbados por LFSR e trocados a cada iteracao -- com o
// datapath FUNDIDO: os temporarios ficam no formato interno de
// takum_log_internal_pkg e so r_t e r_s permanecem em takum.
//
// POR QUE r_t E r_s CONTINUAM EM TAKUM. Os dois sao inspecionados como palavra,
// nao como numero: takum_prng_perturb le o campo de regime para saber a largura
// p da mantissa e faz XOR do LFSR nesses p bits, e o teste T < 1/2 e uma
// comparacao de inteiro com sinal que so vale pela monotonicidade da
// codificacao. Manter esses dois no formato interno exigiria codificar antes de
// cada inspecao -- trocaria seis de meia duzia. Ja r_a e r_b nunca sao olhados:
// nascem da ALU e morrem na ALU, e sao exatamente eles que a fusao liberta.
//
// O QUE ISSO COMPRA. Na versao nao fundida toda operacao paga o par
// decodificar/codificar e fica atras do pipeline de tres estagios dimensionado
// para o somador Gauss-log: 4 ciclos cada, 48 por iteracao. Aqui cada operacao
// custa o que de fato exige:
//
//   passos 0, 2, 6   SUB, tabelas Gauss-log        LAT_ADD+1  = 4 ciclos
//   passos 1,3,4,5,7 e as duas inversoes           LAT_FAST+1 = 1 ciclo
//
// No dominio logaritmico multiplicar e somar L e dividir e subtrair L. Com as
// conversoes fora do caminho, sobra um somador de ponto fixo -- raso o bastante
// para caber no mesmo ciclo em que os operandos sao apresentados. Das dez
// operacoes, sete sao dessas.
//
//   3 SUB x 4  +  5 rapidas x 1  +  2 inversoes x 1  +  4 ciclos avulsos  =  23
//
// Vinte e tres ciclos contra quarenta e quatro, sem uma BRAM a mais, porque as
// tabelas continuam sendo uma so instancia compartilhada.
//
// ISTO PRODUZ OUTRA SEQUENCIA. Entre operacoes encadeadas nao ha mais
// codificacao, e portanto nao ha mais arredondamento para a precisao do takum.
// O resultado e mais preciso e a orbita e outra -- este nucleo NAO reproduz
// takum_prng_model.py nem os vetores golden da versao nao fundida. O modelo que
// corresponde a ele e model/takum_prng_fused_model.py.
//
// TEMPO CONSTANTE, preservado: os dois ramos do mapa tenda sao sempre
// calculados e as duas inversoes de salvaguarda sao sempre emitidas, usadas ou
// nao. Uma iteracao dura 23 ciclos independentemente dos dados.
// -----------------------------------------------------------------------------
module takum_prng_core_fused
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

    localparam int LAT_FAST = FAST_REG;
    localparam int LAT_ADD  = 2 + EXTRA_STAGE;

    // ---- estado ---------------------------------------------------------------
    logic [N-1:0] r_t, r_s;      // takum: inspecionados pela perturbacao
    log_int_t     r_a, r_b;      // interno: so a ALU os ve
    logic [31:0]  lfsr;
    logic [2:0]   idx_t, idx_s;

    logic [5:0]     mb_t, mb_s;
    logic [WF-1:0]  mt, ms;
    logic           need_inv_t, need_inv_s;

    typedef enum logic [2:0] {
        ST_MAPS, ST_LFSR, ST_PERT_T, ST_INV_T, ST_PERT_S, ST_INV_S, ST_EMIT
    } state_t;

    state_t     state;
    logic [3:0] step;
    logic [3:0] wait_cnt;

    // ---- microcodigo ----------------------------------------------------------
    // Destino de cada passo. DST_A/DST_B ficam no formato interno; DST_T/DST_S
    // passam pelo codificador no caminho de escrita.
    typedef enum logic [1:0] { DST_A, DST_B, DST_T, DST_S } dst_t;

    logic         op_sub;        // usa o somador Gauss-log (senao, caminho rapido)
    logic         op_div;        // no caminho rapido: divide em vez de multiplicar
    dst_t         dst;
    logic [3:0]   lat_cur;

    logic [N-1:0] a_tk, b_tk;    // operando vindo de palavra takum
    logic         a_is_int, b_is_int;
    log_int_t     a_int_src, b_int_src;

    logic t_lt_half;
    assign t_lt_half = $signed(r_t) < $signed(C_HALF);

    always_comb begin
        // padroes seguros: multiplicacao de 1 por r_t, descartada em DST_A
        op_sub    = 1'b0;
        op_div    = 1'b0;
        dst       = DST_A;
        a_tk      = C_ONE;
        b_tk      = r_t;
        a_is_int  = 1'b0;
        b_is_int  = 1'b0;
        a_int_src = r_a;
        b_int_src = r_b;

        case (state)
            ST_MAPS:
                case (step)
                    // A = 1 - T
                    4'd0: begin op_sub = 1'b1; a_tk = C_ONE; b_tk = r_t; dst = DST_A; end
                    // T = MU * (T < 1/2 ? T : A)
                    4'd1: begin
                        a_tk = C_MU;
                        if (t_lt_half) begin b_tk = r_t; end
                        else           begin b_is_int = 1'b1; b_int_src = r_a; end
                        dst = DST_T;
                    end
                    // A = 1 - S
                    4'd2: begin op_sub = 1'b1; a_tk = C_ONE; b_tk = r_s; dst = DST_A; end
                    // B = S * A                       -> u
                    4'd3: begin a_tk = r_s; b_is_int = 1'b1; b_int_src = r_a; dst = DST_B; end
                    // A = R16 * B                     -> 14,4u
                    4'd4: begin a_tk = C_R16; b_is_int = 1'b1; b_int_src = r_b; dst = DST_A; end
                    // B = C4 * B                      -> 4u
                    4'd5: begin a_tk = C_C4;  b_is_int = 1'b1; b_int_src = r_b; dst = DST_B; end
                    // B = C5 - B                      -> 5 - 4u
                    4'd6: begin op_sub = 1'b1; a_tk = C_C5; b_is_int = 1'b1; b_int_src = r_b; dst = DST_B; end
                    // S = A / B                       -> 14,4u/(5-4u), JA com o ganho r
                    4'd7: begin op_div = 1'b1; a_is_int = 1'b1; a_int_src = r_a;
                                b_is_int = 1'b1; b_int_src = r_b; dst = DST_S; end
                    default: ;
                endcase
            ST_INV_T: begin op_div = 1'b1; a_tk = C_ONE; b_tk = r_t; dst = DST_T; end
            ST_INV_S: begin op_div = 1'b1; a_tk = C_ONE; b_tk = r_s; dst = DST_S; end
            default: ;
        endcase

        lat_cur = op_sub ? 4'(LAT_ADD) : 4'(LAT_FAST);
    end

    // ---- operandos: conversao so nas bordas -----------------------------------
    // As constantes do pacote entram por aqui como qualquer outra palavra takum;
    // a sintese dobra esses decodificadores em constantes, entao eles nao custam
    // logica nenhuma.
    log_int_t a_tk_int, b_tk_int, alu_a, alu_b;

    takum_log_internal_from_takum #(.N(N)) u_cvt_a (.bits_i(a_tk), .o(a_tk_int));
    takum_log_internal_from_takum #(.N(N)) u_cvt_b (.bits_i(b_tk), .o(b_tk_int));

    assign alu_a = a_is_int ? a_int_src : a_tk_int;
    assign alu_b = b_is_int ? b_int_src : b_tk_int;

    // ---- ALU -------------------------------------------------------------------
    log_int_t res_fast, res_add, res_cur;

    takum_log_alu_fused #(
        .N           (N),
        .EXTRA_STAGE (EXTRA_STAGE),
        .FAST_REG    (FAST_REG),
        .LUT_DIR     (LUT_DIR)
    ) u_alu (
        .clk_i      (clk_i),
        .en_i       (1'b1),       // o sequenciador espera a ALU, nunca a congela
        .sub_i      (op_sub),
        .div_i      (op_div),
        .a_i        (alu_a),
        .b_i        (alu_b),
        .res_fast_o (res_fast),
        .res_add_o  (res_add)
    );

    assign res_cur = op_sub ? res_add : res_fast;

    // Codificador unico no caminho de escrita para r_t / r_s. So um destino e
    // takum por vez, entao uma instancia basta.
    logic [N-1:0] res_takum;
    takum_log_internal_to_takum #(.N(N)) u_cvt_res (.i(res_cur), .bits_o(res_takum));

    logic alu_done;
    assign alu_done = (wait_cnt == lat_cur);

    // ---- LFSR de Galois --------------------------------------------------------
    function automatic logic [31:0] lfsr_advance(input logic [31:0] s);
        logic [31:0] v;
        begin
            v = s;
            for (int k = 0; k < LFSR_STEPS; k++)
                v = v[0] ? ((v >> 1) ^ LFSR_POLY) : (v >> 1);
            lfsr_advance = v;
        end
    endfunction

    // ---- perturbacao -----------------------------------------------------------
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

    // ---- saida ------------------------------------------------------------------
    logic [5:0]    out_bits_c;
    logic [WF-1:0] out_mask_c, out_data_c;
    assign out_bits_c = (mb_t < mb_s) ? mb_t : mb_s;
    assign out_mask_c = ({WF{1'b1}}) >> (WF - out_bits_c);
    assign out_data_c = (mt ^ ms ^ lfsr[WF-1:0]) & out_mask_c;

    // ---- sequenciamento ---------------------------------------------------------
    task automatic escreve_destino();
        case (dst)
            DST_A: r_a <= res_cur;
            DST_B: r_b <= res_cur;
            DST_T: r_t <= res_takum;
            DST_S: r_s <= res_takum;
        endcase
    endtask

    always_ff @(posedge clk_i) begin
        valid_o <= 1'b0;

        if (rst_i) begin
            state      <= ST_MAPS;
            step       <= 4'd0;
            wait_cnt   <= 4'd0;
            r_t        <= T_INIT;
            r_s        <= S_INIT;
            r_a        <= INT_ZERO;
            r_b        <= INT_ZERO;
            lfsr       <= LFSR_INIT;
            idx_t      <= 3'd0;
            idx_s      <= 3'd0;
            need_inv_t <= 1'b0;
            need_inv_s <= 1'b0;
            mb_t       <= 6'd0;
            mb_s       <= 6'd0;
            mt         <= '0;
            ms         <= '0;
            nbits_o    <= 6'd0;
            data_o     <= '0;
        end else begin
            case (state)
                ST_MAPS: begin
                    if (!alu_done) begin
                        wait_cnt <= wait_cnt + 4'd1;
                    end else begin
                        wait_cnt <= 4'd0;
                        escreve_destino();
                        if (step == 4'd7) begin
                            step  <= 4'd0;
                            state <= ST_LFSR;
                        end else begin
                            step <= step + 4'd1;
                        end
                    end
                end

                ST_LFSR: begin
                    lfsr  <= lfsr_advance(lfsr);
                    state <= ST_PERT_T;
                end

                ST_PERT_T: begin
                    r_t        <= px_t;
                    mb_t       <= pmb_t;
                    mt         <= pmt;
                    need_inv_t <= pinv_t;
                    if (col_t) idx_t <= idx_t + 3'd1;
                    state      <= ST_INV_T;
                    wait_cnt   <= 4'd0;
                end

                ST_INV_T: begin
                    if (!alu_done) begin
                        wait_cnt <= wait_cnt + 4'd1;
                    end else begin
                        wait_cnt <= 4'd0;
                        if (need_inv_t) r_t <= res_takum;
                        state <= ST_PERT_S;
                    end
                end

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
                        if (need_inv_s) r_s <= res_takum;
                        state <= ST_EMIT;
                    end
                end

                ST_EMIT: begin
                    if (ready_i) begin
                        nbits_o  <= out_bits_c;
                        data_o   <= out_data_c;
                        valid_o  <= 1'b1;
                        r_t      <= r_s;      // troca: o acoplamento 2D
                        r_s      <= r_t;
                        state    <= ST_MAPS;
                        step     <= 4'd0;
                        wait_cnt <= 4'd0;
                    end
                end

                default: state <= ST_MAPS;
            endcase
        end
    end

endmodule : takum_prng_core_fused
