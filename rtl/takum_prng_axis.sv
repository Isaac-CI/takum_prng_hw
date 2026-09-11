// -----------------------------------------------------------------------------
// takum_prng_axis
//
// O PRNG caotico takum32 com saida AXI-Stream de 32 bits. E este o bloco
// reutilizavel: nucleo mais empacotador, sem nada especifico de placa, pronto
// para ser ligado a um DMA, a uma FIFO ou a qualquer consumidor AXI-Stream.
//
// Nao ha TLAST: o fluxo e continuo e sem fim, entao nao existe fronteira de
// pacote natural. Quem precisar de pacotes deve contar beats no consumidor.
//
// Vazao: depende inteiramente da variante escolhida em VARIANTE, porque o
// empacotador so repassa o que o gerador produz. Com media de 25,87 bits por
// emissao (medida sobre 200 mil iteracoes do modelo):
//
//   base      1 emissao / 48 ciclos  -> 0,54 bit/ciclo   1 beat a cada ~59 ciclos
//   fundido   1 emissao / 24 ciclos  -> 1,08 bit/ciclo   1 beat a cada ~30 ciclos
//   multi     1 emissao / 14 ciclos  -> 1,85 bit/ciclo   1 beat a cada ~17 ciclos
//   pipe      1 emissao /  1 ciclo   -> 25,87 bit/ciclo  1 beat a cada ~1,24 ciclos
//
// O empacotador aguenta a variante "pipe" sem mudanca: ele ja aceita uma
// emissao e entrega um beat no MESMO ciclo, e com 27 bits entrando contra 32
// saindo o acumulador drena sozinho -- simulado, a ocupacao nunca passa de 58
// dos 59 bits que ainda admitem outra emissao, entao ele nunca precisa recusar
// enquanto o consumidor aceitar.
// -----------------------------------------------------------------------------
module takum_prng_axis
    import takum_prng_pkg::*;
#(
    parameter int    AXIS_W      = 32,
    parameter int    ALU_LATENCY = 3,
    parameter int    EXTRA_STAGE = 1,
    // Qual gerador vai atras do empacotador. Os tres tem a mesma interface
    // (ready/valid, nbits, data) e produzem SEQUENCIAS DIFERENTES -- cada um
    // tem seu modelo de referencia e seus vetores golden:
    //
    //   "base"        takum_prng_core        48 ciclos/iteracao
    //                 model/takum_prng_model.py
    //   "fundido"     takum_prng_core_fused  24 ciclos, datapath fundido
    //                 model/takum_prng_fused_model.py
    //   "multi"       takum_prng_core_multi  14 ciclos/emissao, 3 fluxos
    //                 model/takum_prng_multi_model.py
    //   "pipe"        takum_prng_core_pipe   1 ciclo/emissao, 14 fluxos
    //                 model/takum_prng_pipe_model.py
    //
    // O empacotador e indiferente a escolha: ele so ve emissoes de largura
    // variavel, venham de um gerador ou de tres intercalados.
    parameter string VARIANTE    = "base",
    parameter string LUT_DIR     = "rtl/lns/lut/"
) (
    input  logic                clk_i,
    input  logic                rst_i,        // sincrono, ativo alto

    output logic [AXIS_W-1:0]   m_tdata_o,
    output logic                m_tvalid_o,
    input  logic                m_tready_i
);

    logic          core_valid, core_ready;
    logic [5:0]    core_nbits;
    logic [WF-1:0] core_data;

    if (VARIANTE == "pipe") begin : g_pipe
        takum_prng_core_pipe #(
            .EXTRA_STAGE (EXTRA_STAGE),
            .LUT_DIR     (LUT_DIR)
        ) u_core (
            .clk_i   (clk_i),
            .rst_i   (rst_i),
            .ready_i (core_ready),
            .valid_o (core_valid),
            .nbits_o (core_nbits),
            .data_o  (core_data)
        );
    end else if (VARIANTE == "multi") begin : g_multi
        takum_prng_core_multi #(
            .EXTRA_STAGE (EXTRA_STAGE),
            .LUT_DIR     (LUT_DIR)
        ) u_core (
            .clk_i   (clk_i),
            .rst_i   (rst_i),
            .ready_i (core_ready),
            .valid_o (core_valid),
            .nbits_o (core_nbits),
            .data_o  (core_data)
        );
    end else if (VARIANTE == "fundido") begin : g_fundido
        takum_prng_core_fused #(
            .EXTRA_STAGE (EXTRA_STAGE),
            .LUT_DIR     (LUT_DIR)
        ) u_core (
            .clk_i   (clk_i),
            .rst_i   (rst_i),
            .ready_i (core_ready),
            .valid_o (core_valid),
            .nbits_o (core_nbits),
            .data_o  (core_data)
        );
    end else begin : g_base
        takum_prng_core #(
            .ALU_LATENCY (ALU_LATENCY),
            .EXTRA_STAGE (EXTRA_STAGE),
            .LUT_DIR     (LUT_DIR)
        ) u_core (
            .clk_i   (clk_i),
            .rst_i   (rst_i),
            .ready_i (core_ready),
            .valid_o (core_valid),
            .nbits_o (core_nbits),
            .data_o  (core_data)
        );
    end

    takum_prng_packer #(
        .AXIS_W (AXIS_W)
    ) u_packer (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .s_valid_i  (core_valid),
        .s_nbits_i  (core_nbits),
        .s_data_i   (core_data),
        .s_ready_o  (core_ready),
        .m_tdata_o  (m_tdata_o),
        .m_tvalid_o (m_tvalid_o),
        .m_tready_i (m_tready_i)
    );

endmodule : takum_prng_axis
