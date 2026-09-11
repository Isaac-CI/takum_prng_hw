`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_takum_prng_multi
//
// Compara takum_prng_core_multi contra model/takum_prng_multi_model.py e mede
// quantos ciclos custa uma emissao.
//
// O QUE ESTE BANCO REALMENTE TESTA. A aritmetica ja foi verificada pelo
// tb_takum_prng_fused -- cada fluxo e o mesmo gerador fundido. O que e novo
// aqui e o COMPARTILHAMENTO: se o barril servir o fluxo errado, se o
// encaminhamento do resultado do somador pegar o valor velho, ou se o estado de
// um fluxo vazar para outro, a saida diverge. Todos esses erros aparecem como
// divergencia contra o modelo, que mantem os tres geradores separados por
// construcao.
//
// A contagem de ciclos e o outro objetivo. Esperado: 15 ciclos por emissao,
// contra 24 do nucleo fundido de um fluxo so e 48 do original.
// -----------------------------------------------------------------------------
module tb_takum_prng_multi;

    import takum_prng_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic           valid;
    logic [5:0]     nbits;
    logic [WF-1:0]  data;

    takum_prng_core_multi #(
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
        file = $fopen("tb/golden_prng_multi.txt", "r");
        if (file == 0) begin
            $display("ERRO: tb/golden_prng_multi.txt nao encontrado");
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
                        $display("FALHA emissao=%0d | RTL: nbits=%0d data=%07h | MODELO: nbits=%0d data=%07h",
                                 checked, nbits, data, exp_nbits, exp_data);
                end
                if (checked == 1) cyc_start = cycles;
                cyc_end = cycles;
            end
        end

        $display("");
        $display("========== PRNG INTERCALADO (3 fluxos) ==========");
        $display("  emissoes conferidas  : %0d", checked);
        $display("  divergencias         : %0d", fails);
        if (checked > 1)
            $display("  ciclos por emissao   : %0d", (cyc_end - cyc_start) / (checked - 1));
        $display("=================================================");
        $fclose(file);
        $finish;
    end

endmodule
