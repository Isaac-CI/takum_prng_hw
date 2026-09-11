`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_takum_prng
//
// Compara o RTL contra os vetores de model/takum_prng_model.py, iteracao a
// iteracao. Como o modelo usa a mesma aritmetica bit-exata do RTL
// (arch_takum/model/takum_arith.py, validado nos 840316 vetores da ALU), a
// concordancia esperada e total: qualquer divergencia e bug de
// sequenciamento, nao de arredondamento.
// -----------------------------------------------------------------------------
module tb_takum_prng;

    import takum_prng_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic           valid;
    logic [5:0]     nbits;
    logic [WF-1:0]  data;

    takum_prng_core #(
        .LUT_DIR ("../arch_takum/rtl/lns/lut/")
    ) dut (
        .clk_i   (clk),
        .rst_i   (rst),
        // Sem esta ligacao ready_i fica em z, o nucleo espera para sempre em
        // ST_EMIT e valid_o nunca sobe -- o banco nao acusa nada, so roda sem
        // fim, porque o laco de comparacao so avanca quando ha uma emissao.
        .ready_i (1'b1),
        .valid_o (valid),
        .nbits_o (nbits),
        .data_o  (data)
    );

    integer file, status, fails = 0, checked = 0;
    integer exp_nbits;
    logic [WF-1:0] exp_data;
    string header;
    integer cyc_start, cyc_end;
    integer cycles = 0;
    always @(posedge clk) cycles++;

    // O laco de comparacao so avanca quando ha uma emissao, entao um nucleo que
    // para de emitir nao produz erro nenhum -- produz uma simulacao que nunca
    // termina, que e bem pior de diagnosticar. Este limite a transforma num
    // relatorio. Sao 60 ciclos por iteracao, folgado sobre os 44 esperados.
    localparam int LIMITE_CICLOS = 21000 * 60;

    initial begin
        repeat (LIMITE_CICLOS) @(posedge clk);
        $display("");
        $display("ERRO: o nucleo parou de emitir -- %0d iteracoes conferidas em %0d ciclos",
                 checked, cycles);
        $finish;
    end

    initial begin
        file = $fopen("tb/golden_prng.txt", "r");
        if (file == 0) begin
            $display("ERRO: tb/golden_prng.txt nao encontrado");
            $finish;
        end
        status = $fgets(header, file);

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        cyc_start = cycles;

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
        $display("PRNG: %0d iteracoes conferidas, %0d divergencias", checked, fails);
        if (checked > 1)
            $display("Ciclos por iteracao: %0d", (cyc_end - cyc_start) / (checked - 1));
        $fclose(file);
        $finish;
    end

endmodule
