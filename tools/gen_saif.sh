#!/bin/bash
# -----------------------------------------------------------------------------
# Gera um SAIF com a atividade de chaveamento real do PRNG, para que o
# report_power pare de adivinhar.
#
#   cd takum_prng && ./tools/gen_saif.sh
#
# Sem SAIF, o Vivado estima a atividade por heuristica ("vectorless"): ele
# supoe uma taxa de chaveamento para cada no sem saber o que o circuito faz.
# Para um datapath de aritmetica takum, cheio de ROMs e DSPs cujo padrao de
# acesso depende do regime dos operandos, esse chute e ruim -- e a potencia
# dinamica e justamente a parte do PPA que depende dele.
#
# O SAIF sai de uma simulacao comportamental do proprio takum_prng_axis. O
# padrao e 500 us de tempo simulado -- 50 mil ciclos, ~850 beats, varias
# centenas de iteracoes dos dois mapas. Isso e amostra de sobra para a
# atividade media estabilizar: o que se mede aqui e taxa de chaveamento, que
# converge muito antes do que qualquer estatistica de aleatoriedade.
#
# O arquivo sai grande -- ~170 MB -- e isso NAO vem da duracao: 500 us e 2 ms
# dao praticamente o mesmo tamanho (172 vs 181 MB). Vem da quantidade de nos
# registrados, porque log_saif percorre recursivamente todo o interior da ALU
# e escreve uma entrada por no, tenha ele chaveado ou nao. Dos ~1,8 milhao de
# entradas, so cerca de 6650 tem chaveamento -- que sao, essas sim, as que
# importam para a potencia.
#
# Duas consequencias praticas. Reduzir a duracao encurta o tempo de simulacao
# (45 s a 2 ms, ~12 s a 500 us) mas nao encolhe o arquivo. E o SAIF nao deve
# ser transferido entre maquinas: gere-o onde o report_power vai rodar.
#
#   ./tools/gen_saif.sh                 # 500 us, prng.saif
#   ./tools/gen_saif.sh outro.saif 1ms  # duracao a gosto
#
# Depois:  vivado -mode batch -source zcu104/report_ppa.tcl -tclargs $PWD/prng.saif
# -----------------------------------------------------------------------------
set -e

# Todos os caminhos daqui para baixo sao relativos a raiz de takum_prng, entao
# o script se muda para la em vez de exigir que voce esteja no lugar certo --
# rodar de tools/ ou de qualquer outro diretorio funciona igual.
HERE=$(cd "$(dirname "$0")" && pwd)
PRNG=$(cd "$HERE/.." && pwd)

# O SAIF, esse sim, vai para onde voce chamou o script, e nao para a raiz do
# projeto: e mais previsivel encontrar o arquivo onde se estava.
CHAMADA=$(pwd)
case "${1:-}" in
    /*) SAIF="${1}" ;;                       # caminho absoluto, respeitado
    "") SAIF="$CHAMADA/prng.saif" ;;
    *)  SAIF="$CHAMADA/${1}" ;;
esac
DUR=${2:-500us}

cd "$PRNG"
LNS=../arch_takum/rtl/lns

if [ ! -d "$LNS" ]; then
    echo "ERRO: nao encontrei $LNS (a partir de $PRNG)." >&2
    echo "      O clone do arch_takum precisa estar como irmao de takum_prng." >&2
    exit 1
fi
if [ ! -f tb/tb_takum_prng_rate.sv ]; then
    echo "ERRO: nao encontrei tb/tb_takum_prng_rate.sv em $PRNG." >&2
    exit 1
fi

echo "projeto : $PRNG"
echo "saida   : $SAIF"
echo "duracao : $DUR"
echo

rm -rf xsim.dir *.pb *.wdb xsim_webtalk.tcl saif_run.tcl

xvlog -sv --nolog \
      $LNS/takum_log_pkg.sv rtl/takum_prng_pkg.sv \
      $LNS/takum_log_decoder.sv $LNS/takum_log_encoder.sv \
      $LNS/takum_log_gausslog_unit.sv $LNS/takum_log_negator.sv \
      $LNS/takum_log_adder.sv $LNS/takum_log_subtractor.sv \
      $LNS/takum_log_multiplier.sv $LNS/takum_log_divider.sv \
      $LNS/takum_log_alu.sv \
      rtl/takum_prng_perturb.sv rtl/takum_prng_core.sv \
      rtl/takum_prng_packer.sv rtl/takum_prng_axis.sv \
      tb/tb_takum_prng_rate.sv

# -debug typical e necessario: sem ele os objetos internos nao ficam
# acessiveis e o log_saif nao tem o que registrar.
#
# -timescale existe porque o testbench declara `timescale 1ns/1ps e o RTL nao
# declara nenhum. O xsim 2026.1 aceita a mistura; o 2024.2 a rejeita com
# "[XSIM 43-4100] ... at least one module in design doesn't have timescale".
# Esta opcao da um timescale padrao aos modulos que nao tem, o que resolve nas
# duas versoes sem precisar editar o RTL. Nao muda comportamento nenhum: os
# modulos do design sao inteiramente sincronos, sem atrasos, entao o timescale
# deles so importa para o parser.
xelab --nolog -timescale 1ns/1ps \
      -top tb_takum_prng_rate -snapshot saif_snap -debug typical

cat > saif_run.tcl <<TCL
open_saif $SAIF
log_saif [get_objects -r /tb_takum_prng_rate/u_prng/*]
run $DUR
close_saif
quit
TCL

xsim saif_snap -tclbatch saif_run.tcl --nolog

rm -rf xsim.dir *.pb *.wdb xsim_webtalk.tcl saif_run.tcl

if [ ! -s "$SAIF" ]; then
    echo "ERRO: a simulacao terminou mas $SAIF nao foi criado (ou esta vazio)." >&2
    exit 1
fi

echo
echo "SAIF gravado em: $SAIF  ($(du -h "$SAIF" | cut -f1))"
echo "Use com:"
echo "  vivado -mode batch -notrace -source $PRNG/zcu104/report_ppa.tcl -tclargs $SAIF"
