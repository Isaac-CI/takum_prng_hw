#!/bin/bash
# -----------------------------------------------------------------------------
# Gera um SAIF a partir do NETLIST IMPLEMENTADO, para que a potencia deixe de
# depender de atividade estimada.
#
#   cd takum_prng && ./tools/gen_saif_postimpl.sh              # funcsim
#   cd takum_prng && ./tools/gen_saif_postimpl.sh --timesim    # com SDF
#
# DIFERENCA PARA O gen_saif.sh. Aquele simula o RTL. Os nomes de sinal do RTL
# so sobrevivem parcialmente a sintese -- registradores e portas de hierarquia
# mantem o nome, mas as redes combinacionais internas viram saidas de LUT com
# nomes gerados -- entao o report_power casa menos de um quarto dos nos
# internos e estima o resto. Aqui a simulacao roda sobre o proprio netlist
# roteado, onde os nomes ja sao os fisicos, e a anotacao cobre o circuito
# inteiro.
#
# OS DOIS MODOS
#
#   funcsim (padrao) -- netlist funcional, sem atrasos. Toda logica combinacional
#       resolve instantaneamente, entao a simulacao ve apenas as transicoes
#       "verdadeiras": as que sobrevivem ate o proximo registrador. Rapido.
#
#   timesim (--timesim) -- netlist com atrasos anotados por SDF. Como cada
#       caminho combinacional tem atraso proprio, as entradas de uma porta
#       chegam em instantes diferentes e a saida pode oscilar antes de assentar.
#       Essas transicoes espurias sao os GLITCHES, e elas gastam energia de
#       verdade: cada uma carrega e descarrega capacitancia igual a uma
#       transicao util. Num datapath aritmetico encadeado como este -- somadores
#       e multiplicadores em cascata, onde o carry chega tarde -- a potencia de
#       glitch chega a ser parcela relevante do total. O funcsim nao a enxerga e
#       portanto SUBESTIMA; o timesim a captura.
#
# O preco do timesim e tempo de simulacao, por dois motivos que se somam: o
# simulador passa a agendar eventos com atraso em vez de resolver em zero, e o
# numero de eventos cresce porque cada glitch e um evento a mais.
#
# PRE-REQUISITO: zcu104/build.tcl ja rodado, com o impl_1 completo.
# -----------------------------------------------------------------------------
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
PRNG=$(cd "$HERE/.." && pwd)
CHAMADA=$(pwd)

MODO=funcsim
if [ "${1:-}" = "--timesim" ]; then
    MODO=timesim
    shift
elif [ "${1:-}" = "--funcsim" ]; then
    shift
fi

PADRAO="prng_postimpl.saif"
[ "$MODO" = "timesim" ] && PADRAO="prng_timesim.saif"

