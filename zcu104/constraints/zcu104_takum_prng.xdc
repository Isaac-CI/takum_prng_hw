# -----------------------------------------------------------------------------
# ZCU104 (xczu7ev-ffvc1156-2-e) -- pinagem e clock para zcu104_takum_prng_top
#
# Todas as localizacoes e padroes de I/O saem do board file oficial
# xilinx.com:zcu104:part0:1.1 (part0_pins.xml), nao de suposicao.
# -----------------------------------------------------------------------------

# ---- clock de usuario: 300 MHz diferencial ----------------------------------
set_property -dict {PACKAGE_PIN AH18 IOSTANDARD DIFF_SSTL12} [get_ports clk_300_p_i]
set_property -dict {PACKAGE_PIN AH17 IOSTANDARD DIFF_SSTL12} [get_ports clk_300_n_i]

create_clock -period 3.333 -name clk_300 [get_ports clk_300_p_i]

# O clock de 100 MHz que alimenta a ALU vem de um BUFGCE_DIV com divisao por
# 3. Vivado deriva esse clock sozinho a partir da primitiva -- nao ha
# create_generated_clock aqui de proposito, porque declara-lo a mao correria o
# risco de divergir da divisao real configurada no RTL.

# ---- LEDs de usuario --------------------------------------------------------
set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33} [get_ports {led_o[0]}]
set_property -dict {PACKAGE_PIN D6 IOSTANDARD LVCMOS33} [get_ports {led_o[1]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {led_o[2]}]
set_property -dict {PACKAGE_PIN B5 IOSTANDARD LVCMOS33} [get_ports {led_o[3]}]

# Os LEDs so mudam a cada ~0,67 s e nao tem relacao de temporizacao com nada
# fora do FPGA, entao nao vale gastar esforco de roteamento neles.
set_false_path -to [get_ports {led_o[*]}]
