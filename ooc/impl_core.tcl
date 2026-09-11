# -----------------------------------------------------------------------------
# Implementa o takum_prng_core (variante LOGARITMICA) out-of-context, para que
# ele possa ser comparado com o prng_core linear de ../../takum_prng_rtl.
#
#   cd takum_prng/ooc && vivado -mode batch -source impl_core.tcl
#   cd takum_prng/ooc && vivado -mode batch -source impl_core.tcl -tclargs 12.8
#
# POR QUE ESTE ARQUIVO EXISTE. Os numeros de area e potencia que vinham do
# projeto de placa (zcu104/) cobrem o topo inteiro: empacotador, AXI-Stream,
# LEDs, IBUFDS e BUFGCE_DIV. O lado linear e medido com o nucleo sozinho. Somar
# a infraestrutura de um lado so infla o logaritmico e a comparacao deixa de
# dizer o que se quer saber -- qual das duas aritmeticas custa mais para o mesmo
# gerador.
#
# ESPELHA ../../takum_prng_rtl/flow/impl.tcl PASSO A PASSO: mesmo
# -mode out_of_context, mesmos caminhos falsos nas portas de handshake, mesma
# sequencia opt -> place -> phys_opt -> route, mesmos relatorios, mesma forma de
# extrair o WNS. Qualquer divergencia entre os dois scripts vira diferenca
# medida entre as aritmeticas sem que nada avise -- e exatamente o risco que o
# comentario daquele fluxo descreve. Enquanto os dois forem copias separadas,
# uma mudanca aqui precisa ser repetida la.
#
# O ALVO E ESCOLHIDO LOGO ACIMA DO CAMINHO CRITICO, pela mesma razao explicada
# em ../../takum_prng_rtl/zcu104/placa.tcl: um alvo folgado faz as ferramentas
# pararem de otimizar, o caminho roteado piora, e o WNS passa a descrever o
# quanto se pediu de menos em vez de descrever o design.
# -----------------------------------------------------------------------------

set here [file normalize [file dirname [info script]]]
set prng [file normalize $here/..]
set lns  [file normalize $here/../../arch_takum/rtl/lns]

set PLACA "ZCU104"
set PART  xczu7ev-ffvc1156-2-e

# 13,0 ns e o ponto de partida: o topo completo fecha a 13,332 ns com WNS de
# +0,391 ns, ou seja um caminho critico de 12,94 ns. Sem o wrapper o nucleo
# tende a ser igual ou um pouco melhor.
set PERIODO_NS 13.000
if {[llength $argv] > 0} { set PERIODO_NS [lindex $argv 0] }

# Variante: "base" (takum_prng_core) ou "fundido" (takum_prng_core_fused). As
# duas passam pelo MESMO corpo de fluxo de proposito -- se cada uma tivesse o
# seu, a comparacao entre elas mediria a diferenca entre os scripts.
set VARIANTE "base"
if {[llength $argv] > 1} { set VARIANTE [lindex $argv 1] }

if {$VARIANTE eq "pipe"} {
    set TOPO  takum_prng_core_pipe
    set CICLOS 1.0
} elseif {$VARIANTE eq "multi"} {
    set TOPO  takum_prng_core_multi
    set CICLOS 13.0
} elseif {$VARIANTE eq "fundido"} {
    set TOPO  takum_prng_core_fused
    set CICLOS 23.0
} else {
    set TOPO  takum_prng_core
    set CICLOS 44.0
}

set out     $here/impl/$VARIANTE
set reports $here/reports/$VARIANTE
file mkdir $out
file mkdir $reports

puts "== implementando $TOPO out-of-context =="
puts "   placa   : $PLACA"
puts "   parte   : $PART"
puts "   variante: $VARIANTE ($CICLOS ciclos por iteracao)"
puts [format "   alvo    : %.3f ns (%.2f MHz)" $PERIODO_NS [expr {1000.0/$PERIODO_NS}]]

