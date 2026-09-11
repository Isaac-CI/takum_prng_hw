# -----------------------------------------------------------------------------
# Roda sintese, implementacao e bitstream do projeto instrumentado.
#
#   vivado -mode batch -source build_debug.tcl
#
# Espera que create_project_debug.tcl ja tenha rodado.
#
# Produz dois arquivos, e voce precisa dos DOIS: o .bit configura o FPGA, e o
# .ltx e o que ensina o Hardware Manager a nomear as sondas do ILA e do VIO.
# Sem o .ltx a GUI mostra os cores como probe0, probe1... sem largura nem
# significado, e o CSV exportado sai inutil para o script de conferencia.
# -----------------------------------------------------------------------------

set here    [file normalize [file dirname [info script]]]
set projdir $here/vivado_debug
set xpr     $projdir/takum_prng_zcu104_debug.xpr
set reports $here/reports_debug

if {![file exists $xpr]} {
    puts "ERRO: $xpr nao existe -- rode create_project_debug.tcl antes."
    exit 1
}

open_project $xpr
file mkdir $reports

# ---- sintese ----------------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERRO: sintese falhou"
    exit 1
}

# ---- implementacao + bitstream ----------------------------------------------
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERRO: implementacao falhou"
    exit 1
}

# ---- relatorios e sondas -----------------------------------------------------
open_run impl_1
report_utilization    -file $reports/utilization.rpt
report_timing_summary -file $reports/timing_summary.rpt

set impl $projdir/takum_prng_zcu104_debug.runs/impl_1
set bit  $impl/zcu104_takum_prng_debug_top.bit
set ltx  $impl/zcu104_takum_prng_debug_top.ltx

# write_bitstream normalmente ja grava o .ltx, mas escrever explicitamente
# custa nada e evita descobrir a ausencia dele so na frente da placa.
if {![file exists $ltx]} {
    write_debug_probes -force $ltx
}

# ---- resumo ------------------------------------------------------------------
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]

puts "================ RESUMO (DEBUG) ================"
puts "  WNS (setup)   : $wns ns"
puts "  WHS (hold)    : $whs ns"
puts "  LUT           : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ LUT*}]]"
puts "  FF            : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD*}]]"
puts "  BRAM (RAMB36) : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB36*}]]"
puts "  BRAM (RAMB18) : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB18*}]]"
puts "  DSP           : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ DSP48*}]]"
puts ""
puts "  ATENCAO: estes numeros incluem o ILA e o VIO, que nao fazem parte do"
puts "           design. Os numeros que valem para a dissertacao sao os do"
puts "           projeto limpo (build.tcl): 53 BRAM, 17 DSP, ~4700 LUT."
puts ""
puts "  bitstream : $bit"
puts "  sondas    : $ltx"
puts "==============================================="
