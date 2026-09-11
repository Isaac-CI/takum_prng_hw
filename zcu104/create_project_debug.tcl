# -----------------------------------------------------------------------------
# Cria o projeto Vivado do PRNG takum na ZCU104 *instrumentado* -- com ILA e
# VIO -- para verificar o design remotamente.
#
#   cd zcu104 && vivado -mode batch -source create_project_debug.tcl
#
# Fica num diretorio e num projeto separados do topo limpo (vivado_debug/ em
# vez de vivado/), entao os dois convivem: use o limpo para numeros de area e
# timing, o de debug para conferir o comportamento no silicio.
#
# Como no projeto limpo, nenhum RTL e copiado -- ../rtl e ../../arch_takum/rtl/
# lns seguem sendo a unica fonte da verdade -- e o caminho absoluto das ROMs
# chega ao topo pelo parametro LUT_DIR.
# -----------------------------------------------------------------------------

set here    [file normalize [file dirname [info script]]]
set prng    [file normalize $here/../rtl]
set arch    [file normalize $here/../../arch_takum]
set lns     $arch/rtl/lns
set projdir $here/vivado_debug
set projname takum_prng_zcu104_debug

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
    $prng/takum_prng_packer.sv \
    $prng/takum_prng_axis.sv \
    $here/rtl/zcu104_takum_prng_debug_top.sv ]

set_property file_type SystemVerilog [get_files *.sv]

add_files -norecurse [glob $lns/lut/*.mem]
set_property file_type {Memory Initialization Files} [get_files *.mem]

# O topo de debug tem exatamente as mesmas portas do topo limpo, entao o mesmo
# XDC serve para os dois -- nao ha um segundo arquivo de constraints para sair
# de sincronia.
add_files -fileset constrs_1 -norecurse $here/constraints/zcu104_takum_prng.xdc

set_property top zcu104_takum_prng_debug_top [current_fileset]
set_property generic [list LUT_DIR=$lns/lut/] [current_fileset]

# ---- ILA --------------------------------------------------------------------
# Quatro sondas: dados, valid, indice absoluto do beat e o pulso de trigger.
#
# C_EN_STRG_QUAL habilita a qualificacao de armazenamento. Sem ela, as 4096
# amostras cobririam so ~69 beats, porque um beat sai a cada ~59 ciclos; com
# ela voce configura na GUI a condicao de captura ila_tvalid == 1 e cada
# amostra guardada passa a ser um beat, rendendo 4096 beats por janela.
#
# A versao do IP nao e fixada de proposito: assim o script funciona tanto no
# 2024.2 do servidor quanto no 2026.1 daqui.
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES     {4}    \
    CONFIG.C_PROBE0_WIDTH      {32}   \
    CONFIG.C_PROBE1_WIDTH      {1}    \
    CONFIG.C_PROBE2_WIDTH      {32}   \
    CONFIG.C_PROBE3_WIDTH      {1}    \
    CONFIG.C_DATA_DEPTH        {4096} \
    CONFIG.C_EN_STRG_QUAL      {1}    \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2}  \
    CONFIG.C_ADV_TRIGGER       {false} \
    CONFIG.C_INPUT_PIPE_STAGES {0}    \
] [get_ips ila_0]

# ---- VIO --------------------------------------------------------------------
# Entradas (leitura ao vivo, sem precisar de trigger):
#   probe_in0  beat_cnt   -- subindo = o PRNG esta produzindo
#   probe_in1  sig        -- assinatura acumulada
#   probe_in2  tvalid
#   probe_in3  heartbeat  -- oscila com o clock, independente do PRNG
# Saidas:
#   probe_out0 rst        -- nivel; 1 segura o PRNG, 0 solta do beat 0
#   probe_out1 trig_beat  -- em que beat disparar (0 = primeira palavra)
#   probe_out2 ready_en   -- 1 por padrao; 0 exercita back-pressure
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN        {4}  \
    CONFIG.C_NUM_PROBE_OUT       {3}  \
    CONFIG.C_PROBE_IN0_WIDTH     {32} \
    CONFIG.C_PROBE_IN1_WIDTH     {32} \
    CONFIG.C_PROBE_IN2_WIDTH     {1}  \
    CONFIG.C_PROBE_IN3_WIDTH     {1}  \
    CONFIG.C_PROBE_OUT0_WIDTH    {1}  \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT1_WIDTH    {32} \
    CONFIG.C_PROBE_OUT1_INIT_VAL {0x00000000} \
    CONFIG.C_PROBE_OUT2_WIDTH    {1}  \
    CONFIG.C_PROBE_OUT2_INIT_VAL {0x1} \
] [get_ips vio_0]

# Sintese global em vez de out-of-context: sao dois cores pequenos, e assim
# nao ha runs de IP separados para gerenciar, esperar ou falhar.
foreach ip [get_ips] {
    set_property generate_synth_checkpoint false [get_files [get_property IP_FILE $ip]]
}
generate_target {instantiation_template synthesis} [get_ips]

update_compile_order -fileset sources_1

puts "PROJETO DE DEBUG CRIADO: $projdir/$projname.xpr"
puts "  parte   : [get_property PART [current_project]]"
puts "  topo    : [get_property top [current_fileset]]"
puts "  LUT_DIR : $lns/lut/"
puts "  cores   : [join [get_ips] {, }]"
