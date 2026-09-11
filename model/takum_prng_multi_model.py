#!/usr/bin/env python3
"""Modelo de referencia de rtl/takum_prng_core_multi.sv: NSTREAMS geradores
takum32 fundidos, independentes, com as saidas intercaladas.

CADA FLUXO E UM TakumPrngFused. A intercalacao nao muda a aritmetica de gerador
nenhum -- ela so compartilha a ALU no tempo. Entao o modelo e literalmente tres
instancias do modelo fundido, cada uma com suas sementes, emitindo em rodizio.

ORDEM DA SAIDA. No RTL os tres fluxos partem juntos e sao servidos em ordem de
indice -- o passo n do fluxo k acontece no ciclo NSTREAMS*n + k -- entao eles
alcancam a emissao em ordem de indice e a saida sai entrelacada
0, 1, 2, 0, 1, 2, ... E essa ordem que words32() e bitstream() reproduzem, e e
ela que o empacotador ve.

POR QUE AS SEMENTES DIFEREM EM DOIS EIXOS. Os estados iniciais dos mapas sao
distintos pelo motivo obvio: iguais dariam tres copias da mesma sequencia. Os
estados iniciais do LFSR tambem diferem por um motivo menos obvio -- a
dependencia sensivel as condicoes iniciais separa orbitas caoticas como
tendencia estatistica, nao como garantia, e duas orbitas podem se aproximar por
trechos. E a perturbacao por LFSR que descorrelaciona ativamente, entao dar a
cada fluxo um LFSR proprio remove a unica fonte de correlacao que de outro modo
seria comum aos tres. Custo: tres constantes em vez de uma.

A independencia efetiva quem julga e a bateria NIST sobre o bitstream
intercalado: correlacao entre fluxos apareceria nos testes de autocorrelacao e
de casamento de padroes.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from takum_prng_fused_model import TakumPrngFused

# Espelham takum_prng_pkg::T_INIT_M / S_INIT_M / LFSR_INIT_M.
NSTREAMS = 3

T_INIT_M = [0x2da1ecb6, 0x3936a6eb, 0x3ad20fa5]   # 0,123456  0,654321  0,723456
S_INIT_M = [0x3002fd11, 0x30665f0d, 0x37895a72]   # 0,223456  0,234567  0,572391
LFSR_INIT_M = [0xACE1ACE1, 0x5A5A1234, 0x13579BDF]


class TakumPrngMulti:
    """step() devolve (out_bits, valor) do proximo fluxo do rodizio."""

    def __init__(self):
        self.streams = [
            TakumPrngFused(T_INIT_M[k], S_INIT_M[k], LFSR_INIT_M[k])
            for k in range(NSTREAMS)
        ]
        self.turn = 0

    def step(self):
        nb, v = self.streams[self.turn].step()
        self.turn = (self.turn + 1) % NSTREAMS
        return nb, v


def words32(n_words):
    """Palavras de 32 bits na ordem do empacotador AXI-Stream."""
    p = TakumPrngMulti()
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
    p = TakumPrngMulti()
    bits = []
    while len(bits) < n_bits:
        nb, v = p.step()
        for i in range(nb - 1, -1, -1):
            bits.append((v >> i) & 1)
    return bits[:n_bits]


if __name__ == '__main__':
    p = TakumPrngMulti()
    print(f"{'emissao':>8} {'fluxo':>6} {'nb':>3} {'out':>8}")
    for i in range(12):
        k = p.turn
        nb, v = p.step()
        print(f'{i:>8} {k:>6} {nb:>3} {v:08x}')
