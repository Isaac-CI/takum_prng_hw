# takum_prng

PRNG caotico em takum logaritmico de 32 bits: **mapa tenda acoplado ao mapa
seno** (aproximacao de Bhaskara), com as saidas de cada mapa perturbadas por
um LFSR de Galois e trocadas entre si a cada iteracao. A saida e o XOR das
mantissas dos dois valores perturbados.

Porte para hardware do gerador de referencia em float32, usando os modulos
aritmeticos de [`../arch_takum/rtl/lns`](../arch_takum/rtl/lns).

## Uso

```bash
python3 model/takum_prng_model.py    # modelo de referencia, 12 iteracoes
python3 model/gen_constants.py       # regera as constantes de rtl/takum_prng_pkg.sv
./run_sim.sh                         # RTL contra os vetores do modelo
```

## O algoritmo, por iteracao

```
1. tenda   T' = mu * (T < 0.5 ? T : 1 - T)                 mu = 1.999
2. seno    u = S(1-S) ;  S' = r * 16u / (5 - 4u)           r  = 0.9
3. LFSR    8 passos de Galois, polinomio 0x80200003
4/5. perturba T' e S':
       colapso (zero ou NaR)  -> resemeia de SEEDS, suprime a saida
       senao                  -> captura o campo M, XOR dos p bits baixos
                                 com o LFSR, e salvaguarda:
                                   x < 0 -> |x| ;  senao x > 1 -> 1/x
6. saida   min(p_T, p_S) bits de (M_T xor M_S xor LFSR)
7. troca   T <-> S     (e isso que faz o acoplamento 2D)
```

O mapa seno vem da aproximacao de Bhaskara `sin(t) ~ 16t(pi-t)/(5pi^2 -
4t(pi-t))` com `t = pi*x`: os `pi^2` se cancelam e sobra `16u/(5-4u)` com
`u = x(1-x)`, que precisa so de subtracao, multiplicacao e divisao.

## Duas diferencas contra o referencial em float32

**A mantissa nao tem largura fixa.** Em IEEE754 sao sempre 23 bits; no
takum32 o campo M ocupa `p = 27 - r` bits, com `r` vindo do regime, entao `p`
varia de 20 a 27. O gerador de referencia ja previa isso -- carregava
`m_bits` de cada mapa e emitia `min(m_bits_t, m_bits_s)` -- entao a estrutura
absorve a mudanca, mas a saida por iteracao passa a ter largura variavel.
Medido sobre 200 mil iteracoes: media de **25,87 bits por iteracao**,
distribuidos entre 23 e 27.

**Nenhuma constante decimal e exata.** O valor de um takum logaritmico e
`sqrt(e)^L`, entao so potencias de `sqrt(e)` caem em cima de um codigo: nem
0,5, nem 1,999, nem 5,0. Como os mapas sao caoticos, essas diferencas de
ultimo bit divergem em poucas dezenas de iteracoes.

**Consequencia: este gerador nao reproduz o bitstream do float32, e nao teria
como.** A comparacao entre os dois e estatistica (NIST), nao bit a bit.

## Arquitetura

**Uma ALU, sequenciada por microcodigo.** A escolha e ditada pela BRAM: um
`takum_log_adder` carrega 53 RAMB36 de tabelas Gauss-log, entao replicar ALUs
custa BRAM linearmente -- quatro delas ja seriam 212 dos 312 tiles de uma
ZCU104. Com uma unica ALU compartilhada e uma maquina de estados, o PRNG
inteiro cabe nos mesmos 53.

**Tempo constante.** Os dois ramos do mapa tenda sao sempre calculados, e as
duas divisoes de salvaguarda (`1/x`) sao sempre emitidas mesmo quando serao
descartadas. Uma iteracao leva sempre **48 ciclos**, independente dos dados --
alem de simplificar a FSM, isso evita que o tempo de execucao vaze informacao
sobre o estado interno.

Vazao: 48 ciclos por iteracao x ~25,87 bits = **~40 Mbit/s a 75 MHz**.

### Area medida (xczu7ev, pos-rota, 75 MHz)

| | | |
|---|---|---|
| CLB LUTs | 4 709 | 2,0% |
| CLB Registers | 944 | 0,2% |
| Block RAM (RAMB36) | 53 | 17,0% |
| DSP48E2 | 17 | 1,0% |
| Slack (setup) | +0,259 ns | fecha |

As 53 BRAMs sao exatamente as da ALU sozinha: o PRNG inteiro -- FSM,
registradores de estado, LFSR, as duas unidades de perturbacao -- nao
acrescenta nenhuma. Confirma na pratica o argumento de compartilhar uma ALU
unica em vez de replicar.

## Verificacao

`model/takum_prng_model.py` nao usa a aritmetica do Python: soma, subtracao,
multiplicacao e divisao vem de
[`../arch_takum/model/takum_arith.py`](../arch_takum/model/takum_arith.py),
um modelo bit-exato do RTL que le os proprios `.mem` das tabelas. Esse modelo
foi validado nos 840316 vetores da ALU, reproduzindo o RTL bit a bit.

Entao o modelo do PRNG e o hardware tem que concordar exatamente -- qualquer
divergencia seria bug de sequenciamento, nao de arredondamento.

**Resultado: 20000 iteracoes, 0 divergencias, 48 ciclos por iteracao.**

Sanidade estatistica do modelo em 200 mil iteracoes:

| | |
|---|---|
| bits gerados | 5 174 021 (25,87 por iteracao) |
| proporcao de 1 | 0,499904 |
| colapsos (zero ou NaR) | 0 |
| estados `T` distintos | 199 939 de 200 000 |

Nao substitui a bateria NIST -- e so a checagem de que nada esta obviamente
degenerado.

## Estrutura

```
rtl/takum_prng_pkg.sv        constantes takum32, sementes, opcodes
rtl/takum_prng_perturb.sv    inspecao, mantissa, XOR e salvaguardas (combinacional)
rtl/takum_prng_core.sv       FSM microcodificada + ALU compartilhada
model/takum_prng_model.py    modelo de referencia bit-exato
model/gen_constants.py       gera as constantes de takum_prng_pkg.sv
tb/tb_takum_prng.sv          compara o RTL contra o modelo
tb/golden_prng.txt           vetores gerados pelo modelo
run_sim.sh                   roda a simulacao
```

## Nota sobre SEEDS[0]

`SEEDS[0]` e zero, herdado do gerador de referencia. Se um colapso cair nela,
o mapa colapsa de novo na iteracao seguinte e avanca para `SEEDS[1]`, entao o
esquema se recupera sozinho -- ao custo de duas iteracoes sem saida. Em 200
mil iteracoes do modelo nenhum colapso ocorreu, entao o caso nao foi
exercitado na pratica.
