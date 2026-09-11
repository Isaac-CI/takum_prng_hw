#!/usr/bin/env python3
"""Confere uma captura de ILA da ZCU104 contra o modelo do PRNG.

    ./check_ila_csv.py captura.csv

O PRNG e determinista: sementes fixas, nenhuma entrada externa. Entao a
sequencia de palavras de 32 bits que sai do silicio tem de ser identica, bit a
bit, a que model/takum_prng_model.py produz com words32(). Este script faz essa
comparacao e e a verificacao que substitui olhar os LEDs -- ela nao diz apenas
que o design esta vivo, diz que ele esta correto.

O CSV vem de "Export ILA Data" no Hardware Manager. O alinhamento nao depende
de a captura ter comecado no beat 0: a sonda ila_beat_cnt carrega o indice
absoluto de cada beat, e e por ele que a comparacao se posiciona na sequencia
do modelo.

Um aviso de custo: o modelo e Python puro fazendo aritmetica takum, entao gerar
o golden ate um indice alto leva tempo. Disparar o ILA no beat 0 (VIO
trig_beat = 0) mantem a conferencia em segundos.
"""

import argparse
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..', 'model'))


# --- leitura do CSV ---------------------------------------------------------
# As colunas sao encontradas por trecho do nome, nao por posicao, porque o
# Hardware Manager prefixa as sondas com a hierarquia da instancia e a versao
# do Vivado muda o que exatamente aparece antes do nome do sinal.
COLUNAS = {
    'tdata':  ('tdata',),
    'beat':   ('beat_cnt', 'beat'),
    'tvalid': ('tvalid',),
}


def achar_coluna(cabecalho, chaves):
    for chave in chaves:
        for i, nome in enumerate(cabecalho):
            if chave in nome.lower():
                return i
    return None


# O exportador do Hardware Manager escreve o cabecalho e, logo abaixo, uma
# linha de radix com UMA BASE POR COLUNA:
#
#   Sample in Buffer,Sample in Window,TRIGGER,ila_tdata[31:0],ila_tvalid,...
#   Radix - UNSIGNED,UNSIGNED,UNSIGNED,HEX,HEX,HEX,HEX
#   0,0,1,3e4ec32b,1,00000000,1
#
# Ou seja, nao existe "a base do arquivo": as colunas de controle saem em
# decimal e as sondas em hexadecimal. Ler essa linha e o jeito certo, e torna
# a deteccao automatica um mero fallback para capturas sem ela.
BASES = {
    'HEX': 16, 'UNSIGNED': 10, 'SIGNED': 10, 'DECIMAL': 10,
    'BINARY': 2, 'OCTAL': 8,
}


def parse_radix(linha, n_colunas):
    """Converte a linha de radix em uma base por coluna, ou None se a linha
    nao for uma linha de radix."""
    campos = [c.strip().strip('"') for c in linha.split(',')]
    if not campos or not campos[0].upper().startswith('RADIX'):
        return None
    # O primeiro campo vem como "Radix - UNSIGNED"; os demais sao a base pura.
    campos[0] = campos[0].split('-', 1)[1].strip() if '-' in campos[0] else ''
    bases = [BASES.get(c.upper()) for c in campos]
    if len(bases) == 1 and bases[0]:
        return [bases[0]] * n_colunas      # uma base so, aplicada a tudo
    return bases


def ler_csv(caminho):
    """Devolve (cabecalho, bases, linhas) a partir do CSV exportado pelo ILA.

    bases e None quando o arquivo nao traz linha de radix."""
    with open(caminho, newline='') as f:
        linhas = [l.rstrip('\n\r') for l in f]

    idx = None
    for i, l in enumerate(linhas):
        if 'tdata' in l.lower():
            idx = i
            break
    if idx is None:
        sys.exit('ERRO: nao achei uma coluna com "tdata" no CSV. A captura foi '
                 'exportada com o .ltx carregado?')

    cabecalho = [c.strip().strip('"') for c in linhas[idx].split(',')]

    # A linha de radix costuma vir logo depois do cabecalho, mas ja vi
    # exportacoes com ela antes -- procurar nos dois lados custa nada.
    bases = None
    corpo = idx + 1
    if idx + 1 < len(linhas):
        b = parse_radix(linhas[idx + 1], len(cabecalho))
        if b:
            bases, corpo = b, idx + 2
    if bases is None and idx > 0:
        bases = parse_radix(linhas[idx - 1], len(cabecalho))

    dados = []
    for l in linhas[corpo:]:
        if not l.strip():
            continue
        campos = [c.strip().strip('"') for c in l.split(',')]
        if campos and campos[0].upper().startswith('RADIX'):
            continue
        dados.append(campos)
    return cabecalho, bases, dados


def converter(txt, base):
    txt = txt.strip()
    if not txt:
        raise ValueError('vazio')
    return int(txt, base)


