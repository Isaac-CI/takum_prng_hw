`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_takum_prng_axis
//
// Confere a saida AXI-Stream de 32 bits contra model/takum_prng_model.py
// (words32), com back-pressure pseudoaleatoria em m_tready.
//
// A back-pressure e o ponto do teste: um PRNG nao pode descartar amostras, e
// o caminho de parada atravessa o empacotador ate a FSM do nucleo, que segura
// em ST_EMIT. Se esse caminho estiver errado, os beats saem certos enquanto o
// consumidor aceita sempre e comecam a divergir assim que ele hesita -- por
// isso o tready aqui fica baixo em rajadas, e nao so um ciclo isolado.
// -----------------------------------------------------------------------------
module tb_takum_prng_axis;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic [31:0] tdata;
    logic        tvalid;
    logic        tready;

    takum_prng_axis #(
        .LUT_DIR ("../arch_takum/rtl/lns/lut/")
    ) dut (
        .clk_i      (clk),
        .rst_i      (rst),
        .m_tdata_o  (tdata),
        .m_tvalid_o (tvalid),
        .m_tready_i (tready)
    );

    // Consumidor irregular: aceita em ~60% dos ciclos, em rajadas.
    integer seed = 32'h1234_5678;
    always_ff @(posedge clk) begin
        if (rst) tready <= 1'b1;
        else     tready <= ($random(seed) % 10) < 6;
    end

    integer file, status, fails = 0, checked = 0;
    logic [31:0] expected;
    string header;

    initial begin
        file = $fopen("tb/golden_axis.txt", "r");
        if (file == 0) begin
            $display("ERRO: tb/golden_axis.txt nao encontrado");
            $finish;
        end
        status = $fgets(header, file);

        repeat (4) @(posedge clk);
        rst <= 1'b0;

        while (!$feof(file)) begin
            @(posedge clk);
            if (tvalid && tready) begin
                status = $fscanf(file, "%h\n", expected);
                if (status != 1) break;
                checked++;
                if (tdata !== expected) begin
                    fails++;
                    if (fails <= 10)
                        $display("FALHA beat=%0d | RTL=%08h | MODELO=%08h",
                                 checked, tdata, expected);
                end
            end
        end

        $display("");
        $display("AXI-Stream: %0d beats de 32 bits conferidos, %0d divergencias",
                 checked, fails);
        $fclose(file);
        $finish;
    end

endmodule
