"""Modelo de referencia bit-exato do PRNG caotico takum32.

Acoplamento entre o mapa tenda e o mapa seno (aproximacao de Bhaskara), com
as saidas de cada mapa perturbadas por um LFSR de Galois e trocadas entre si
a cada iteracao. Porte do gerador em float32 do usuario para takum
logaritmico de 32 bits.

A aritmetica NAO e a do Python: soma, subtracao, multiplicacao e divisao vem
do modelo bit-exato do RTL em ../../arch_takum, para que este modelo e o
hardware produzam exatamente o mesmo bitstream. Serve para gerar os vetores
golden do testbench.

DIFERENCA DELIBERADA CONTRA O REFERENCIAL EM FLOAT32
----------------------------------------------------
Duas coisas mudam no porte, e nenhuma e evitavel:

  * A mantissa nao tem largura fixa. Em IEEE754 sao sempre 23 bits; no
    takum32 o campo M tem p = 27 - r, variando de 20 a 27 conforme o regime.
    O codigo original ja carregava m_bits_t/m_bits_s e out_bits = min(...),
    entao a estrutura absorve isso -- mas a saida por iteracao passa a ter
    largura variavel.

  * Nenhuma constante decimal e exata. O valor de um takum logaritmico e
    sqrt(e)^L, entao so potencias de sqrt(e) sao exatas: nem 0.5, nem 1.999,
    nem 5.0. Os mapas sao caoticos, entao essas diferencas de ultimo bit
    divergem em poucas dezenas de iteracoes.

Consequencia: este gerador NAO reproduz o bitstream do float32, e nao teria
como. A comparacao entre os dois e estatistica (NIST), nao bit a bit.
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..', '..', 'arch_takum', 'model'))

from takum_arith import add, sub, mul, div, negate, decode, N, NAR, ZERO, WF

# ---------------------------------------------------------------------------
# Constantes, ja no formato takum32 (geradas por gen_constants.py)
# ---------------------------------------------------------------------------
ONE  = 0x40000000   # 1.0        exato
HALF = 0x36746f40   # 0.5        0.499999999048
MU   = 0x498a8a8a   # 1.999      1.998999998547
R16  = 0x54ab3ddf   # 0.9*16     14.400000005907
C4   = 0x4f17217f   # 4.0        3.999999985435
C5   = 0x5070107e   # 5.0        5.000000001342

SEEDS = [
    0x00000000,     # 0.0
    0x2f8fef82,     # 0.2
    0x2da1ecb6,     # 0.123456
    0x3936a6eb,     # 0.654321
    0x3ad20fa5,     # 0.723456
    0x30665f0d,     # 0.234567
    0x37895a72,     # 0.572391
    0x3fb471e0,     # 0.981723
]

T_INIT = SEEDS[2]   # INIT_X
S_INIT = 0x3002fd11 # INIT_X + 0.1 = 0.223456
LFSR_INIT = 0xACE1ACE1
LFSR_POLY = 0x80200003
LFSR_STEPS = 8


def si(x):
    """Palavra takum como inteiro com sinal -- a ordem de inteiro com sinal e
    exatamente a ordem dos valores (o formato e monotonico), entao comparar
    magnitudes e comparar palavras."""
    return x - (1 << N) if x >> (N - 1) else x


def mantissa_bits(word):
    """Largura p do campo M e o proprio campo, para uma palavra normal."""
    D = (word >> (N - 2)) & 1
    Rv = (word >> (N - 5)) & 7
    r = Rv if D else 7 - Rv
    p = WF - r
    return p, (word & ((1 << p) - 1) if p else 0)


def lfsr_next(state):
    """LFSR de Galois de 32 bits, LFSR_STEPS passos por iteracao."""
    for _ in range(LFSR_STEPS):
        bit = state & 1
        state >>= 1
        if bit:
            state ^= LFSR_POLY
    return state


def perturb(x, lfsr, seed_index):
    """Inspeciona, extrai a mantissa, perturba e resgata -- os passos 4 e 5 do
    gerador original.

    Devolve (novo x, m_bits, m_out, novo seed_index). Em colapso (zero ou
    NaR) o estado e resemeado e m_bits = 0, o que suprime a saida daquela
    iteracao.
    """
    if x == ZERO or x == NAR:
        return SEEDS[seed_index & 7], 0, 0, seed_index + 1

    p, m_out = mantissa_bits(x)          # mantissa capturada ANTES da perturbacao
    x ^= lfsr & ((1 << p) - 1)

    # Salvaguardas: mesma logica do original, com as comparacoes feitas na
    # palavra (monotonica) em vez do valor.
    if si(x) < 0:
        x = negate(x)                    # valor absoluto
    elif si(x) > si(ONE):
        x = div(ONE, x)                  # inversao, exata no dominio log

    return x, p, m_out, seed_index


class TakumPrng:
    def __init__(self):
        self.t = T_INIT
        self.s = S_INIT
        self.lfsr = LFSR_INIT
        self.idx_t = 0
        self.idx_s = 0

    def step(self):
        """Uma iteracao. Devolve (out_bits, valor) -- out_bits pode ser 0."""
        # --- 1. mapa tenda -------------------------------------------------
        # Os dois ramos sao sempre calculados: o hardware roda em tempo
        # constante, sem desvio dependente de dado.
        t_lt_half = si(self.t) < si(HALF)
        t_hi = sub(ONE, self.t)
        t_new = mul(MU, self.t if t_lt_half else t_hi)

        # --- 2. mapa seno por Bhaskara -------------------------------------
        # sin(pi*x) ~ 16u/(5-4u) com u = x(1-x); os pi^2 se cancelam. O ganho
        # r do mapa esta dobrado em R16 = 0.9*16, entao o quociente ja e S' --
        # ver o comentario de C_R16 em rtl/takum_prng_pkg.sv.
        a = sub(ONE, self.s)
        u = mul(self.s, a)
        n = mul(R16, u)
        m = mul(C4, u)
        d = sub(C5, m)
        s_new = div(n, d)

        # --- 3. LFSR --------------------------------------------------------
        self.lfsr = lfsr_next(self.lfsr)

        # --- 4/5. perturbacao ----------------------------------------------
        t_new, mb_t, mt, self.idx_t = perturb(t_new, self.lfsr, self.idx_t)
        s_new, mb_s, ms, self.idx_s = perturb(s_new, self.lfsr, self.idx_s)

        # --- 6. saida -------------------------------------------------------
        out_bits = min(mb_t, mb_s)
        out_val = ((mt ^ ms ^ self.lfsr) & ((1 << out_bits) - 1)) if out_bits else 0

        # --- 7. troca, para o acoplamento 2D --------------------------------
        self.t, self.s = s_new, t_new

        return out_bits, out_val


def words32(n_words):
    """Palavras de 32 bits na mesma ordem do empacotador AXI-Stream do RTL.

    Os bits entram do mais significativo para o menos significativo de cada
    emissao, e cada palavra leva os 32 bits mais antigos ainda nao entregues
    -- exatamente o que takum_prng_packer.sv faz, e a mesma ordem do
    BitWriter do gerador de referencia.
    """
    p = TakumPrng()
    acc = 0
    cnt = 0
    out = []
    while len(out) < n_words:
        nb, v = p.step()
        if nb:
            acc = (acc << nb) | v
            cnt += nb
        while cnt >= 32:
            out.append((acc >> (cnt - 32)) & 0xFFFFFFFF)
            cnt -= 32
    return out


def bitstream(n_bits):
    """Gera n_bits de saida, do bit mais significativo de cada emissao para o
    menos -- mesma ordem do BitWriter do original."""
    p = TakumPrng()
    bits = []
    while len(bits) < n_bits:
        nb, v = p.step()
        for i in range(nb - 1, -1, -1):
            bits.append((v >> i) & 1)
    return bits[:n_bits]


if __name__ == '__main__':
    p = TakumPrng()
    print(f"{'it':>5} {'t':>10} {'s':>10} {'lfsr':>10} {'nb':>3} {'out':>8}")
    for i in range(12):
        nb, v = p.step()
        print(f'{i:>5} {p.t:08x}   {p.s:08x}   {p.lfsr:08x}  {nb:>3} {v:08x}')
