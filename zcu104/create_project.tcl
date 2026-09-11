# -----------------------------------------------------------------------------
# Cria o projeto Vivado do PRNG takum na ZCU104, do zero.
#
#   cd zcu104 && vivado -mode batch -source create_project.tcl
#
# Nenhum RTL e copiado: o projeto aponta para ../rtl (o PRNG) e para
# ../../arch_takum/rtl/lns (a ALU), que seguem sendo a unica fonte da verdade.
# As ROMs (.mem) ficam onde estao e o caminho absoluto delas chega ao topo
# pelo parametro LUT_DIR -- a sintese de um projeto Vivado roda em
# <proj>.runs/synth_1/, onde o default relativo do RTL nao resolveria.
# -----------------------------------------------------------------------------

set here    [file normalize [file dirname [info script]]]
set prng    [file normalize $here/../rtl]
set arch    [file normalize $here/../../arch_takum]
set lns     $arch/rtl/lns
set projdir $here/vivado
set projname takum_prng_zcu104

# Variante do gerador: "base", "fundido", "multi" ou "pipe" -- ver o cabecalho
# de rtl/takum_prng_axis.sv. Passa por -tclargs e chega ao topo como generic,
# entao o mesmo projeto serve as quatro:
#
#   vivado -mode batch -source create_project.tcl -tclargs pipe
#
# O nome do projeto NAO muda com a variante de proposito: cada criacao apaga a
# anterior. Comparar duas variantes quer dois diretorios, nao dois estados do
# mesmo -- e misturar relatorios de variantes diferentes no mesmo lugar e
# exatamente como um numero de PPA vai parar na dissertacao com o rotulo errado.
set VARIANTE "base"
if {[llength $argv] > 0} { set VARIANTE [lindex $argv 0] }
puts "== variante do gerador: $VARIANTE =="

foreach d [list $prng $lns] {
    if {![file isdirectory $d]} {
        puts "ERRO: nao encontrei $d"
        exit 1
    }
}

file delete -force $projdir
create_project $projname $projdir -part xczu7ev-ffvc1156-2-e
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]

# ---- fontes -----------------------------------------------------------------
add_files -norecurse [list \
    $lns/takum_log_pkg.sv \
    $prng/takum_prng_pkg.sv \
    $lns/takum_log_decoder.sv \
    $lns/takum_log_encoder.sv \
    $lns/takum_log_gausslog_unit.sv \
    $lns/takum_log_negator.sv \
    $lns/takum_log_adder.sv \
    $lns/takum_log_subtractor.sv \
    $lns/takum_log_multiplier.sv \
    $lns/takum_log_divider.sv \
    $lns/takum_log_alu.sv \
    $prng/takum_prng_perturb.sv \
    $prng/takum_prng_core.sv \
    $lns/takum_log_internal_pkg.sv \
    $lns/takum_log_internal_ops.sv \
    $lns/takum_log_alu_fused.sv \
    $prng/takum_prng_core_fused.sv \
    $prng/takum_prng_core_multi.sv \
    $prng/takum_prng_core_pipe.sv \
    $prng/takum_prng_packer.sv \
    $prng/takum_prng_axis.sv \
    $here/rtl/zcu104_takum_prng_top.sv ]

set_property file_type SystemVerilog [get_files *.sv]

add_files -norecurse [glob $lns/lut/*.mem]
set_property file_type {Memory Initialization Files} [get_files *.mem]

add_files -fileset constrs_1 -norecurse $here/constraints/zcu104_takum_prng.xdc

set_property top zcu104_takum_prng_top [current_fileset]
set_property generic [list LUT_DIR=$lns/lut/ VARIANTE=$VARIANTE] [current_fileset]

update_compile_order -fileset sources_1

puts "PROJETO CRIADO: $projdir/$projname.xpr"
puts "  parte   : [get_property PART [current_project]]"
puts "  placa   : [get_property board_part [current_project]]"
puts "  topo    : [get_property top [current_fileset]]"
puts "  LUT_DIR : $lns/lut/"
