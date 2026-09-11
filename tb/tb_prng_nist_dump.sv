`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_prng_nist_dump
//
// Roda takum_prng_axis e despeja a saida num arquivo binario para a bateria
// NIST. A variante do gerador vem por generic (-generic_top VARIANTE=...), e o
// caminho do arquivo por plusarg, para que os tres geradores usem o MESMO banco
// e a comparacao entre eles nao misture diferencas de testbench.
//
//   xelab -generic_top "VARIANTE=multi" -top tb_prng_nist_dump ...
//   xsim ... -testplusarg "out=prng_multi.bin" -testplusarg "bits=100000000"
//
// POR QUE DO TESTBENCH E NAO DA PLACA. O bitstream aqui sai do RTL simulado, nao
// de captura por JTAG. Sao a mesma sequencia -- o RTL e o mesmo e o gerador e
// determinista -- mas pelo testbench ela sai em minutos em vez de meia hora de
// cabo, sem depender da placa e sem o risco de uma janela de ILA mal emendada
// introduzir descontinuidade no arquivo. A captura por ILA continua valendo
// para o que so ela prova: que o silicio concorda com o RTL.
//
// ORDEM DOS BITS. Cada palavra de 32 bits e gravada em big-endian, byte mais
// significativo primeiro, que preserva a ordem de emissao: o primeiro byte do
// arquivo carrega os oito bits mais antigos, com o mais antigo no MSB. Mesma
// ordem de words32() nos modelos e a que o NIST espera em modo binario.
// -----------------------------------------------------------------------------
module tb_prng_nist_dump;

    parameter string VARIANTE = "multi";

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic [31:0] tdata;
    logic        tvalid;

    takum_prng_axis #(
        .VARIANTE (VARIANTE),
        .LUT_DIR  ("../arch_takum/rtl/lns/lut/")
    ) dut (
        .clk_i      (clk),
        .rst_i      (rst),
        .m_tdata_o  (tdata),
        .m_tvalid_o (tvalid),
        .m_tready_i (1'b1)          // dreno sempre pronto: vazao maxima
    );

    integer fd;
    string  nome;
    longint alvo_bits;
    longint palavras = 0, ciclos = 0;

    initial begin
        if (!$value$plusargs("out=%s", nome))   nome = "prng.bin";
        if (!$value$plusargs("bits=%d", alvo_bits)) alvo_bits = 100000000;

        fd = $fopen(nome, "wb");
        if (fd == 0) begin
            $display("ERRO: nao consegui abrir %s para escrita", nome);
            $finish;
        end

        $display("gerando %0d bits com a variante '%s' -> %s",
                 alvo_bits, VARIANTE, nome);

        repeat (4) @(posedge clk);
        rst <= 1'b0;

        while (palavras * 32 < alvo_bits) begin
            @(posedge clk);
            ciclos++;
            if (tvalid) begin
                // big-endian: o byte mais antigo primeiro
                $fwrite(fd, "%c", tdata[31:24]);
                $fwrite(fd, "%c", tdata[23:16]);
                $fwrite(fd, "%c", tdata[15:8]);
                $fwrite(fd, "%c", tdata[7:0]);
                palavras++;
                if (palavras % 500000 == 0)
                    $display("  %0d palavras (%0d Mbit)", palavras, (palavras*32)/1000000);
            end
        end

        $fclose(fd);
        $display("");
        $display("============ BITSTREAM PARA O NIST ============");
        $display("  variante        : %s", VARIANTE);
        $display("  arquivo         : %s", nome);
        $display("  palavras de 32b : %0d", palavras);
        $display("  bits            : %0d", palavras * 32);
        $display("  sequencias 1Mbit: %0d", (palavras * 32) / 1000000);
        $display("  ciclos por beat : %0d", ciclos / palavras);
        $display("===============================================");
        $finish;
    end

endmodule
