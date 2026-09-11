// -----------------------------------------------------------------------------
// takum_prng_pkg
//
// Constantes do PRNG caotico takum32: acoplamento entre o mapa tenda e o mapa
// seno (aproximacao de Bhaskara), perturbados por um LFSR de Galois.
//
// Todas as constantes ja estao codificadas em takum32 logaritmico. Vale
// registrar que, fora 1.0, NENHUMA e exata: o valor de um takum logaritmico e
// sqrt(e)^L, entao so potencias de sqrt(e) caem em cima de um codigo. O valor
// reconstruido de cada uma esta no comentario ao lado. Como os mapas sao
// caoticos, essas diferencas de ultimo bit fazem a trajetoria divergir da
// versao em float32 em poucas dezenas de iteracoes -- esperado, e o motivo de
// a validacao contra o referencial ser estatistica e nao bit a bit.
//
// Geradas por model/gen_constants.py.
// -----------------------------------------------------------------------------
package takum_prng_pkg;

  localparam int N  = 32;   // largura do takum
  localparam int WF = N - 5; // 27: mantissa no regime mais largo

  // ---- padroes reservados ---------------------------------------------------
  localparam logic [N-1:0] TK_ZERO = 32'h00000000;
  localparam logic [N-1:0] TK_NAR  = 32'h80000000;

  // ---- constantes dos mapas -------------------------------------------------
  localparam logic [N-1:0] C_ONE  = 32'h40000000;  // 1.0     exato
  localparam logic [N-1:0] C_HALF = 32'h36746f40;  // 0.5     0.499999999048
  localparam logic [N-1:0] C_MU   = 32'h498a8a8a;  // 1.999   1.998999998547
  localparam logic [N-1:0] C_R16  = 32'h54ab3ddf;  // 0.9*16  14.400000005907
  localparam logic [N-1:0] C_C4   = 32'h4f17217f;  // 4.0     3.999999985435
  localparam logic [N-1:0] C_C5   = 32'h5070107e;  // 5.0     5.000000001342
  localparam logic [N-1:0] C_R36  = 32'h4e3f5a3e;  // 0.9*4   3.599999987763
  localparam logic [N-1:0] C_125  = 32'h4391fef9;  // 5/4     1.250000000231

  // C_R36 E C_125 SAO A MESMA FRACAO REESCALADA. Dividindo numerador e
  // denominador por 4,
  //
  //     14.4u / (5 - 4u)  ==  3.6u / (1.25 - u)
  //
  // e a multiplicacao 4u desaparece: o denominador passa a ser uma subtracao
  // direta sobre u. So takum_prng_core_pipe usa esta forma, e la ela vale DOIS
  // passos e nao um -- alem da multiplicacao, some o estagio que existia
  // unicamente para separa-la da subtracao, porque o operando da unidade
  // Gauss-log passa a vir de um registrador em vez da saida de um multiplicador.
  //
  // ATENCAO A COMPARACAO. As outras tres variantes continuam com C_R16/C_C4/C_C5,
  // como o gerador linear -- entao o pipeline esta, por ora, algebricamente
  // diferente das demais e do linear. Propagar esta forma e uma edicao de um
  // passo de microcodigo em cada nucleo, e enquanto isso nao for feito uma
  // comparacao direta de ciclos entre o pipeline e as outras mede tambem a
  // diferenca de algebra.

  // C_R16 E A DOBRA DO GANHO r DO MAPA SENO DENTRO DO NUMERADOR. O mapa e
  //
  //     S' = r * 16u/(5 - 4u),   u = S(1 - S),   r = 0.9
  //
  // e como r e 16 sao ambos constantes, r*16 = 14.4 tambem e. Calcular 14.4u
  // direto poupa a multiplicacao final por r -- uma operacao a menos por
  // iteracao, em todas as quatro variantes. Por isso nao existem mais C_C16
  // nem C_R separados: seriam constantes sem uso.
  //
  // O GERADOR LINEAR JA FAZIA ISSO (takum_prng_rtl/prng/prng_pkg.sv). Mante-lo
  // so de um lado deixaria a comparacao log-vs-linear medindo tambem a
  // diferenca de algebra entre os dois, em vez de so a diferenca de aritmetica
  // -- que e a unica coisa que ela deveria dizer.
  //
  // A PALAVRA E OUTRA nos dois formatos: o linear usa 0x5199999a e o
  // logaritmico 0x54ab3ddf para o mesmo 14,4. Constantes takum sao especificas
  // do formato, e trocar uma pela outra decodifica para outro numero.

  // ---- sementes de resgate --------------------------------------------------
  // Usadas quando um mapa colapsa em zero ou NaR. SEEDS[0] e zero de
  // proposito, herdado do gerador de referencia: se cair nela o mapa colapsa
  // de novo na iteracao seguinte e avanca para SEEDS[1], entao o esquema se
  // recupera sozinho.
  localparam logic [N-1:0] SEEDS [0:7] = '{
      32'h00000000,   // 0.0
      32'h2f8fef82,   // 0.2       0.199999999946
      32'h2da1ecb6,   // 0.123456  0.123456000588
      32'h3936a6eb,   // 0.654321  0.654321000904
      32'h3ad20fa5,   // 0.723456  0.723456000924
      32'h30665f0d,   // 0.234567  0.234567000023
      32'h37895a72,   // 0.572391  0.572390998104
      32'h3fb471e0    // 0.981723  0.981722999975
  };

  // ---- estado inicial -------------------------------------------------------
  localparam logic [N-1:0] T_INIT = 32'h2da1ecb6;  // INIT_X       = 0.123456
  localparam logic [N-1:0] S_INIT = 32'h3002fd11;  // INIT_X + 0.1 = 0.223456

  localparam logic [31:0] LFSR_INIT  = 32'hACE1ACE1;

  // ---- sementes dos fluxos intercalados ------------------------------------
  // takum_prng_core_multi roda NSTREAMS geradores independentes no mesmo
  // hardware. Fluxos que partissem do mesmo estado produziriam a MESMA
  // sequencia, e intercala-las daria um bitstream com periodo tres vezes menor
  // -- o oposto do pretendido. Daí tres estados iniciais distintos.
  //
  // O LFSR TAMBEM DIFERE, e nao so as sementes dos mapas. Mapas caoticos tem
  // dependencia sensivel as condicoes iniciais, o que separa as orbitas, mas
  // isso e uma tendencia estatistica e nao uma garantia de independencia: duas
  // orbitas podem se aproximar por trechos. A perturbacao por LFSR e o que
  // descorrelaciona ativamente, entao dar a cada fluxo um estado de LFSR
  // proprio custa apenas um valor inicial diferente e remove a unica fonte de
  // correlacao que seria comum aos tres.
  //
  // Os valores sao arbitrarios e nao nulos, escolhidos sem relacao aparente
  // entre si. Quem julga a independencia de fato e a bateria NIST sobre o
  // bitstream intercalado -- correlacao entre fluxos apareceria nos testes de
  // autocorrelacao e de padroes.
  localparam int NSTREAMS = 3;

  localparam logic [N-1:0] T_INIT_M [0:NSTREAMS-1] = '{
      32'h2da1ecb6,   // 0.123456  (= T_INIT, o fluxo 0 reproduz a semente base)
      32'h3936a6eb,   // 0.654321
      32'h3ad20fa5    // 0.723456
  };

  localparam logic [N-1:0] S_INIT_M [0:NSTREAMS-1] = '{
      32'h3002fd11,   // 0.223456  (= S_INIT)
      32'h30665f0d,   // 0.234567
      32'h37895a72    // 0.572391
  };

  localparam logic [31:0] LFSR_INIT_M [0:NSTREAMS-1] = '{
      32'hACE1ACE1,   // = LFSR_INIT
      32'h5A5A1234,
      32'h13579BDF
  };

  // ---- sementes dos fluxos do pipeline espacial -----------------------------
  // takum_prng_core_pipe desenrola as operacoes do mapa no espaco e as encadeia
  // num anel de NPIPE estagios. Cada estagio guarda o estado de um fluxo
  // diferente, entao a profundidade do pipeline E o numero de fluxos: nao ha
  // banco de registradores por fluxo a dimensionar, o estado de cada um E o
  // conteudo dos registradores de pipeline, andando um estagio por ciclo.
  //
  // Os tres primeiros repetem T_INIT_M / S_INIT_M / LFSR_INIT_M de proposito.
  // Assim o fluxo k do pipeline e bit a bit o fluxo k do intercalado para
  // k < 3, e uma divergencia entre os dois nucleos aparece na comparacao
  // direta em vez de ficar escondida atras de sementes diferentes.
  //
  // Geradas por model/gen_pipe_seeds.py, que verifica que nenhuma palavra
  // takum colide -- dois fluxos com a mesma palavra teriam a mesma orbita, e
  // intercala-las encurtaria o periodo em vez de alonga-lo.
  localparam int NPIPE = 12;

  localparam logic [N-1:0] T_INIT_P [0:NPIPE-1] = '{
      32'h2da1ecb6,   // 0.123456  0.123456000588
      32'h3936a6eb,   // 0.654321  0.654321000904
      32'h3ad20fa5,   // 0.723456  0.723456000924
      32'h32ab7b05,   // 0.311527  0.311527000631
      32'h3d58e63c,   // 0.847219  0.847219001473
      32'h34faca60,   // 0.415803  0.415803000314
      32'h2b52d541,   // 0.069314  0.069313999797
      32'h3b92af8a,   // 0.758291  0.758291000261
      32'h2f6a9691,   // 0.192837  0.192836999375
      32'h389c85fc,   // 0.630157  0.630156999528
      32'h3e082dff,   // 0.884261  0.884261001190
      32'h3694b6a0    // 0.507943  0.507942998459
  };

  localparam logic [N-1:0] S_INIT_P [0:NPIPE-1] = '{
      32'h3002fd11,   // 0.223456  0.223456000152
      32'h30665f0d,   // 0.234567  0.234567000022
      32'h37895a72,   // 0.572391  0.572390998103
      32'h3df93459,   // 0.881034  0.881033999579
      32'h2e52c3db,   // 0.146728  0.146728000096
      32'h3a61e769,   // 0.703915  0.703914999505
      32'h33d0b593,   // 0.359482  0.359481999264
      32'h382526ba,   // 0.612057  0.612056999513
      32'h29ad3a2e,   // 0.045921  0.045921000027
      32'h3c3c465e,   // 0.790346  0.790345999683
      32'h3626367d,   // 0.481263  0.481262998270
      32'h3ec3cdad    // 0.925708  0.925707998539
  };

  localparam logic [31:0] LFSR_INIT_P [0:NPIPE-1] = '{
      32'hACE1ACE1,
      32'h5A5A1234,
      32'h13579BDF,
      32'h2468ACE0,
      32'h7F3E1D5C,
      32'hC0FFEE11,
      32'h1BADB002,
      32'hDEADC0DE,
      32'h5EED0FF1,
      32'h0BADCAFE,
      32'hF00DBABE,
      32'h3C3C5A5A 
  };

  localparam logic [31:0] LFSR_POLY  = 32'h80200003;
  localparam int          LFSR_STEPS = 8;

  // ---- opcodes da ALU (takum_log_alu) --------------------------------------
  localparam logic [2:0] OP_ADD = 3'd0;
  localparam logic [2:0] OP_SUB = 3'd1;
  localparam logic [2:0] OP_MUL = 3'd2;
  localparam logic [2:0] OP_DIV = 3'd3;

endpackage : takum_prng_pkg