# ---- fontes ------------------------------------------------------------------
# O empacotador e o wrapper AXI-Stream ficam DE FORA de proposito: sao a
# infraestrutura de saida, nao o gerador.
read_verilog -sv [list \
    $lns/takum_log_pkg.sv \
    $prng/rtl/takum_prng_pkg.sv \
    $lns/takum_log_decoder.sv \
    $lns/takum_log_encoder.sv \
    $lns/takum_log_gausslog_unit.sv \
    $lns/takum_log_negator.sv \
    $lns/takum_log_adder.sv \
    $lns/takum_log_subtractor.sv \
    $lns/takum_log_multiplier.sv \
    $lns/takum_log_divider.sv \
    $lns/takum_log_alu.sv \
    $lns/takum_log_internal_pkg.sv \
    $lns/takum_log_internal_ops.sv \
    $lns/takum_log_alu_fused.sv \
    $prng/rtl/takum_prng_perturb.sv \
    $prng/rtl/takum_prng_core.sv \
    $prng/rtl/takum_prng_core_fused.sv \
    $prng/rtl/takum_prng_core_multi.sv \
    $prng/rtl/takum_prng_core_pipe.sv ]

# LUT_DIR precisa ser absoluto: o $readmemh das ROMs resolve o caminho a partir
# do diretorio onde o Vivado esta rodando, nao de onde o RTL mora.
synth_design -top $TOPO -part $PART -mode out_of_context \
             -generic LUT_DIR=$lns/lut/

# ---- restricoes --------------------------------------------------------------
create_clock -period $PERIODO_NS -name clk [get_ports clk_i]

# Identicas as do fluxo linear: as portas de handshake ligariam a um consumidor
# cujo atraso nao e propriedade do gerador, entao o timing reportado fala so dos
# caminhos registrador-a-registrador do datapath.
set_false_path -from [get_ports {rst_i ready_i}]
set_false_path -to   [get_ports {valid_o nbits_o[*] data_o[*]}]

# ---- implementacao -----------------------------------------------------------
opt_design
place_design
phys_opt_design
route_design

# ---- artefatos ---------------------------------------------------------------
write_checkpoint -force $out/${TOPO}_routed.dcp
write_verilog -mode funcsim -force $out/${TOPO}_funcsim.v

report_utilization       -file $reports/utilization.rpt
report_timing_summary    -file $reports/timing_summary.rpt
report_timing -delay_type max -max_paths 10 -file $reports/timing_paths.rpt
report_clock_utilization -file $reports/clocks.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set periodo_real [expr {$PERIODO_NS - $wns}]
set fmax [expr {1000.0/$periodo_real}]

# CICLOS por iteracao (44 / 23 / 13 / 1 conforme a variante) e 25,87 bits por
# iteracao, media medida sobre 200 mil iteracoes do modelo.
set mbps [expr {($fmax * 25.87) / $CICLOS}]

set lut   [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ LUT*}]]
set ff    [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD*}]]
set r36   [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB36*}]]
set r18   [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB18*}]]
set dsp   [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ DSP48*}]]

puts ""
puts "===== NUCLEO LOGARITMICO ($VARIANTE), OUT-OF-CONTEXT ====="
puts [format "  alvo               : %.3f ns (%.2f MHz)" $PERIODO_NS [expr {1000.0/$PERIODO_NS}]]
puts [format "  WNS                : %+.3f ns" $wns]
puts [format "  caminho critico    : %.3f ns  -> Fmax %.2f MHz" $periodo_real $fmax]
puts [format "  vazao no Fmax      : %.2f Mbit/s  (%.0f ciclos/iteracao)" $mbps $CICLOS]
puts ""
puts [format "  LUT                : %d" $lut]
puts [format "  FF                 : %d" $ff]
puts [format "  BRAM (RAMB36/18)   : %d / %d" $r36 $r18]
puts [format "  DSP48              : %d" $dsp]
if {$r36 == 0 && $r18 == 0} {
    puts "  ATENCAO: nenhuma BRAM inferida -- as ROMs Gauss-log viraram LUT."
    puts "  Provavel falha do LUT_DIR; confira os avisos de \$readmemh acima."
}
if {$wns < 0} {
    puts "  ATENCAO: o alvo NAO foi cumprido; reexecute com um alvo maior."
}
puts ""
puts "  checkpoint         : $out/${TOPO}_routed.dcp"
puts "  netlist (funcsim)  : $out/${TOPO}_funcsim.v"
puts "  relatorios         : $reports/"
puts "============================================================"
