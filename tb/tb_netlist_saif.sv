`timescale 1ps / 1ps
// -----------------------------------------------------------------------------
// tb_netlist_saif
//
// Testbench para simular o NETLIST IMPLEMENTADO e extrair dele um SAIF com
// cobertura alta.
//
// Por que existe um testbench separado. Os outros bancos instanciam
// takum_prng_axis, com clk_i/rst_i e a AXI-Stream exposta. O netlist gerado a
// partir do impl_1 tem como topo o zcu104_takum_prng_top, cuja interface e a
// da placa: par diferencial de 300 MHz entrando e quatro LEDs saindo. Nada de
// AXI-Stream nos pinos. Entao este banco nao confere dados -- para isso ja
// existem tb_takum_prng e tb_takum_prng_axis, e a conferencia definitiva foi
// feita no silicio. Aqui o objetivo e so exercitar o circuito para medir
// quanto cada no chaveia.
//
// Nao ha reset externo: o design se reinicia sozinho na partida, a partir dos
// valores INIT dos registradores, que o glbl aplica via GSR no inicio da
// simulacao. Por isso o netlist precisa ser elaborado junto de work.glbl.
//
// O NOME DA INSTANCIA IMPORTA. O report_power casa a atividade do SAIF por
// caminho hierarquico. Como este banco instancia o proprio topo do design,
// remover o prefixo "tb_netlist_saif/dut" dos caminhos do SAIF faz o que
// sobra coincidir exatamente com a hierarquia do design implementado. Trocar
// o nome desta instancia exige trocar o -strip_path junto.
// -----------------------------------------------------------------------------
module tb_netlist_saif;

    // 300 MHz diferenciais: periodo de 3333 ps, meio periodo 1667 ps. A
    // resolucao do banco e 1 ps de proposito -- em ns o meio periodo cairia
    // para 2 ns e o clock sairia a 250 MHz, alterando toda a atividade medida.
    logic clk_p = 1'b0;
    logic clk_n = 1'b1;

    always #1667 begin
        clk_p = ~clk_p;
        clk_n = ~clk_n;
    end

    logic [3:0] led;

    zcu104_takum_prng_top dut (
        .clk_300_p_i (clk_p),
        .clk_300_n_i (clk_n),
        .led_o       (led)
    );

    // NAO HA $finish AQUI, e isso e essencial. Quem controla a duracao e o
    // script Tcl, com "run <duracao>" seguido de close_saif. Se o testbench
    // terminasse a simulacao por conta propria, o $finish encerraria o
    // simulador antes do close_saif e o SAIF nunca seria escrito -- sem erro
    // nenhum, apenas sem arquivo no fim.
    //
    // A janela padrao do script e 50 us: ~3750 ciclos de 75 MHz, cerca de 78
    // iteracoes completas dos dois mapas. E amostra suficiente para a taxa
    // media de chaveamento estabilizar, que e tudo que a potencia precisa.

endmodule
