`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_takum_prng_pipe
//
// Compara takum_prng_core_pipe contra model/takum_prng_pipe_model.py e mede
// quantos ciclos custa uma emissao. Esperado: UM.
//
// O QUE ESTE BANCO REALMENTE TESTA. A aritmetica ja foi verificada pelo
// tb_takum_prng_fused -- cada fluxo e o mesmo gerador fundido, e os tres
// primeiros sao literalmente os mesmos fluxos do nucleo intercalado. O que e
// novo aqui e o ANEL:
//
//   * se um estagio colher o resultado de uma unidade Gauss-log no ciclo
//     errado, o token pega a correcao de OUTRO fluxo -- que e o erro classico
//     de um pipeline desenrolado, e nao se manifesta como X nem como travamento,
//     so como um numero diferente;
//   * se o enchimento injetar uma semente fora de ordem, ou se a realimentacao
//     disputar a entrada com ele no ciclo de transicao, a ordem do rodizio
//     quebra;
//   * se um campo do token nao andar junto com o fluxo a que pertence, dois
//     geradores se misturam.
//
// Todos aparecem como divergencia contra o modelo, que mantem os catorze
// geradores separados por construcao.
//
// E A SEGUNDA PASSADA TESTA O CONGELAMENTO, que e o risco especifico deste
// desenho. Com uma emissao por ciclo o empacotador recusa de vez em quando, e
// um anel nao tem para onde escoar: `en` tem que congelar tambem os
// registradores DENTRO das unidades Gauss-log, onde ha varios pares de
// operandos em voo ao mesmo tempo. Se o congelamento pegasse so os estagios
// externos, esses pares avancariam em relacao a quem vai consome-los e a
// correcao errada seria recombinada -- em silencio, sem handshake que
// perceba. A passada com ready pseudoaleatorio tem que produzir EXATAMENTE a
// mesma sequencia da passada sem espera; qualquer diferenca e esse erro.
// -----------------------------------------------------------------------------
module tb_takum_prng_pipe;

    import takum_prng_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic ready = 1'b1;
    always #5 clk = ~clk;

    logic           valid;
    logic [5:0]     nbits;
    logic [WF-1:0]  data;

    takum_prng_core_pipe #(
        .LUT_DIR ("../arch_takum/rtl/lns/lut/")
    ) dut (
        .clk_i   (clk),
        .rst_i   (rst),
        .ready_i (ready),
        .valid_o (valid),
        .nbits_o (nbits),
        .data_o  (data)
    );

    integer cycles = 0;
    always @(posedge clk) cycles++;

    integer total_fails = 0;

    // Confere N emissoes contra o arquivo de ouro. `aleatorio` liga o
    // back-pressure pseudoaleatorio; `ciclos` devolve os ciclos gastos entre a
    // primeira e a ultima emissao conferida.
    task automatic confere(input bit aleatorio, input integer n_max,
                           output integer checked, output integer fails,
                           output integer ciclos);
        integer file, status;
        integer exp_nbits;
        logic [WF-1:0] exp_data;
        string header;
        integer cyc_start, cyc_end;
        integer lfsr_tb;
        begin
            checked = 0;
            fails   = 0;
            ciclos  = 0;
            cyc_start = 0;
            cyc_end   = 0;
            lfsr_tb   = 32'h1234_5678;

            file = $fopen("tb/golden_prng_pipe.txt", "r");
            if (file == 0) begin
                $display("ERRO: tb/golden_prng_pipe.txt nao encontrado");
                $finish;
            end
            status = $fgets(header, file);

            // Reinicia o anel: o enchimento recomeca do fluxo 0, entao as duas
            // passadas comparam contra o mesmo arquivo.
            rst   <= 1'b1;
            ready <= 1'b1;
            repeat (4) @(posedge clk);
            rst <= 1'b0;

            while (checked < n_max) begin
                @(posedge clk);
                if (valid && ready) begin
                    status = $fscanf(file, "%d %h\n", exp_nbits, exp_data);
                    if (status != 2) break;
                    checked++;
                    if (nbits !== exp_nbits[5:0] || data !== exp_data) begin
                        fails++;
                        if (fails <= 10)
                            $display("FALHA %s emissao=%0d | RTL: nbits=%0d data=%07h | MODELO: nbits=%0d data=%07h",
                                     aleatorio ? "(com espera)" : "(sem espera)",
                                     checked, nbits, data, exp_nbits, exp_data);
                    end
                    if (checked == 1) cyc_start = cycles;
                    cyc_end = cycles;
                end
                if (aleatorio) begin
                    // Galois de 32 bits so para gerar um padrao de espera
                    // reprodutivel; ready fica baixo em ~1/4 dos ciclos.
                    lfsr_tb = lfsr_tb[0] ? ((lfsr_tb >> 1) ^ 32'h80200003)
                                         : (lfsr_tb >> 1);
                    ready <= (lfsr_tb[1:0] != 2'b00);
                end
            end

            ciclos = cyc_end - cyc_start;
            $fclose(file);
        end
    endtask

    integer c1, f1, cy1, c2, f2, cy2;

    initial begin
        confere(1'b0, 21000, c1, f1, cy1);
        confere(1'b1,  8000, c2, f2, cy2);
        total_fails = f1 + f2;

        $display("");
        $display("========== PRNG EM PIPELINE ESPACIAL (%0d fluxos) ==========", NPIPE);
        $display("  sem espera (ready sempre alto)");
        $display("    emissoes conferidas : %0d", c1);
        $display("    divergencias        : %0d", f1);
        if (c1 > 1)
            $display("    ciclos por emissao  : %0d.%02.0f",
                     cy1 / (c1 - 1), 100.0 * (real'(cy1) / real'(c1 - 1) - cy1 / (c1 - 1)));
        $display("  com espera (ready pseudoaleatorio, ~25%% de recusa)");
        $display("    emissoes conferidas : %0d", c2);
        $display("    divergencias        : %0d", f2);
        $display("    ciclos decorridos   : %0d  (%0.2f por emissao)",
                 cy2, real'(cy2) / real'(c2 - 1));
        $display("  -> a sequencia tem que ser IDENTICA nas duas passadas");
        $display("=============================================================");
        $finish;
    end

endmodule
