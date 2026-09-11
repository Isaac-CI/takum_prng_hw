#!/usr/bin/env python3
"""Modelo de referencia do PRNG takum32 com DATAPATH FUNDIDO.

Corresponde a rtl/takum_prng_core_fused.sv, assim como takum_prng_model.py
corresponde a rtl/takum_prng_core.sv. Os dois geradores sao o mesmo desenho --
mapa tenda acoplado ao mapa seno de Bhaskara, perturbados por LFSR e trocados a
cada iteracao -- e produzem SEQUENCIAS DIFERENTES.

A DIFERENCA, EM UMA FRASE. Na versao nao fundida cada operacao codifica o
resultado de volta para takum32, o que arredonda para a precisao do formato.
Aqui os temporarios permanecem no formato interno e so ha arredondamento ao
escrever t e s. Menos arredondamento, mais precisao -- e, num sistema caotico,
outra orbita a partir da primeira iteracao.

O QUE CONTINUA IDENTICO. A perturbacao e as salvaguardas operam sobre a palavra
takum (regime, campo de mantissa, comparacoes monotonicas), entao t e s tem de
ser codificados antes delas de qualquer forma. Por isso perturb(), lfsr_next() e
a formacao da saida sao reaproveitados de takum_prng_model.py sem alteracao: a
fusao muda a aritmetica dos mapas, nao a extracao de bits.

ONDE CADA VALOR VIVE, seguindo o microcodigo do RTL passo a passo:

    A = 1 - T          interno      (temporario, nunca inspecionado)
    T = MU * (...)     takum        (perturbacao le o regime dele)
    A = 1 - S          interno
    B = S * A          interno      -> u
    A = R16 * B        interno      -> 14,4u  (0.9*16 dobrados na constante)
    B = C4 * B         interno      -> 4u
    B = C5 - B         interno      -> 5 - 4u
    S = A / B          takum        -> 14,4u/(5-4u), ja com o ganho r
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..', '..', 'arch_takum', 'model'))

from takum_arith_internal import from_takum, to_takum, imul, idiv, isub

from takum_prng_model import (
    ONE, HALF, MU, R16, C4, C5,
    T_INIT, S_INIT, LFSR_INIT,
    perturb, lfsr_next, si,
)


class TakumPrngFused:
    """Mesma interface de TakumPrng: step() devolve (out_bits, valor)."""

    def __init__(self, t_init=None, s_init=None, lfsr_init=None):
        # As sementes sao argumentos porque takum_prng_core_multi roda varios
        # destes em paralelo, e fluxos que partissem do mesmo estado dariam a
        # mesma sequencia. Os defaults reproduzem o gerador de um fluxo so.
        self.t = T_INIT if t_init is None else t_init
        self.s = S_INIT if s_init is None else s_init
        self.lfsr = LFSR_INIT if lfsr_init is None else lfsr_init
        self.idx_t = 0
        self.idx_s = 0

    def step(self):
        # --- 1. mapa tenda -------------------------------------------------
        # Os dois ramos sao sempre calculados: o hardware roda em tempo
        # constante, sem desvio dependente de dado.
        t_lt_half = si(self.t) < si(HALF)
        A = isub(from_takum(ONE), from_takum(self.t))          # interno
        t_new = to_takum(imul(from_takum(MU),
                              from_takum(self.t) if t_lt_half else A))

        # --- 2. mapa seno por Bhaskara -------------------------------------
        # sin(pi*x) ~ 16u/(5-4u) com u = x(1-x). Toda a cadeia permanece no
        # formato interno; so o quociente final e codificado. O ganho r esta
        # dobrado em R16, entao nao ha multiplicacao depois da divisao.
        A = isub(from_takum(ONE), from_takum(self.s))          # 1 - S
        B = imul(from_takum(self.s), A)                        # u
        A = imul(from_takum(R16), B)                           # 14,4u
        B = imul(from_takum(C4), B)                            # 4u
        B = isub(from_takum(C5), B)                            # 5 - 4u
        s_new = to_takum(idiv(A, B))                           # 14,4u/(5-4u)

        # --- 3. LFSR --------------------------------------------------------
        self.lfsr = lfsr_next(self.lfsr)

        # --- 4/5. perturbacao ----------------------------------------------
        # Sobre a palavra takum, identica a versao nao fundida.
        t_new, mb_t, mt, self.idx_t = perturb(t_new, self.lfsr, self.idx_t)
        s_new, mb_s, ms, self.idx_s = perturb(s_new, self.lfsr, self.idx_s)

        # --- 6. saida -------------------------------------------------------
        out_bits = min(mb_t, mb_s)
        out_val = ((mt ^ ms ^ self.lfsr) & ((1 << out_bits) - 1)) if out_bits else 0

        # --- 7. troca, para o acoplamento 2D --------------------------------
        self.t, self.s = s_new, t_new

        return out_bits, out_val


def words32(n_words):
    """Palavras de 32 bits na ordem do empacotador AXI-Stream."""
    p = TakumPrngFused()
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
    """Bits de saida, do mais significativo de cada emissao para o menos."""
    p = TakumPrngFused()
    bits = []
    while len(bits) < n_bits:
        nb, v = p.step()
        for i in range(nb - 1, -1, -1):
            bits.append((v >> i) & 1)
    return bits[:n_bits]


if __name__ == '__main__':
    p = TakumPrngFused()
    print(f"{'it':>5} {'t':>10} {'s':>10} {'lfsr':>10} {'nb':>3} {'out':>8}")
    for i in range(12):
        nb, v = p.step()
        print(f'{i:>5} {p.t:08x}   {p.s:08x}   {p.lfsr:08x}  {nb:>3} {v:08x}')
