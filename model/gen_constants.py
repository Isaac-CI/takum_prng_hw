#!/usr/bin/env python3
"""Gera as constantes takum32 de rtl/takum_prng_pkg.sv.

Roda com

    python3 model/gen_constants.py

e imprime os localparams prontos para colar. Existe para que nenhuma
constante do RTL seja digitada a mao -- um digito hexadecimal trocado numa
delas nao quebraria a simulacao de forma obvia, so mudaria silenciosamente a
trajetoria caotica.

Cada valor decimal e convertido para L = 2*ln(v) e codificado com o mesmo
codificador do modelo de ouro. Fora 1.0, nenhum e exato: o valor de um takum
logaritmico e sqrt(e)^L, entao so potencias de sqrt(e) caem em cima de um
codigo. O valor reconstruido vai no comentario de cada linha.
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

CONSTS = [
    ('C_ONE',  1.0,    '1.0'),
    ('C_HALF', 0.5,    '0.5'),
    ('C_MU',   1.999,  '1.999'),
    # C_R16 = 0.9 * 16 = 14.4 dobra o ganho r do mapa seno dentro do numerador.
    # O mapa e S' = r * 16u/(5-4u); como r e 16 sao ambos constantes, r*16
    # tambem e, entao o numerador sai direto como 14.4u e a multiplicacao final
    # por r desaparece -- uma operacao a menos por iteracao, em todas as
    # variantes. E a mesma dobra que o gerador linear ja fazia em
    # takum_prng_rtl/prng/prng_pkg.sv; mante-la so de um lado deixaria a
    # comparacao log-vs-linear medindo tambem a diferenca de algebra.
    ('C_R16',  14.4,   '0.9*16'),
    ('C_C4',   4.0,    '4.0'),
    ('C_C5',   5.0,    '5.0'),
    # Dividindo numerador e denominador por 4, 14.4u/(5-4u) = 3.6u/(1.25-u).
    # Some a multiplicacao 4u: o denominador passa a ser uma subtracao direta
    # sobre u. Usado por takum_prng_core_pipe, onde isso vale dois passos --
    # a multiplicacao e o estagio que existia so para separa-la da subtracao,
    # ja que o operando da unidade Gauss-log passa a vir de um registrador.
    ('C_R36',  3.6,    '0.9*4'),
    ('C_125',  1.25,   '5/4'),
]

SEEDS = [0.0, 0.2, 0.123456, 0.654321, 0.723456, 0.234567, 0.572391, 0.981723]
INIT_X = SEEDS[2]


def encode(v):
    """Valor decimal -> (palavra takum32, valor reconstruido)."""
    if v == 0:
        return 0, Decimal(0)
    d = Decimal(str(v))
    bits = G.encode(N, 'num', 0 if v > 0 else 1, Fraction(2 * d.ln()))
    word = G.bits_to_uint(bits)
    dec = G.decode(bits, N)
    back = (Decimal(dec.L.numerator) / Decimal(dec.L.denominator) / 2).exp()
    return word, back


def main():
    print('  // ---- constantes dos mapas -----------------------------------')
    for name, v, label in CONSTS:
        w, back = encode(v)
        exact = 'exato' if back == Decimal(str(v)) else f'{back:.12f}'
        print(f"  localparam logic [N-1:0] {name:6s} = 32'h{w:08x};  // {label:7s} {exact}")

    print()
    print("  localparam logic [N-1:0] SEEDS [0:7] = '{")
    for i, v in enumerate(SEEDS):
        w, back = encode(v)
        comma = ',' if i < len(SEEDS) - 1 else ' '
        print(f"      32'h{w:08x}{comma}   // {v:<9} {back:.12f}")
    print('  };')

    print()
    for name, v, label in (('T_INIT', INIT_X, 'INIT_X'),
                           ('S_INIT', round(INIT_X + 0.1, 6), 'INIT_X + 0.1')):
        w, back = encode(v)
        print(f"  localparam logic [N-1:0] {name} = 32'h{w:08x};  // {label} = {v}  {back:.12f}")


if __name__ == '__main__':
    main()
