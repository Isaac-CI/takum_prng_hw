# -----------------------------------------------------------------------------
# Roda sintese, implementacao e bitstream, e grava os relatorios em reports/.
#
#   vivado -mode batch -source build.tcl
#
# Espera que create_project.tcl ja tenha rodado.
# -----------------------------------------------------------------------------

set here    [file normalize [file dirname [info script]]]
set projdir $here/vivado
set xpr     $projdir/takum_prng_zcu104.xpr
set reports $here/reports

if {![file exists $xpr]} {
    puts "ERRO: $xpr nao existe -- rode create_project.tcl antes."
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

# ---- relatorios -------------------------------------------------------------
open_run impl_1
report_utilization       -file $reports/utilization.rpt
report_timing_summary    -file $reports/timing_summary.rpt
report_timing -delay_type max -max_paths 10 -file $reports/timing_paths.rpt
report_power             -file $reports/power.rpt
report_clock_utilization -file $reports/clocks.rpt

# ---- resumo na tela ---------------------------------------------------------
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
set clk [get_clocks -quiet -of_objects [get_pins -quiet u_clkdiv/O]]
set per [expr {[llength $clk] ? [get_property PERIOD [lindex $clk 0]] : 0}]

puts "==================== RESUMO ===================="
puts "  WNS (setup)        : $wns ns"
puts "  WHS (hold)         : $whs ns"
if {$per > 0} {
    puts "  periodo do clock   : $per ns ([format %.1f [expr {1000.0/$per}]] MHz)"
    puts "  Fmax alcancavel    : [format %.1f [expr {1000.0/($per - $wns)}]] MHz"
}
puts "  LUT                : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ LUT*}]]"
puts "  FF                 : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD*}]]"
puts "  BRAM (RAMB36)      : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB36*}]]"
puts "  BRAM (RAMB18)      : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB18*}]]"
puts "  DSP                : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ DSP48*}]]"
puts "  bitstream          : $projdir/takum_prng_zcu104.runs/impl_1/zcu104_takum_prng_top.bit"
puts "  relatorios         : $reports/"
puts "==============================================="
