// -----------------------------------------------------------------------------
// takum_prng_packer
//
// Junta as emissoes de largura variavel do PRNG em palavras de 32 bits e as
// entrega por AXI-Stream.
//
// O nucleo emite entre 20 e 27 bits por iteracao (a largura do campo M do
// takum depende do regime), com media medida de 25,87. Nada disso se alinha a
// 32 bits, entao e preciso um acumulador de bits.
//
// ORDEM DOS BITS. Os bits entram do mais significativo para o menos
// significativo de cada emissao, e a palavra de saida carrega os 32 bits mais
// antigos -- a mesma ordem do BitWriter do gerador de referencia em C++.
// Isso importa: o NIST le o arquivo como uma sequencia, entao trocar a ordem
// aqui mudaria os resultados dos testes sem mudar nada da matematica.
//
// O acumulador guarda `cnt` bits validos alinhados a direita: os mais antigos
// ficam no topo dos `cnt` bits, e cada emissao nova entra deslocando para a
// esquerda. Emitir uma palavra e ler `acc[cnt-1 -: 32]` e descontar 32 de
// `cnt` -- os bits ja consumidos ficam acima de `cnt` e saem sozinhos nos
// deslocamentos seguintes.
//
// BACK-PRESSURE. `s_ready_o` depende so de `cnt`, nunca de `m_tready_i`, para
// nao criar caminho combinacional do consumidor de volta ao produtor. Quando
// o consumidor para, `cnt` cresce, `s_ready_o` cai e o nucleo segura em
// ST_EMIT: um PRNG nao pode descartar amostras.
// -----------------------------------------------------------------------------
module takum_prng_packer
    import takum_prng_pkg::*;
#(
    parameter int AXIS_W = 32
) (
    input  logic                clk_i,
    input  logic                rst_i,

    // entrada de largura variavel, vinda do nucleo
    input  logic                s_valid_i,
    input  logic [5:0]          s_nbits_i,
    input  logic [WF-1:0]       s_data_i,
    output logic                s_ready_o,

    // AXI-Stream mestre
    output logic [AXIS_W-1:0]   m_tdata_o,
    output logic                m_tvalid_o,
    input  logic                m_tready_i
);

    // Pior caso de ocupacao: aceitamos enquanto cabe mais uma emissao inteira,
    // entao o acumulador precisa de AXIS_W + 2*WF bits para nunca transbordar.
    localparam int ACC_W    = AXIS_W + 2 * WF;      // 86
    localparam int CNT_W    = $clog2(ACC_W + 1);
    localparam int ACCEPT_HI = ACC_W - WF;          // maior cnt que ainda aceita

    logic [ACC_W-1:0] acc;
    logic [CNT_W-1:0] cnt;

    assign s_ready_o  = (cnt <= CNT_W'(ACCEPT_HI));
    assign m_tvalid_o = (cnt >= CNT_W'(AXIS_W));
    assign m_tdata_o  = AXIS_W'(acc >> (cnt - CNT_W'(AXIS_W)));

    logic accept, emit;
    assign accept = s_valid_i && s_ready_o && (s_nbits_i != 6'd0);
    assign emit   = m_tvalid_o && m_tready_i;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            acc <= '0;
            cnt <= '0;
        end else begin
            logic [CNT_W-1:0] c;
            logic [ACC_W-1:0] a;
            c = cnt;
            a = acc;
            // Consumir nao mexe em `acc`: so reduz quantos bits sao validos.
            if (emit)   c = c - CNT_W'(AXIS_W);
            if (accept) begin
                a = (a << s_nbits_i) | ACC_W'(s_data_i);
                c = c + CNT_W'(s_nbits_i);
            end
            acc <= a;
            cnt <= c;
        end
    end

endmodule : takum_prng_packer
