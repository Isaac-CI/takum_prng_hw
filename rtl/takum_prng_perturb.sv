// -----------------------------------------------------------------------------
// takum_prng_perturb
//
// Passos 4 e 5 do gerador: inspeciona um estado caotico, extrai a mantissa,
// injeta entropia do LFSR e decide a salvaguarda. Puramente combinacional.
//
// Duas coisas mudam em relacao ao original em float32:
//
//   * A mantissa nao tem largura fixa. Em IEEE754 sao sempre 23 bits; aqui o
//     campo M ocupa p = WF - r bits, com r vindo do regime, entao p varia de
//     20 a 27. O gerador de referencia ja previa isso, carregando m_bits de
//     cada mapa e emitindo min(m_bits_t, m_bits_s) -- e o que m_bits_o serve.
//
//   * Colapso e um teste de igualdade, nao de expoente. O takum tem padroes
//     reservados unicos para zero e NaR, entao a deteccao e exata e barata,
//     sem mascarar campo de expoente.
//
// A ordem importa e segue o original: a mantissa e capturada ANTES da
// perturbacao, e as salvaguardas sao um if/else-if -- um valor que era
// negativo passa pelo valor absoluto e NAO e testado contra 1 depois.
//
// A inversao 1/x nao e feita aqui: sai como um pedido (need_inv_o) para o
// sequenciador emitir na ALU, onde a divisao e exata no dominio logaritmico.
// -----------------------------------------------------------------------------
module takum_prng_perturb
    import takum_prng_pkg::*;
(
    input  logic [N-1:0]   x_i,          // estado apos o mapa
    input  logic [31:0]    lfsr_i,
    input  logic [N-1:0]   seed_i,       // SEEDS[idx], usada em colapso

    output logic           collapse_o,   // x era zero ou NaR
    output logic [5:0]     m_bits_o,     // p, ou 0 em colapso
    output logic [WF-1:0]  m_out_o,      // campo M antes da perturbacao
    output logic [N-1:0]   x_o,          // estado ja perturbado (e com abs)
    output logic           need_inv_o    // pede 1/x_o ao sequenciador
);

    // ---- colapso ---------------------------------------------------------
    assign collapse_o = (x_i == TK_ZERO) || (x_i == TK_NAR);

    // ---- regime -> largura da mantissa -----------------------------------
    logic       D;
    logic [2:0] Rbits;
    logic [3:0] r_val;
    logic [5:0] p_val;
    assign D     = x_i[N-2];
    assign Rbits = x_i[N-3 -: 3];
    assign r_val = D ? 4'(Rbits) : 4'(3'd7 - Rbits);
    assign p_val = 6'(WF) - 6'(r_val);

    logic [WF-1:0] mask_p;
    assign mask_p = ({WF{1'b1}}) >> (WF - p_val);

    // ---- perturbacao ------------------------------------------------------
    logic [N-1:0] x_xor;
    assign x_xor = x_i ^ {{(N-WF){1'b0}}, (lfsr_i[WF-1:0] & mask_p)};

    // ---- salvaguardas -----------------------------------------------------
    // O takum e monotonico na ordem de inteiro com sinal, entao "x < 0" e o
    // bit de sinal e "x > 1" e uma comparacao com sinal contra C_ONE. A
    // negacao e complemento de dois da palavra inteira (Proposicao 6).
    logic negative, above_one;
    assign negative  = x_xor[N-1];
    assign above_one = $signed(x_xor) > $signed(C_ONE);

    always_comb begin
        if (collapse_o) begin
            m_bits_o   = 6'd0;
            m_out_o    = '0;
            x_o        = seed_i;
            need_inv_o = 1'b0;
        end else begin
            m_bits_o   = p_val;
            m_out_o    = x_i[WF-1:0] & mask_p;
            if (negative) begin
                x_o        = (~x_xor) + 1'b1;   // valor absoluto
                need_inv_o = 1'b0;
            end else begin
                x_o        = x_xor;
                need_inv_o = above_one;         // sequenciador emite 1/x
            end
        end
    end

endmodule : takum_prng_perturb
