`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_takum_prng_rate
//
// Mede a vazao sustentada do design final: consumidor sempre pronto, conta
// beats e ciclos ao longo de uma janela longa e reporta bits por ciclo.
//
// Existe porque a vazao deste PRNG nao e um numero fechado: cada iteracao
// emite entre 20 e 27 bits, dependendo do regime dos dois takums daquele
// passo, entao a taxa media so sai de uma amostra grande.
// -----------------------------------------------------------------------------
module tb_takum_prng_rate;

    localparam int BEATS_ALVO = 20000;
    localparam real F_MHZ     = 75.0;   // clock do topo na ZCU104

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic [31:0] tdata;
    logic        tvalid;

    takum_prng_axis #(
        .LUT_DIR ("../arch_takum/rtl/lns/lut/")
    // O nome da instancia importa: gen_saif.sh grava um SAIF a partir daqui e
    // o report_power casa a atividade por caminho hierarquico. Chamando-a de
    // u_prng, igual ao nome que ela tem em zcu104_takum_prng_top, basta tirar
    // o prefixo do testbench para os caminhos coincidirem com os do design
    // implementado. Renomear isto invalida a anotacao de potencia -- sem erro
    // nenhum, apenas com o Vivado voltando a estimar por heuristica.
    ) u_prng (
        .clk_i      (clk),
        .rst_i      (rst),
        .m_tdata_o  (tdata),
        .m_tvalid_o (tvalid),
        .m_tready_i (1'b1)
    );

    longint beats = 0, cycles = 0;
    logic   running = 1'b0;

    always_ff @(posedge clk) begin
        if (running) begin
            cycles <= cycles + 1;
            if (tvalid) beats <= beats + 1;
        end
    end

    real bits_por_ciclo, mbits_s, mbeats_s;

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        running <= 1'b1;

        wait (beats >= BEATS_ALVO);
        running <= 1'b0;
        @(posedge clk);

        bits_por_ciclo = (real'(beats) * 32.0) / real'(cycles);
        mbits_s        = bits_por_ciclo * F_MHZ;
        mbeats_s       = (real'(beats) / real'(cycles)) * F_MHZ;

        $display("");
        $display("=============== VAZAO SUSTENTADA ===============");
        $display("  beats de 32 bits : %0d", beats);
        $display("  ciclos           : %0d", cycles);
        $display("  ciclos por beat  : %.2f", real'(cycles) / real'(beats));
        $display("  bits por ciclo   : %.4f", bits_por_ciclo);
        $display("  a %.0f MHz        : %.2f Mbit/s  (%.3f Mbeat/s)",
                 F_MHZ, mbits_s, mbeats_s);
        $display("================================================");
        $finish;
    end

endmodule
