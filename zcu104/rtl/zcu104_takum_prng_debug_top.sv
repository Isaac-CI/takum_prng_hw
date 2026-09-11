// -----------------------------------------------------------------------------
// zcu104_takum_prng_debug_top
//
// Versao instrumentada do topo do PRNG, para verificar o design numa placa que
// esta fisicamente longe. O topo limpo (zcu104_takum_prng_top) continua
// existindo e nao foi tocado: e ele que deve ser usado para medir area e
// timing de verdade, porque ILA e VIO consomem BRAM, LUT e FF que nao fazem
// parte do design.
//
// A ideia da verificacao. O PRNG e inteiramente determinista -- sementes fixas
// em takum_prng_pkg.sv, nenhuma entrada externa -- entao o silicio e obrigado
// a produzir exatamente a mesma sequencia de palavras que model/
// takum_prng_model.py produz com words32(). Capturar beats reais e compara-los
// com o modelo nao prova apenas que o design esta vivo: prova que ele esta
// correto no hardware.
//
// O PROBLEMA DO ALINHAMENTO. O design roda livre a partir do instante da
// configuracao do FPGA, entao quando o ILA finalmente e armado pela GUI ja se
// passaram milhoes de beats, e nao ha como saber em que ponto da sequencia a
// captura caiu. Duas coisas resolvem isso:
//
//   1. O VIO fornece um reset. Voce arma o ILA com o reset afirmado, solta o
//      reset, e a captura comeca no beat 0 -- alinhada com o modelo desde a
//      primeira palavra.
//   2. O proprio contador de beats e capturado junto dos dados. Assim cada
//      linha do CSV exportado carrega o indice absoluto daquele beat, e o
//      script de conferencia alinha sozinho, sem depender de o beat 0 ter sido
//      pego.
//
// Qualquer um dos dois basta; ter os dois torna a conferencia insensivel a
// como a captura foi feita.
//
// CAPTURA DENSA. Um beat sai a cada ~59 ciclos. Sem qualificacao de
// armazenamento, uma janela de 4096 amostras conteria so ~69 beats e o resto
// seria ociosidade. O ILA e gerado com storage qualification habilitada
// (create_project_debug.tcl) para que se configure, na GUI, a condicao de
// captura ila_tvalid == 1 -- assim cada amostra guardada e um beat, e a janela
// rende 4096 beats.
//
// Portas identicas as do topo limpo, de proposito: o mesmo
// constraints/zcu104_takum_prng.xdc serve para os dois.
// -----------------------------------------------------------------------------
module zcu104_takum_prng_debug_top #(
    parameter string LUT_DIR = ""    // caminho absoluto das ROMs (.mem)
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

    // ---- controles vindos do VIO --------------------------------------------
    logic        vio_rst;        // nivel: 1 segura o PRNG em reset
    logic [31:0] vio_trig_beat;  // em que beat o ILA deve disparar
    logic        vio_ready_en;   // 0 aplica back-pressure na AXI-Stream

    // ---- reset ---------------------------------------------------------------
    // Reset de partida (8 ciclos apos a configuracao, para carregar as
    // sementes) somado ao reset do VIO. O do VIO e o que permite reiniciar a
    // sequencia com o ILA ja armado.
    logic [3:0] rst_cnt = 4'd8;
    logic       rst;

    always_ff @(posedge clk)
        if (rst_cnt != 4'd0) rst_cnt <= rst_cnt - 4'd1;

    assign rst = (rst_cnt != 4'd0) | vio_rst;

    // ---- PRNG ----------------------------------------------------------------
    logic [31:0] tdata;
    logic        tvalid;
    logic        tready;

    // O dreno so nao esta amarrado em 1 para que a back-pressure possa ser
    // exercitada no silicio pelo VIO -- e o caminho de parada que o testbench
    // tb_takum_prng_axis cobre em simulacao.
    assign tready = vio_ready_en;

    takum_prng_axis #(
        .LUT_DIR (LUT_DIR)
    ) u_prng (
        .clk_i      (clk),
        .rst_i      (rst),
        .m_tdata_o  (tdata),
        .m_tvalid_o (tvalid),
        .m_tready_i (tready)
    );

    logic beat;
    assign beat = tvalid & tready;

    // ---- contador de beats ---------------------------------------------------
    // Zerado pelo reset, entao o beat 0 e sempre a primeira palavra da
    // sequencia do modelo. E o indice absoluto que o script de conferencia usa
    // para alinhar a captura.
    logic [31:0] beat_cnt;
    always_ff @(posedge clk)
        if (rst)       beat_cnt <= 32'd0;
        else if (beat) beat_cnt <= beat_cnt + 32'd1;

    // ---- assinatura ----------------------------------------------------------
    logic [31:0] sig;
    always_ff @(posedge clk)
        if (rst)       sig <= 32'd0;
        else if (beat) sig <= {sig[30:0], sig[31]} ^ tdata;

    // ---- prova de vida do clock ----------------------------------------------
    // Separado do PRNG de proposito. Se alive_o oscila mas beat_cnt nao anda,
    // o clock existe e o PRNG e que travou; se nem alive_o oscila, o problema
    // e o clock de 300 MHz da placa. Sao as duas falhas que, de longe, nao dao
    // para distinguir de outro jeito.
    logic [24:0] heartbeat = '0;
    logic [3:0]  led_q     = '0;
    always_ff @(posedge clk) begin
        heartbeat <= heartbeat + 1'b1;
        if (heartbeat == '1) led_q <= sig[3:0];
    end

    assign led_o = led_q;

    // ---- sinais do ILA -------------------------------------------------------
    // Registrados e com nomes proprios porque sao esses nomes que aparecem
    // como colunas no CSV exportado, e e por eles que o script de conferencia
    // encontra os dados.
    logic [31:0] ila_tdata;
    logic        ila_tvalid;
    logic [31:0] ila_beat_cnt;
    logic        ila_trig;

    always_ff @(posedge clk) begin
        ila_tdata    <= tdata;
        ila_tvalid   <= beat;
        ila_beat_cnt <= beat_cnt;
        ila_trig     <= beat && (beat_cnt == vio_trig_beat);
    end

    ila_0 u_ila (
        .clk    (clk),
        .probe0 (ila_tdata),
        .probe1 (ila_tvalid),
        .probe2 (ila_beat_cnt),
        .probe3 (ila_trig)
    );

    vio_0 u_vio (
        .clk        (clk),
        .probe_in0  (beat_cnt),
        .probe_in1  (sig),
        .probe_in2  (tvalid),
        .probe_in3  (heartbeat[24]),
        .probe_out0 (vio_rst),
        .probe_out1 (vio_trig_beat),
        .probe_out2 (vio_ready_en)
    );

endmodule : zcu104_takum_prng_debug_top
