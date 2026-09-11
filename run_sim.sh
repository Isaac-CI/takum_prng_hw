#!/bin/bash
# Simula o PRNG contra os vetores do modelo Python.
#   ./run_sim.sh
set -e
LNS=../arch_takum/rtl/lns
rm -rf xsim.dir *.log *.jou *.pb *.wdb *.str xsim_webtalk.tcl
xvlog -sv $LNS/takum_log_pkg.sv rtl/takum_prng_pkg.sv \
      $LNS/takum_log_decoder.sv $LNS/takum_log_encoder.sv \
      $LNS/takum_log_gausslog_unit.sv $LNS/takum_log_negator.sv \
      $LNS/takum_log_adder.sv $LNS/takum_log_subtractor.sv \
      $LNS/takum_log_multiplier.sv $LNS/takum_log_divider.sv $LNS/takum_log_alu.sv \
      rtl/takum_prng_perturb.sv rtl/takum_prng_core.sv \
      rtl/takum_prng_packer.sv rtl/takum_prng_axis.sv \
      tb/tb_takum_prng.sv tb/tb_takum_prng_axis.sv

echo "== nucleo contra o modelo =="
xelab -timescale 1ns/1ps -top tb_takum_prng -snapshot prng_snap
xsim prng_snap -R

echo
echo "== saida AXI-Stream, com back-pressure =="
xelab -timescale 1ns/1ps -top tb_takum_prng_axis -snapshot axis_snap
xsim axis_snap -R
rm -rf xsim.dir *.log *.jou *.pb *.wdb *.str xsim_webtalk.tcl
