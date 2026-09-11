#!/usr/bin/env python3
"""Junta as janelas capturadas pelo ILA num unico arquivo binario para o NIST.

    ./csv_to_bin.py captura/ -o prng.bin
    ./csv_to_bin.py captura/ -o prng.bin --conferir 4096

Le todos os janela_*.csv produzidos por capture_stream.tcl, verifica que os
indices de beat formam uma sequencia continua sem buracos nem sobreposicoes, e
grava as palavras de 32 bits em ordem big-endian.

ORDEM DOS BITS. O empacotador do RTL entrega os bits do mais significativo para
o menos significativo de cada emissao, e a palavra de 32 bits leva os bits mais
antigos primeiro. Gravar big-endian preserva exatamente essa ordem: o primeiro
byte do arquivo carrega os 8 bits mais antigos, com o mais antigo no MSB. E a
mesma ordem que bitstream() produz no modelo, e a que o NIST espera de um
arquivo binario.

A verificacao de continuidade nao e decorativa. Se uma janela falhar, se o
reset do VIO nao tiver pegado ou se duas janelas se sobrepuserem, o arquivo
resultante teria um defeito estrutural que a bateria NIST poderia acusar como
falha do gerador -- quando o problema seria da extracao.
"""

import argparse
import glob
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, '..', 'model'))

from check_ila_csv import ler_captura


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dir', help='diretorio com os janela_*.csv')
    ap.add_argument('-o', '--saida', default='prng.bin',
                    help='arquivo binario de saida (padrao: prng.bin)')
    ap.add_argument('--conferir', type=int, default=0, metavar='N',
                    help='confere as primeiras N palavras contra o modelo '
                         '(0 = nao conferir; o modelo e Python puro e lento)')
    ap.add_argument('--radix', choices=['auto', 'hex', 'dec'], default='auto')
    args = ap.parse_args()

    arquivos = sorted(glob.glob(os.path.join(args.dir, 'janela_*.csv')))
    if not arquivos:
        sys.exit(f'ERRO: nenhum janela_*.csv em {args.dir}')

    print(f'janelas : {len(arquivos)}')

    palavras = []
    esperado = None
    for caminho in arquivos:
        beats, _ = ler_captura(caminho, args.radix)
        if not beats:
            sys.exit(f'ERRO: {os.path.basename(caminho)} nao tem beats.')

        primeiro = beats[0][0]
        if esperado is None:
            esperado = primeiro
            if primeiro != 0:
                print(f'aviso  : a sequencia comeca no beat {primeiro}, nao em '
                      f'0. O arquivo sera um trecho do fluxo, nao o inicio.')
        elif primeiro != esperado:
            sys.exit(
                f'ERRO: descontinuidade em {os.path.basename(caminho)}.\n'
                f'      esperava o beat {esperado}, veio {primeiro}.\n'
                f'      Diferenca de {primeiro - esperado} beats -- '
                f'{"buraco" if primeiro > esperado else "sobreposicao"} na '
                f'sequencia.\n'
                f'      O arquivo nao foi gravado; a captura precisa ser '
                f'refeita.')

        for i in range(1, len(beats)):
            if beats[i][0] != beats[i - 1][0] + 1:
                sys.exit(f'ERRO: buraco dentro de '
                         f'{os.path.basename(caminho)}, entre os beats '
                         f'{beats[i-1][0]} e {beats[i][0]}.')

        palavras.extend(p for _, p in beats)
        esperado = beats[-1][0] + 1

    print(f'beats   : {len(palavras)} continuos, '
          f'indices {esperado - len(palavras)}..{esperado - 1}')

    if args.conferir:
        n = min(args.conferir, len(palavras))
        inicio = esperado - len(palavras)
        if inicio != 0:
            print(f'aviso  : conferindo a partir do beat {inicio}, o que exige '
                  f'gerar {inicio + n} palavras no modelo.')
        print(f'modelo  : gerando {inicio + n} palavras para conferir...',
              flush=True)
        from takum_prng_model import words32
        golden = words32(inicio + n)
        ruins = [i for i in range(n) if palavras[i] != golden[inicio + i]]
        if ruins:
            sys.exit(f'ERRO: {len(ruins)} das {n} primeiras palavras divergem '
                     f'do modelo. Primeira no beat {inicio + ruins[0]}.')
        print(f'        OK: {n} palavras conferem com o modelo.')

    with open(args.saida, 'wb') as f:
        f.write(struct.pack(f'>{len(palavras)}I', *palavras))

    bits = len(palavras) * 32
    tam = os.path.getsize(args.saida)
    print()
    print(f'gravado : {args.saida}')
    print(f'          {tam} bytes, {bits} bits')
    print(f'          {bits // 1000000} sequencias NIST de 1 Mbit '
          f'(sobram {bits % 1000000} bits)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
