// -----------------------------------------------------------------------------
// takum_prng_core_pipe
//
// O mesmo PRNG caotico takum32 das outras variantes, com as dez operacoes
// DESENROLADAS NO ESPACO: cada uma tem sua propria unidade aritmetica, ligada
// em cadeia, e o conjunto forma um ANEL de NPIPE estagios que emite um numero
// POR CICLO.
//
// POR QUE DESENROLAR SOZINHO NAO BASTARIA. As dez operacoes de uma iteracao
// nao sao independentes -- sao uma cadeia de dependencias (1-S alimenta S*A,
// que alimenta C4*B, que alimenta C5-B, que alimenta A/B). Instanciar dez
// unidades e mandar um fluxo so atravessa-las deixaria nove ociosas a cada
// instante: dez vezes a area para a mesma vazao. O que o desenrolamento
// habilita nao e paralelismo dentro de uma iteracao, e PIPELINE entre
// iteracoes.
//
// E O QUE PREENCHE O PIPELINE SAO OS FLUXOS. O mapa e uma recorrencia --
// x(n+1) = f(x(n)) -- entao um fluxo sozinho nao tem o que injetar enquanto
// sua propria iteracao nao termina, e o pipeline andaria vazio. Com NPIPE
// fluxos independentes, um por estagio, ele anda cheio o tempo todo. E aqui
// esta a economia que faz o desenho fechar: os fluxos NAO custam banco de
// registradores, porque o estado de cada um E o conteudo dos registradores de
// pipeline, andando um estagio por ciclo. Some tudo que o nucleo intercalado
// precisava para dividir uma ALU no tempo:
//
//   * o banco r_t/r_s/r_a/r_b/lfsr por fluxo        -> sao os proprios tok[]
//   * os multiplexadores de operando (turno -> ALU) -> operandos sao fixos
//   * o encaminhamento do somador em voo            -> nao ha o que encaminhar
//   * o contador de turno                           -> nao ha turno
//
// Medido: a intercalacao custou +2399 LUT e +715 FF sobre o nucleo fundido so
// nessa infraestrutura. O pipeline espacial gasta esse orcamento em aritmetica
// util.
//
// O PRECO, E COMO ELE FOI CORTADO. Sao tres subtracoes por iteracao, e no
// desenrolamento espacial todas trabalham a cada ciclo -- logo, tres caminhos
// Gauss-log simultaneos. Nao ha especializacao a explorar: as tres sao
// subtracoes de operandos de mesmo sinal, todas caem em Phi-, e Phi- usa TODAS
// as tabelas (o ramo direto usa exp2m/ln2p e o ramo de q pequeno usa
// ln1p/lng/k_table), entao nenhuma delas pode ficar sem uma tabela.
//
// Mas tres CAMINHOS nao exigem tres conjuntos de TABELAS. Duas das subtracoes
// -- 1-T e 1-S -- estao no mesmo estagio: sao apresentadas juntas e colhidas
// juntas, em lock-step por construcao. Uma block RAM tem duas portas, entao
// elas dividem um conjunto so (takum_log_internal_add com WAYS=2). A terceira,
// 5-4u, mora quatro estagios adiante e precisa do seu. Dois conjuntos em vez
// de tres: 2 x 53 = 106 RAMB36 dos 312 do xczu7ev, contra os 159 que tres
// instancias separadas custariam.
//
// ESTA E A MESMA SEQUENCIA DO NUCLEO FUNDIDO. A ordem das operacoes e os
// pontos de arredondamento sao identicos aos de takum_prng_core_fused -- so T
// e S voltam a takum, r_a/r_b nunca -- entao o fluxo k daqui reproduz
// exatamente model/takum_prng_fused_model.py com a semente k. Os tres
// primeiros fluxos usam as sementes de takum_prng_core_multi de proposito, de
// modo que o fluxo k dos dois nucleos coincide bit a bit para k < 3.
//
// TEMPO CONSTANTE. Todo estagio dura um ciclo, sempre, e nenhum caminho depende
// do dado para durar o que dura: os dois ramos do mapa tenda sao calculados e
// as duas inversoes de salvaguarda sao emitidas, usadas ou nao. O instante de
// cada emissao e funcao apenas do ciclo, nao do estado.
//
// CONGELAMENTO. Com uma emissao por ciclo o empacotador pode recusar, e um
// anel nao tem para onde escoar: `en` congela TUDO junto, inclusive os
// registradores internos das unidades Gauss-log (dai en_i existir nelas).
// Congelar so os estagios externos adiantaria os pares em voo dentro das
// tabelas em relacao aos estagios que vao consumi-los, silenciosamente.
// -----------------------------------------------------------------------------
module takum_prng_core_pipe
    import takum_prng_pkg::*;
    import takum_log_pkg::*;
    import takum_log_internal_pkg::*;
