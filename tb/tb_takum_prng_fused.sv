`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_takum_prng_fused
//
// Compara takum_prng_core_fused contra model/takum_prng_fused_model.py,
// iteracao a iteracao, e mede quantos ciclos uma iteracao leva.
//
// A concordancia esperada e TOTAL, e vale dizer por que, ja que a fusao muda a
// aritmetica: o modelo fundido foi escrito para espelhar o datapath fundido --
// mesma cadeia, mesmos valores permanecendo no formato interno, arredondamento
// so ao escrever t e s. Entao qualquer divergencia aqui e bug de
// sequenciamento ou de conversao nas bordas, nao de precisao.
//
// A contagem de ciclos e o outro objetivo. A versao nao fundida gasta 48 ciclos
// por iteracao porque toda operacao fica atras do pipeline dimensionado para o
// somador Gauss-log. Aqui o esperado sao 24:
//
//   3 SUB x 4 ciclos  +  6 rapidas x 1  +  2 inversoes x 1  +  4 avulsos
// -----------------------------------------------------------------------------
module tb_takum_prng_fused;

    import takum_prng_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic           valid;
    logic [5:0]     nbits;
    logic [WF-1:0]  data;

    takum_prng_core_fused #(
        .LUT_DIR ("../arch_takum/rtl/lns/lut/")
    ) dut (
        .clk_i   (clk),
        .rst_i   (rst),
        .ready_i (1'b1),
        .valid_o (valid),
        .nbits_o (nbits),
        .data_o  (data)
    );

    integer file, status, fails = 0, checked = 0;
    integer exp_nbits;
    logic [WF-1:0] exp_data;
    string header;
    integer cyc_start = 0, cyc_end = 0;
    integer cycles = 0;
    always @(posedge clk) cycles++;

    initial begin
        file = $fopen("tb/golden_prng_fused.txt", "r");
        if (file == 0) begin
            $display("ERRO: tb/golden_prng_fused.txt nao encontrado");
            $finish;
        end
        status = $fgets(header, file);

        repeat (4) @(posedge clk);
        rst <= 1'b0;

        while (!$feof(file)) begin
            @(posedge clk);
            if (valid) begin
                status = $fscanf(file, "%d %h\n", exp_nbits, exp_data);
                if (status != 2) break;
                checked++;
                if (nbits !== exp_nbits[5:0] || data !== exp_data) begin
                    fails++;
                    if (fails <= 10)
                        $display("FALHA it=%0d | RTL: nbits=%0d data=%07h | MODELO: nbits=%0d data=%07h",
                                 checked, nbits, data, exp_nbits, exp_data);
                end
                if (checked == 1) cyc_start = cycles;
                cyc_end = cycles;
            end
        end

        $display("");
        $display("=============== PRNG FUNDIDO ===============");
        $display("  iteracoes conferidas : %0d", checked);
        $display("  divergencias         : %0d", fails);
        if (checked > 1)
            $display("  ciclos por iteracao  : %0d", (cyc_end - cyc_start) / (checked - 1));
        $display("============================================");
        $fclose(file);
        $finish;
    end

endmodule