def extrair(cabecalho, dados, bases):
    """Extrai (indice, palavra) dos beats. bases e a base de cada coluna."""
    c_tdata = achar_coluna(cabecalho, COLUNAS['tdata'])
    c_beat = achar_coluna(cabecalho, COLUNAS['beat'])
    c_valid = achar_coluna(cabecalho, COLUNAS['tvalid'])

    if c_tdata is None or c_beat is None:
        sys.exit('ERRO: o CSV nao tem as colunas ila_tdata e ila_beat_cnt.\n'
                 f'      colunas encontradas: {cabecalho}')

    def base_de(col):
        if bases and col < len(bases) and bases[col]:
            return bases[col]
        raise ValueError(f'sem base para a coluna {col}')

    beats = []
    for linha in dados:
        if max(c_tdata, c_beat) >= len(linha):
            continue
        if c_valid is not None and c_valid < len(linha):
            if converter(linha[c_valid], base_de(c_valid)) == 0:
                continue
        beats.append((converter(linha[c_beat], base_de(c_beat)),
                      converter(linha[c_tdata], base_de(c_tdata))))
    return beats


def contiguo(beats):
    """Os indices tem de andar de um em um. E tambem a validacao da base: se a
    captura for lida em decimal quando estava em hexadecimal (ou vice-versa),
    os indices deixam de ser consecutivos quase imediatamente."""
    if len(beats) < 2:
        return True
    return all(beats[i + 1][0] == beats[i][0] + 1 for i in range(len(beats) - 1))


def ler_captura(caminho, base_pedida):
    cabecalho, bases, dados = ler_csv(caminho)
    if not dados:
        sys.exit('ERRO: o CSV nao tem linhas de dados.')

    n = len(cabecalho)

    # --radix manda em tudo; sem ele, a linha de radix do proprio arquivo e a
    # fonte correta, porque ela sabe que cada coluna pode ter base diferente.
    if base_pedida != 'auto':
        base = 16 if base_pedida == 'hex' else 10
        try:
            return extrair(cabecalho, dados, [base] * n), f'{base} (forcada)'
        except ValueError as e:
            sys.exit(f'ERRO: --radix {base_pedida} nao serve para este CSV '
                     f'({e}).\n'
                     '      Sem --radix o script le a base declarada no proprio '
                     'arquivo, que e o normal.')

    if bases and any(bases):
        beats = extrair(cabecalho, dados, bases)
        if beats:
            return beats, 'declarada no arquivo'

    # Sem linha de radix: tentar as duas e deixar a continuidade dos indices
    # decidir. Se a base estiver errada, os indices deixam de ser consecutivos
    # quase imediatamente.
    erro = 'nenhuma linha de dados aproveitavel'
    for base in (16, 10):
        try:
            beats = extrair(cabecalho, dados, [base] * n)
        except ValueError as e:
            erro = e
            continue
        if beats and contiguo(beats):
            return beats, f'{base} (deduzida)'
        if beats:
            erro = 'indices de beat nao consecutivos'

    sys.exit(f'ERRO: nao consegui interpretar o CSV ({erro}).\n'
             '      Tente informar a base explicitamente com --radix hex ou '
             '--radix dec.')


# --- comparacao -------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('csv', help='CSV exportado pelo Hardware Manager')
    ap.add_argument('--radix', choices=['auto', 'hex', 'dec'], default='auto',
                    help='base dos valores no CSV (padrao: detecta sozinho)')
    ap.add_argument('--mostrar', type=int, default=10,
                    help='quantas divergencias listar (padrao: 10)')
    args = ap.parse_args()

    beats, base = ler_captura(args.csv, args.radix)
    primeiro, ultimo = beats[0][0], beats[-1][0]

    print(f'captura : {len(beats)} beats, indices {primeiro}..{ultimo} '
          f'(base {base})')

    if not contiguo(beats):
        print('AVISO: os indices de beat nao sao consecutivos. A captura pode '
              'ter sido feita sem a qualificacao de armazenamento em '
              'ila_tvalid; a comparacao segue, alinhada por indice.')

    try:
        from takum_prng_model import words32
    except ImportError as e:
        sys.exit(f'ERRO: nao consegui importar o modelo ({e}).\n'
                 '      Confira que ../model/takum_prng_model.py existe e que '
                 'arch_takum/model/takum_arith.py esta presente -- o modelo do '
                 'PRNG importa a aritmetica takum de la.')

    print(f'modelo  : gerando {ultimo + 1} palavras...', flush=True)
    golden = words32(ultimo + 1)

    falhas = []
    for indice, palavra in beats:
        if palavra != golden[indice]:
            falhas.append((indice, palavra, golden[indice]))

    print()
    if not falhas:
        print(f'OK: {len(beats)} beats conferidos, 0 divergencias.')
        print('    O hardware reproduz o modelo bit a bit.')
        return 0

    print(f'FALHA: {len(beats)} beats conferidos, {len(falhas)} divergencias.')
    print()
    print(f'  {"beat":>10}  {"hardware":>8}  {"modelo":>8}')
    for indice, hw, mod in falhas[:args.mostrar]:
        print(f'  {indice:>10}  {hw:08x}  {mod:08x}')
    if len(falhas) > args.mostrar:
        print(f'  ... e mais {len(falhas) - args.mostrar}')

    print()
    if falhas[0][0] == primeiro and len(falhas) == len(beats):
        print('Todas divergem, inclusive a primeira. Isso costuma ser '
              'alinhamento, nao aritmetica: confira se a captura foi feita '
              'depois de um reset pelo VIO.')
    elif len(falhas) < len(beats) * 0.01:
        print('Poucas divergencias isoladas apontam para timing, nao para '
              'logica -- o design correto nao erra em alguns beats e acerta '
              'nos outros. Reveja o WNS do build.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