#(
    parameter int    EXTRA_STAGE = 1,
    parameter string LUT_DIR     = "rtl/lns/lut/"
) (
    input  logic            clk_i,
    input  logic            rst_i,        // sincrono, ativo alto
    input  logic            ready_i,
    output logic            valid_o,
    output logic [5:0]      nbits_o,
    output logic [WF-1:0]   data_o
);

    localparam int LAT_ADD = 2 + EXTRA_STAGE;   // latencia da unidade Gauss-log

    // ---- mapa dos estagios ----------------------------------------------------
    // Convencao: tok[k] e um REGISTRADOR; a logica combinacional do estagio k
    // le tok[k] e produz o que entra em tok[k+1]. Um token que esta em tok[k]
    // no ciclo c esta em tok[k+1] no ciclo c+1.
    //
    // Uma subtracao apresentada pelo estagio P tem o resultado combinacional
    // disponivel no ciclo em que o token chega em tok[P+LAT_ADD] -- e o estagio
    // P+LAT_ADD que o COLHE, gravando-o no token seguinte. Derivar os indices
    // de LAT_ADD em vez de escreve-los faz um EXTRA_STAGE diferente reposicionar
    // o anel inteiro sozinho, em vez de desalinhar em silencio.
    localparam int S_PRES_TS = 0;                     // apresenta 1-T e 1-S
    localparam int S_CATCH_TS= S_PRES_TS + LAT_ADD;   // colhe P e Q
    localparam int S_MAP_T   = S_CATCH_TS + 1;        // T' = MU*(T<1/2 ? T : P); u = S*Q
    localparam int S_SPLIT   = S_MAP_T + 1;           // n = 14,4u; d4 = 4u
    localparam int S_PRES_D  = S_SPLIT + 1;           // apresenta C5 - 4u
    localparam int S_CATCH_D = S_PRES_D + LAT_ADD;    // colhe d
    localparam int S_MAP_S   = S_CATCH_D + 1;         // S' = n/d; avanca o LFSR
    localparam int S_PERT    = S_MAP_S + 1;           // perturba T' e S'
    localparam int S_EMIT    = S_PERT + 1;            // inverte se pedido, emite, troca
    localparam int DEPTH     = S_EMIT + 1;

    initial begin
        if (DEPTH != NPIPE) begin
            $error("takum_prng_core_pipe: a profundidade do anel e %0d mas o pacote define NPIPE=%0d; gere as sementes de novo com model/gen_pipe_seeds.py",
                   DEPTH, NPIPE);
            $finish;
        end
    end

    // ---- o token -------------------------------------------------------------
    // Tudo que um fluxo carrega ao redor do anel. Varios campos so vivem em um
    // trecho -- va/vb entre os mapas, mb/m/inv entre a perturbacao e a emissao
    // -- e poderiam morar em registradores dedicados de um estagio so. Ficam no
    // token de proposito: assim CADA campo anda junto com o fluxo a que
    // pertence por construcao, e nao ha como desalinhar um deles. Sao ~950 FF
    // a mais num orcamento de centenas de milhares.
    typedef struct packed {
        logic          vld;      // ha um fluxo de verdade neste estagio
        logic [N-1:0]  t;        // takum: estado do mapa tenda
        logic [N-1:0]  s;        // takum: estado do mapa seno
        logic [31:0]   lfsr;
        logic [2:0]    idx_t;    // proxima semente de resgate de cada mapa
        logic [2:0]    idx_s;
        log_int_t      va;       // interno: P, depois n
        log_int_t      vb;       // interno: Q, depois u, 4u, d
        logic [5:0]    mb_t;     // colhidos na perturbacao, usados na emissao
        logic [5:0]    mb_s;
        logic [WF-1:0] mt;
        logic [WF-1:0] ms;
        logic          inv_t;
        logic          inv_s;
    } tok_t;

    tok_t tok [0:NPIPE-1];
    tok_t nxt [1:NPIPE-1];       // nxt[k] entra em tok[k]; tok[0] vem da cabeca
    tok_t cabeca, semente;

    // ---- congelamento --------------------------------------------------------
    // Produtor valid/ready comum: o anel anda a menos que haja uma emissao
    // pendente que o empacotador nao aceita. Nao ha laco combinacional --
    // s_ready_o do empacotador depende so do contador dele, que e registrado.
    logic en;
    assign valid_o = tok[S_EMIT].vld;
    assign en      = !valid_o || ready_i;

    // ---- constantes no formato interno ---------------------------------------
    // Decodificadores de entrada constante: a sintese os dobra em constantes,
    // entao nao custam logica.
    log_int_t k_one, k_mu, k_r16, k_c4, k_c5;
    takum_log_internal_from_takum #(.N(N)) u_k_one (.bits_i(C_ONE), .o(k_one));
    takum_log_internal_from_takum #(.N(N)) u_k_mu  (.bits_i(C_MU),  .o(k_mu));
    takum_log_internal_from_takum #(.N(N)) u_k_r16 (.bits_i(C_R16), .o(k_r16));
    takum_log_internal_from_takum #(.N(N)) u_k_c4  (.bits_i(C_C4),  .o(k_c4));
    takum_log_internal_from_takum #(.N(N)) u_k_c5  (.bits_i(C_C5),  .o(k_c5));

    // =========================================================================
    // ESTAGIO S_PRES_TS: as duas subtracoes 1-T e 1-S, em paralelo
    //
    // Sao independentes uma da outra -- o nucleo sequencial as fazia nos passos
    // 0 e 2 apenas porque tinha um somador so. Aqui cada uma tem o seu, e as
    // duas partem do mesmo ciclo.
    // =========================================================================
    // UMA INSTANCIA COM DUAS VIAS, nao duas instancias. As duas subtracoes
    // estao no MESMO estagio -- sao apresentadas juntas e colhidas juntas --
    // que e exatamente a condicao para dividirem as tabelas pelas duas portas
    // da block RAM. Duas instancias separadas guardariam as mesmas constantes
    // duas vezes e custariam 53 RAMB36 a mais sem calcular nada de novo.
    log_int_t dec_t0, dec_s0;
    log_int_t [1:0] gl_ts_a, gl_ts_b, res_gl_ts;

    takum_log_internal_from_takum #(.N(N)) u_dec_t0 (.bits_i(tok[S_PRES_TS].t), .o(dec_t0));
    takum_log_internal_from_takum #(.N(N)) u_dec_s0 (.bits_i(tok[S_PRES_TS].s), .o(dec_s0));

    assign gl_ts_a = '{k_one, k_one};
    assign gl_ts_b = '{dec_s0, dec_t0};   // via 0 = 1-T, via 1 = 1-S

    takum_log_internal_add #(
        .EXTRA_STAGE (EXTRA_STAGE), .WAYS (2), .LUT_DIR (LUT_DIR)
    ) u_gl_ts (
        .clk_i (clk_i), .en_i (en),
        .a (gl_ts_a), .b (gl_ts_b), .sub_i (2'b11), .o (res_gl_ts)
    );

    // =========================================================================
    // ESTAGIO S_MAP_T: fecha o mapa tenda e abre o mapa seno
    // =========================================================================
    log_int_t dec_tm, dec_sm, sel_t, t1_int, u_int;
    logic     t_lt_half;
    logic [N-1:0] t1_takum;

    takum_log_internal_from_takum #(.N(N)) u_dec_tm (.bits_i(tok[S_MAP_T].t), .o(dec_tm));
    takum_log_internal_from_takum #(.N(N)) u_dec_sm (.bits_i(tok[S_MAP_T].s), .o(dec_sm));

    // O takum e monotonico na ordem de inteiro com sinal, entao o ramo do mapa
    // tenda e uma comparacao de palavra -- e sobre o T de ENTRADA, ainda nao
    // atualizado, que e o que este estagio ainda tem em maos.
    assign t_lt_half = $signed(tok[S_MAP_T].t) < $signed(C_HALF);
    assign sel_t     = t_lt_half ? dec_tm : tok[S_MAP_T].va;

    takum_log_internal_mul u_mul_t (.a (k_mu),   .b (sel_t),            .o (t1_int));
    takum_log_internal_mul u_mul_u (.a (dec_sm), .b (tok[S_MAP_T].vb),  .o (u_int));

    takum_log_internal_to_takum #(.N(N)) u_enc_t (.i (t1_int), .bits_o (t1_takum));

    // =========================================================================
    // ESTAGIO S_SPLIT: 14,4u e 4u, independentes entre si
    // =========================================================================
    log_int_t n_int, d4_int;
    takum_log_internal_mul u_mul_n  (.a (k_r16), .b (tok[S_SPLIT].vb), .o (n_int));
    takum_log_internal_mul u_mul_d4 (.a (k_c4),  .b (tok[S_SPLIT].vb), .o (d4_int));

    // =========================================================================
    // ESTAGIO S_PRES_D: a terceira subtracao, 5 - 4u
    //
    // Os operandos vem direto de um registrador, nao da saida de um
    // multiplicador: por isso 14,4u/4u ganharam o seu proprio estagio em vez de
    // ficarem no mesmo ciclo. A unidade Gauss-log comeca com uma multiplicacao
    // por 1/(2 ln2) e um detector de bit mais significativo, e por um somador
    // de 78 bits antes dela o caminho critico do anel mudaria de lugar.
    // =========================================================================
    log_int_t res_gl_d;
    takum_log_internal_add #(
        .EXTRA_STAGE (EXTRA_STAGE), .WAYS (1), .LUT_DIR (LUT_DIR)
    ) u_gl_d (
        .clk_i (clk_i), .en_i (en),
        .a (k_c5), .b (tok[S_PRES_D].vb), .sub_i (1'b1), .o (res_gl_d)
    );

    // =========================================================================
    // ESTAGIO S_MAP_S: 14,4u/(5-4u), que JA E S'
    //
    // Com o ganho r dobrado em C_R16 o quociente sai pronto -- nao ha mais um
    // estagio multiplicando por 0,9 depois dele, e o anel encurtou de 14 para
    // 13. O estagio economizado nao vale so um ciclo de latencia: vale um
    // fluxo a menos, uma semente a menos e um registrador de token a menos.
    // =========================================================================
    log_int_t s1_int;
    logic [N-1:0] s1_takum;

    takum_log_internal_div u_div_s (.a (tok[S_MAP_S].va), .b (tok[S_MAP_S].vb), .o (s1_int));
    takum_log_internal_to_takum #(.N(N)) u_enc_s (.i (s1_int), .bits_o (s1_takum));

    // ---- LFSR de Galois, no mesmo estagio: independente do mapa --------------
    function automatic logic [31:0] lfsr_advance(input logic [31:0] s);
        logic [31:0] v;
        begin
            v = s;
            for (int k = 0; k < LFSR_STEPS; k++)
                v = v[0] ? ((v >> 1) ^ LFSR_POLY) : (v >> 1);
            lfsr_advance = v;
        end
    endfunction

    logic [31:0] lfsr_nxt;
    assign lfsr_nxt = lfsr_advance(tok[S_MAP_S].lfsr);

    // =========================================================================
    // ESTAGIO S_PERT: perturba os dois mapas, em paralelo
    //
    // As duas perturbacoes leem registradores diferentes e o MESMO LFSR ja
    // avancado, entao sao independentes -- o nucleo sequencial as separava so
    // por ter uma ALU. A mantissa e capturada ANTES da perturbacao, e e ela
    // que vai para a saida; a inversao de salvaguarda vem depois e nao a afeta.
    // =========================================================================
    logic          col_t, col_s, pinv_t, pinv_s;
    logic [5:0]    pmb_t, pmb_s;
    logic [WF-1:0] pmt, pms;
    logic [N-1:0]  px_t, px_s;

    takum_prng_perturb u_pert_t (
        .x_i(tok[S_PERT].t), .lfsr_i(tok[S_PERT].lfsr), .seed_i(SEEDS[tok[S_PERT].idx_t]),
        .collapse_o(col_t), .m_bits_o(pmb_t), .m_out_o(pmt),
        .x_o(px_t), .need_inv_o(pinv_t)
    );

    takum_prng_perturb u_pert_s (
        .x_i(tok[S_PERT].s), .lfsr_i(tok[S_PERT].lfsr), .seed_i(SEEDS[tok[S_PERT].idx_s]),
        .collapse_o(col_s), .m_bits_o(pmb_s), .m_out_o(pms),
        .x_o(px_s), .need_inv_o(pinv_s)
    );

    // =========================================================================
    // ESTAGIO S_EMIT: as duas inversoes, a emissao e a troca
    // =========================================================================
    log_int_t dec_pt, dec_ps, it_int, is_int;
    logic [N-1:0] it_takum, is_takum, t2, s2;

    takum_log_internal_from_takum #(.N(N)) u_dec_pt (.bits_i(tok[S_EMIT].t), .o(dec_pt));
    takum_log_internal_from_takum #(.N(N)) u_dec_ps (.bits_i(tok[S_EMIT].s), .o(dec_ps));

    takum_log_internal_div u_div_it (.a (k_one), .b (dec_pt), .o (it_int));
    takum_log_internal_div u_div_is (.a (k_one), .b (dec_ps), .o (is_int));

    takum_log_internal_to_takum #(.N(N)) u_enc_it (.i (it_int), .bits_o (it_takum));
    takum_log_internal_to_takum #(.N(N)) u_enc_is (.i (is_int), .bits_o (is_takum));

    assign t2 = tok[S_EMIT].inv_t ? it_takum : tok[S_EMIT].t;
    assign s2 = tok[S_EMIT].inv_s ? is_takum : tok[S_EMIT].s;

    logic [5:0]    out_bits_c;
    logic [WF-1:0] out_mask_c;
    assign out_bits_c = (tok[S_EMIT].mb_t < tok[S_EMIT].mb_s) ? tok[S_EMIT].mb_t
                                                              : tok[S_EMIT].mb_s;
    assign out_mask_c = ({WF{1'b1}}) >> (WF - out_bits_c);

    assign nbits_o = out_bits_c;
    assign data_o  = (tok[S_EMIT].mt ^ tok[S_EMIT].ms
                      ^ tok[S_EMIT].lfsr[WF-1:0]) & out_mask_c;

    // =========================================================================
    // O anel
    // =========================================================================
    always_comb begin
        // Por padrao todo estagio apenas repassa o token adiante; os estagios
        // que fazem alguma coisa sobrescrevem os campos que produzem. Ler a
        // lista de sobrescritas abaixo e ler o microcodigo inteiro.
        for (int k = 1; k < NPIPE; k++) nxt[k] = tok[k-1];

        nxt[S_CATCH_TS+1].va = res_gl_ts[0];             // P = 1 - T
        nxt[S_CATCH_TS+1].vb = res_gl_ts[1];             // Q = 1 - S

        nxt[S_MAP_T+1].t     = t1_takum;             // T' = MU*(T<1/2 ? T : P)
        nxt[S_MAP_T+1].vb    = u_int;                // u  = S*Q

        nxt[S_SPLIT+1].va    = n_int;                // n  = 14,4u
        nxt[S_SPLIT+1].vb    = d4_int;               // 4u

        nxt[S_CATCH_D+1].vb  = res_gl_d;             // d  = 5 - 4u

        nxt[S_MAP_S+1].s     = s1_takum;             // S' = n/d, ja com o ganho r
        nxt[S_MAP_S+1].lfsr  = lfsr_nxt;

        nxt[S_PERT+1].t      = px_t;
        nxt[S_PERT+1].s      = px_s;
        nxt[S_PERT+1].mb_t   = pmb_t;
        nxt[S_PERT+1].mb_s   = pmb_s;
        nxt[S_PERT+1].mt     = pmt;
        nxt[S_PERT+1].ms     = pms;
        nxt[S_PERT+1].inv_t  = pinv_t;
        nxt[S_PERT+1].inv_s  = pinv_s;
        nxt[S_PERT+1].idx_t  = tok[S_PERT].idx_t + (col_t ? 3'd1 : 3'd0);
        nxt[S_PERT+1].idx_s  = tok[S_PERT].idx_s + (col_s ? 3'd1 : 3'd0);

        // A cabeca fecha o anel: o token emitido volta ao estagio 0 ja com a
        // troca T <-> S, que e o acoplamento 2D entre os dois mapas.
        cabeca       = tok[S_EMIT];
        cabeca.t     = s2;
        cabeca.s     = t2;
        cabeca.va    = INT_ZERO;    // mortos ate o proximo mapa; zerados para
        cabeca.vb    = INT_ZERO;    // que a onda nao carregue lixo da volta anterior
        cabeca.mb_t  = 6'd0;
        cabeca.mb_s  = 6'd0;
        cabeca.mt    = '0;
        cabeca.ms    = '0;
        cabeca.inv_t = 1'b0;
        cabeca.inv_s = 1'b0;
    end

    // ---- enchimento ----------------------------------------------------------
    // Nos primeiros NPIPE ciclos o estagio 0 recebe uma semente nova por ciclo
    // em vez da realimentacao. O fluxo k entra no ciclo k, chega ao estagio de
    // emissao no ciclo k + S_EMIT e volta ao estagio 0 no ciclo k + NPIPE --
    // exatamente quando o enchimento acabou, sem lacuna e sem disputa pela
    // entrada. Dai a ordem de saida ser 0, 1, ..., NPIPE-1, 0, 1, ..., que e a
    // ordem que o modelo de referencia reproduz.
    localparam int FW_CNT = $clog2(NPIPE + 1);
    logic [FW_CNT-1:0] fill;
    logic              enchendo;
    assign enchendo = (fill != FW_CNT'(NPIPE));

    always_comb begin
        semente       = '0;
        semente.vld   = 1'b1;
        semente.t     = T_INIT_P[fill];
        semente.s     = S_INIT_P[fill];
        semente.lfsr  = LFSR_INIT_P[fill];
        semente.va    = INT_ZERO;
        semente.vb    = INT_ZERO;
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int k = 0; k < NPIPE; k++) begin
                tok[k]     <= '0;
                tok[k].vld <= 1'b0;   // nada a emitir ate o anel encher
            end
            fill <= '0;
        end else if (en) begin
            for (int k = 1; k < NPIPE; k++) tok[k] <= nxt[k];
            tok[0] <= enchendo ? semente : cabeca;
            if (enchendo) fill <= fill + FW_CNT'(1);
        end
    end

endmodule : takum_prng_core_pipe
