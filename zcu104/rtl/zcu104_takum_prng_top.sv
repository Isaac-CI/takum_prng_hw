// -----------------------------------------------------------------------------
// zcu104_takum_prng_top
//
// Topo do PRNG caotico takum32 para a ZCU104.
//
// O bloco reutilizavel e o takum_prng_axis: nucleo mais empacotador, com uma
// saida AXI-Stream de 32 bits, pronto para ser ligado a um DMA no PS, a uma
// FIFO ou a qualquer consumidor AXIS. Este topo existe para dar um bitstream
// que roda sozinho na placa e um numero de timing honesto, entao consome o
// stream internamente: um dreno sempre pronto dobra cada beat numa assinatura
// que chega aos LEDs.
//
// Para levar os bits para fora de verdade -- que e o que interessa para rodar
// a bateria NIST -- o caminho e instanciar takum_prng_axis num block design e
// ligar o AXIS a um AXI DMA do PS. Isso nao esta aqui: exigiria um block
// design com o Zynq MPSoC, que e outra ordem de trabalho e nao muda nada do
// PRNG em si.
//
// CLOCK. Igual ao projeto da ALU: 300 MHz diferenciais em CLK_300_P/N, com um
// BUFGCE_DIV dividindo por 4 na propria rede de clock -- 75 MHz, sem MMCM e
// sem divisor em fabric.
//
// SEM RESET EXTERNO. Os registradores partem do INIT gravado na configuracao
// do FPGA. O botao CPU_RESET ficou de fora porque o board file nao documenta
// a polaridade dele, e chutar errado deixaria o design preso em reset. O
// reset interno do PRNG e pulsado por alguns ciclos na partida para carregar
// as sementes.
// -----------------------------------------------------------------------------
module zcu104_takum_prng_top #(
    parameter string LUT_DIR = "",   // caminho absoluto das ROMs (.mem)
    // Qual gerador vai dentro do takum_prng_axis -- ver a lista de variantes
    // no cabecalho daquele modulo. Repassado por -generic no build, para que o
    // mesmo topo sirva as quatro sem um arquivo por variante.
    parameter string VARIANTE = "base"
) (
    input  logic       clk_300_p_i,
    input  logic       clk_300_n_i,
    output logic [3:0] led_o
);

    // ---- clock: 300 MHz diferencial -> 75 MHz -------------------------------
    logic clk_300, clk;

    IBUFDS u_ibufds (
        .I  (clk_300_p_i),
        .IB (clk_300_n_i),
        .O  (clk_300)
    );

    BUFGCE_DIV #(
        .BUFGCE_DIVIDE (4)
    ) u_clkdiv (
        .I   (clk_300),
        .CE  (1'b1),
        .CLR (1'b0),
        .O   (clk)
    );

    // ---- reset de partida ----------------------------------------------------
    // Oito ciclos apos a configuracao, so para carregar as sementes; depois
    // nunca mais e afirmado.
    logic [3:0] rst_cnt = 4'd8;
    logic       rst;
    assign rst = (rst_cnt != 4'd0);
    always_ff @(posedge clk)
        if (rst_cnt != 4'd0) rst_cnt <= rst_cnt - 4'd1;

    // ---- PRNG ----------------------------------------------------------------
    logic [31:0] tdata;
    logic        tvalid;

    takum_prng_axis #(
        .LUT_DIR  (LUT_DIR),
        .VARIANTE (VARIANTE)
    ) u_prng (
        .clk_i      (clk),
        .rst_i      (rst),
        .m_tdata_o  (tdata),
        .m_tvalid_o (tvalid),
        .m_tready_i (1'b1)      // dreno sempre pronto
    );

    // ---- assinatura ----------------------------------------------------------
    // Cada beat entra por XOR numa assinatura que rotaciona, e a assinatura
    // chega aos pinos -- e o que impede a sintese de podar o PRNG por falta de
    // carga.
    logic [31:0] sig = '0;
    always_ff @(posedge clk)
        if (tvalid) sig <= {sig[30:0], sig[31]} ^ tdata;

    // ---- LEDs ----------------------------------------------------------------
    // A 75 MHz sai um beat a cada ~59 ciclos, rapido demais para o olho. O
    // contador captura uma amostra a cada 2^25 ciclos (~0,45 s), entao os LEDs
    // exibem valores trocando devagar: prova visivel de que o clock esta vivo e
    // o PRNG esta produzindo.
    logic [24:0] heartbeat = '0;
    logic [3:0]  led_q     = '0;
    always_ff @(posedge clk) begin
        heartbeat <= heartbeat + 1'b1;
        if (heartbeat == '1) led_q <= sig[3:0];
    end

    assign led_o = led_q;

endmodule : zcu104_takum_prng_top