case "${1:-}" in
    /*) SAIF="${1}" ;;
    "") SAIF="$CHAMADA/$PADRAO" ;;
    *)  SAIF="$CHAMADA/${1}" ;;
esac
# O timesim e lento o bastante para a janela padrao ser menor. Nao ha perda de
# validade: o que se mede e taxa media de chaveamento, que estabiliza em poucas
# dezenas de iteracoes dos mapas.
if [ "$MODO" = "timesim" ]; then
    DUR=${2:-20us}
else
    DUR=${2:-50us}
fi

cd "$PRNG"

XPR=zcu104/vivado/takum_prng_zcu104.xpr
if [ ! -f "$XPR" ]; then
    echo "ERRO: $PRNG/$XPR nao existe." >&2
    echo "      Rode zcu104/create_project.tcl e zcu104/build.tcl antes." >&2
    exit 1
fi

if [ -z "${XILINX_VIVADO:-}" ]; then
    echo "ERRO: XILINX_VIVADO nao esta definido -- carregue o settings64.sh." >&2
    exit 1
fi
GLBL="$XILINX_VIVADO/data/verilog/src/glbl.v"

TRAB=$(mktemp -d "$PRNG/.postimpl.XXXXXX")
trap 'rm -rf "$TRAB"' EXIT

falhou() {
    echo "ERRO: $1" >&2
    [ -n "${2:-}" ] && grep -E 'ERROR|error' "$2" | head -20 >&2
    trap - EXIT
    [ -n "${2:-}" ] && echo "      log completo preservado em $2" >&2
    exit 1
}

echo "projeto : $PRNG"
echo "modo    : $MODO"
echo "saida   : $SAIF"
echo "duracao : $DUR de tempo simulado"
echo

# ---- 1. exportar o netlist implementado -------------------------------------
# -sdf_anno false de proposito: com true, o Vivado embute um $sdf_annotate no
# proprio netlist, que resolve o caminho do SDF em tempo de simulacao e falha
# em silencio se ele nao estiver onde se espera. Anotar explicitamente pelo
# xelab (-sdfmax) torna o vinculo visivel e verificavel.
{
    echo "open_project $PRNG/$XPR"
    echo "open_run impl_1"
    if [ "$MODO" = "timesim" ]; then
        echo "write_verilog -mode timesim -sdf_anno false -force $TRAB/netlist.v"
        echo "write_sdf -process_corner slow -force $TRAB/netlist.sdf"
    else
        echo "write_verilog -mode funcsim -force $TRAB/netlist.v"
    fi
} > "$TRAB/export.tcl"

echo "== exportando o netlist implementado ($MODO) =="
vivado -mode batch -notrace -nojournal -log "$TRAB/vivado.log" \
       -source "$TRAB/export.tcl" > /dev/null 2>&1 \
    || falhou "a exportacao do netlist falhou." "$TRAB/vivado.log"

[ -s "$TRAB/netlist.v" ] || falhou "o netlist nao foi gerado." "$TRAB/vivado.log"
echo "   netlist: $(du -h "$TRAB/netlist.v" | cut -f1)"

if [ "$MODO" = "timesim" ]; then
    [ -s "$TRAB/netlist.sdf" ] || falhou "o SDF nao foi gerado." "$TRAB/vivado.log"
    echo "   SDF    : $(du -h "$TRAB/netlist.sdf" | cut -f1)"
fi

# ---- 2. compilar netlist + glbl + banco -------------------------------------
echo
echo "== compilando =="
xvlog --nolog -work work "$TRAB/netlist.v" "$GLBL" > "$TRAB/xvlog1.log" 2>&1 \
    || falhou "a compilacao do netlist falhou." "$TRAB/xvlog1.log"
xvlog -sv --nolog -work work tb/tb_netlist_saif.sv > "$TRAB/xvlog2.log" 2>&1 \
    || falhou "a compilacao do banco falhou." "$TRAB/xvlog2.log"

# As bibliotecas mudam com o modo: o netlist funcional referencia as primitivas
# UNISIM, e o temporal referencia as SIMPRIM, que sao as mesmas celulas com
# blocos specify onde o SDF pendura os atrasos.
if [ "$MODO" = "timesim" ]; then
    LIBS="-L simprims_ver -L secureip"
    # Estas quatro opcoes sao o que faz o timesim valer a pena para potencia.
    #
    # Por padrao o simulador usa atraso INERCIAL: um pulso mais curto que o
    # atraso da porta e absorvido e nunca aparece na saida. Isso e o modelo
    # certo para verificar funcionalidade, e exatamente o errado para medir
    # energia -- justamente os glitches que queremos contar seriam descartados
    # antes de chegar ao SAIF.
    #
    #   -transport_int_delays  usa atraso de transporte na interconexao, que
    #                          propaga o pulso em vez de absorve-lo
    #   -pulse_r 0 / -pulse_int_r 0   limite de rejeicao em 0%: nenhum pulso e
    #                          descartado por ser estreito demais
    #   -pulse_e 0 / -pulse_int_e 0   idem para o limite de erro, senao pulsos
    #                          curtos viram X e poluem a contagem
    #
    # GLITCH_FILTER escolhe entre os dois extremos, e nenhum e "o certo":
    #
    #   inertial (padrao) -- cada porta absorve pulsos mais curtos que o
    #       proprio atraso, que e o que o silicio faz: uma porta real tem banda
    #       finita e nao propaga um pulso de 10 ps. Conta os glitches fisicos.
    #
    #   transport -- rejeicao zerada, todo pulso propaga por mais estreito que
    #       seja. Inclui glitches que a porta real filtraria, entao
    #       SUPERESTIMA. Serve como limite superior.
    if [ "${GLITCH_FILTER:-inertial}" = "transport" ]; then
        SDF_OPTS="-transport_int_delays -pulse_r 0 -pulse_int_r 0
                  -pulse_e 0 -pulse_int_e 0
                  -sdfmax /tb_netlist_saif/dut=$TRAB/netlist.sdf"
    else
        SDF_OPTS="-sdfmax /tb_netlist_saif/dut=$TRAB/netlist.sdf"
    fi
else
    LIBS="-L unisims_ver -L unimacro_ver -L secureip"
    SDF_OPTS=""
fi

# work.glbl precisa entrar explicitamente na elaboracao: e ele que pulsa o GSR
# no inicio, sem o qual os registradores do netlist nao assumem seus valores
# INIT e o design comeca em X.
#
# Sem -top, de proposito. Passar -top tb_netlist_saif junto do argumento
# posicional work.tb_netlist_saif declara o mesmo topo duas vezes, e o xelab
# responde com "top-level design unit was specified more than once" seguido de
# uma falha de elaboracao estatica sem causa aparente.
echo "== elaborando =="
xelab --nolog -timescale 1ps/1ps $LIBS $SDF_OPTS \
      -snapshot postimpl_snap -debug typical \
      work.tb_netlist_saif work.glbl > "$TRAB/xelab.log" 2>&1 \
    || falhou "a elaboracao falhou." "$TRAB/xelab.log"

if [ "$MODO" = "timesim" ]; then
    anotados=$(grep -cE 'SDF Annotat|annotated' "$TRAB/xelab.log" || true)
    echo "   SDF anotado (mensagens: $anotados)"
fi

# ---- 3. simular e registrar a atividade -------------------------------------
# Sem "run all": o banco nao tem $finish, de proposito. Se tivesse, ele
# encerraria o simulador antes do close_saif e o SAIF nunca seria escrito --
# sem erro nenhum, apenas sem arquivo no fim.
cat > "$TRAB/run.tcl" <<TCL
open_saif $SAIF
log_saif [get_objects -r /tb_netlist_saif/dut/*]
run $DUR
close_saif
quit
TCL

echo "== simulando o netlist ($MODO) =="
[ "$MODO" = "timesim" ] && echo "   (com atrasos e glitches; bem mais lento que funcsim)"
xsim postimpl_snap -tclbatch "$TRAB/run.tcl" --nolog

rm -rf xsim.dir *.pb *.wdb xsim_webtalk.tcl

[ -s "$SAIF" ] || falhou "a simulacao terminou mas $SAIF nao foi criado."

echo
echo "SAIF gravado em: $SAIF  ($(du -h "$SAIF" | cut -f1))"
echo "Use com:"
echo "  vivado -mode batch -notrace -source $PRNG/zcu104/report_ppa.tcl \\"
echo "         -tclargs $SAIF tb_netlist_saif/dut"
echo
echo "O segundo argumento e o -strip_path e MUDA em relacao ao SAIF"
echo "comportamental, porque este banco instancia o topo do design inteiro."
