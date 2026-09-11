#!/usr/bin/env python3
"""Modelo de referencia de rtl/takum_prng_core_pipe.sv: NPIPE geradores takum32
fundidos, independentes, com as saidas intercaladas.

E O MESMO MODELO DO NUCLEO INTERCALADO, COM MAIS FLUXOS. O pipeline espacial
nao muda a aritmetica de gerador nenhum -- a ordem das operacoes e os pontos de
arredondamento sao identicos aos de takum_prng_core_fused, so T e S voltam a
takum e os temporarios nunca. O que muda e onde o estado de cada fluxo mora: no
nucleo intercalado, num banco de registradores indexado pelo turno; aqui, nos
proprios registradores de pipeline, que andam um estagio por ciclo. Nenhuma das
duas coisas e visivel na sequencia, entao o modelo continua sendo N instancias
de TakumPrngFused em rodizio.

Que os dois nucleos partilhem modelo nao e conveniencia: e uma AFIRMACAO
VERIFICAVEL sobre o desenho. Se o desenrolamento espacial tivesse mudado a
ordem de um arredondamento -- por exemplo ao juntar duas operacoes num estagio
so -- a sequencia mudaria e a comparacao com este modelo acusaria. As tres
primeiras sementes sao as de takum_prng_core_multi justamente para que o fluxo
k dos dois nucleos coincida bit a bit para k < 3.

ORDEM DA SAIDA. No RTL os fluxos entram no anel um por ciclo, na ordem do
indice, e andam juntos: o fluxo k chega ao estagio de emissao no ciclo
k + S_EMIT e volta a chegar NPIPE ciclos depois. Entao a saida sai entrelacada
0, 1, ..., NPIPE-1, 0, 1, ... -- uma emissao POR CICLO, contra uma a cada 14 do
nucleo intercalado. E essa ordem que words32() e bitstream() reproduzem, e e
ela que o empacotador ve.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from takum_prng_fused_model import TakumPrngFused

# Espelham takum_prng_pkg::NPIPE / T_INIT_P / S_INIT_P / LFSR_INIT_P.
# Geradas por gen_pipe_seeds.py -- nao editar a mao.
NPIPE = 13

T_INIT_P = [0x2da1ecb6, 0x3936a6eb, 0x3ad20fa5, 0x32ab7b05, 0x3d58e63c,
            0x34faca60, 0x2b52d541, 0x3b92af8a, 0x2f6a9691, 0x389c85fc,
            0x3e082dff, 0x3694b6a0, 0x317a753b]

S_INIT_P = [0x3002fd11, 0x30665f0d, 0x37895a72, 0x3df93459, 0x2e52c3db,
            0x3a61e769, 0x33d0b593, 0x382526ba, 0x29ad3a2e, 0x3c3c465e,
            0x3626367d, 0x3ec3cdad, 0x334da02b]

LFSR_INIT_P = [0xACE1ACE1, 0x5A5A1234, 0x13579BDF, 0x2468ACE0, 0x7F3E1D5C,
               0xC0FFEE11, 0x1BADB002, 0xDEADC0DE, 0x5EED0FF1, 0x0BADCAFE,
               0xF00DBABE, 0x3C3C5A5A, 0x9E3779B9]


class TakumPrngPipe:
    """step() devolve (out_bits, valor) do proximo fluxo do rodizio."""

    def __init__(self):
        self.streams = [
            TakumPrngFused(T_INIT_P[k], S_INIT_P[k], LFSR_INIT_P[k])
            for k in range(NPIPE)
        ]
        self.turn = 0

    def step(self):
        nb, v = self.streams[self.turn].step()
        self.turn = (self.turn + 1) % NPIPE
        return nb, v


def words32(n_words):
    """Palavras de 32 bits na ordem do empacotador AXI-Stream."""
    p = TakumPrngPipe()
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
    p = TakumPrngPipe()
    bits = []
    while len(bits) < n_bits:
        nb, v = p.step()
        for i in range(nb - 1, -1, -1):
            bits.append((v >> i) & 1)
    return bits[:n_bits]


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    p = TakumPrngPipe()
    for i in range(n):
        nb, v = p.step()
        print('%6d  fluxo %2d  nbits %2d  0x%07x' % (i, i % NPIPE, nb, v))


if __name__ == '__main__':
    main()
