#!/usr/bin/env python3
"""Gera as sementes dos NPIPE fluxos de rtl/takum_prng_core_pipe.sv.

O nucleo em pipeline espacial mantem um fluxo por estagio, entao precisa de
NPIPE estados iniciais distintos -- muito mais que os tres do nucleo
intercalado. Digitar treze triplas a mao seria pedir para errar um digito
sem que nada quebrasse de forma visivel, entao elas saem daqui, do mesmo
codificador do modelo de ouro.

Roda com

    python3 model/gen_pipe_seeds.py

e imprime tanto o bloco de localparams do pacote SystemVerilog quanto as
listas Python do modelo de referencia, para que os dois nunca divirjam.

CRITERIO DE ESCOLHA. Os valores dos mapas sao espalhados por (0,1) sem relacao
aritmetica aparente entre si -- nada de progressoes, que dariam orbitas
iniciadas em pontos proximos no espaco de fase. Os estados de LFSR sao nao
nulos e sem estrutura compartilhada. Os tres primeiros fluxos repetem as
sementes de takum_prng_core_multi de proposito: assim o fluxo k do pipeline e
bit a bit o fluxo k do intercalado, e qualquer divergencia entre os dois
nucleos aparece na comparacao direta em vez de se esconder atras de sementes
diferentes.
"""
import os
import sys
from decimal import Decimal, getcontext
from fractions import Fraction

getcontext().prec = 60

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..', '..', 'takum_ula', 'lns',
                                'takum_log', 'model'))
import takum_log as G   # noqa: E402

N = 32
NPIPE = 13

# Os tres primeiros casam com T_INIT_M / S_INIT_M / LFSR_INIT_M do pacote.
T_VALS = [
    0.123456, 0.654321, 0.723456,
    0.311527, 0.847219, 0.415803, 0.069314, 0.758291,
    0.192837, 0.630157, 0.884261, 0.507943, 0.268419,
]

S_VALS = [
    0.223456, 0.234567, 0.572391,
    0.881034, 0.146728, 0.703915, 0.359482, 0.612057,
    0.045921, 0.790346, 0.481263, 0.925708, 0.337194,
]

LFSR_VALS = [
    0xACE1ACE1, 0x5A5A1234, 0x13579BDF,
    0x2468ACE0, 0x7F3E1D5C, 0xC0FFEE11, 0x1BADB002, 0xDEADC0DE,
    0x5EED0FF1, 0x0BADCAFE, 0xF00DBABE, 0x3C3C5A5A, 0x9E3779B9,
]


def encode(v):
    """Valor decimal -> (palavra takum32, valor reconstruido)."""
    d = Decimal(str(v))
    bits = G.encode(N, 'num', 0, Fraction(2 * d.ln()))
    word = G.bits_to_uint(bits)
    dec = G.decode(bits, N)
    back = (Decimal(dec.L.numerator) / Decimal(dec.L.denominator) / 2).exp()
    return word, back


def main():
    for nome, vals in (('T', T_VALS), ('S', S_VALS)):
        assert len(vals) == NPIPE, f'{nome}: {len(vals)} valores, esperava {NPIPE}'
        assert len(set(vals)) == NPIPE, f'{nome}: ha valores repetidos'
    assert len(set(LFSR_VALS)) == NPIPE, 'LFSR: ha estados repetidos'
    assert 0 not in LFSR_VALS, 'LFSR: estado nulo trava o registrador'

    t_words = [encode(v) for v in T_VALS]
    s_words = [encode(v) for v in S_VALS]

    # Palavras repetidas significariam dois fluxos com a mesma orbita.
    assert len(set(w for w, _ in t_words)) == NPIPE, 'T: palavras takum colidiram'
    assert len(set(w for w, _ in s_words)) == NPIPE, 'S: palavras takum colidiram'

    print('  localparam int NPIPE = %d;\n' % NPIPE)

    for nome, vals, words in (('T_INIT_P', T_VALS, t_words),
                              ('S_INIT_P', S_VALS, s_words)):
        print("  localparam logic [N-1:0] %s [0:NPIPE-1] = '{" % nome)
        for k, (v, (w, back)) in enumerate(zip(vals, words)):
            virg = ',' if k < NPIPE - 1 else ' '
            print("      32'h%08x%s   // %-9s %s" % (w, virg, v, str(back)[:14]))
        print('  };\n')

    print("  localparam logic [31:0] LFSR_INIT_P [0:NPIPE-1] = '{")
    for k, v in enumerate(LFSR_VALS):
        virg = ',' if k < NPIPE - 1 else ' '
        print("      32'h%08X%s" % (v, virg))
    print('  };')

    print('\n# ---- para model/takum_prng_pipe_model.py ----')
    print('NPIPE = %d' % NPIPE)
    for nome, words in (('T_INIT_P', t_words), ('S_INIT_P', s_words)):
        print('%s = [%s]' % (nome, ', '.join('0x%08x' % w for w, _ in words)))
    print('LFSR_INIT_P = [%s]' % ', '.join('0x%08X' % v for v in LFSR_VALS))


if __name__ == '__main__':
    main()
