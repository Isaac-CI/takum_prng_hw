#!/bin/bash
# Simula takum_prng_core_pipe contra os vetores de model/takum_prng_pipe_model.py.
#
#   ./run_sim_pipe.sh
#
# Roda a partir de qualquer diretorio -- os caminhos sao resolvidos a partir do
# lugar do script, nao do cwd de quem chama.
set -e
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$AQUI"

LNS=../arch_takum/rtl/lns
rm -rf xsim.dir *.log *.jou *.pb *.wdb *.str xsim_webtalk.tcl

xvlog -sv \
      $LNS/takum_log_pkg.sv $LNS/takum_log_internal_pkg.sv rtl/takum_prng_pkg.sv \
      $LNS/takum_log_decoder.sv $LNS/takum_log_encoder.sv \
      $LNS/takum_log_gausslog_unit.sv $LNS/takum_log_internal_ops.sv \
      rtl/takum_prng_perturb.sv rtl/takum_prng_core_pipe.sv \
      rtl/takum_prng_packer.sv

# -timescale explicito: o banco declara `timescale e o RTL nao, o que o xelab
# do Vivado 2024.2 rejeita ([XSIM 43-4100]) embora o 2026.1 tolere.
xelab -timescale 1ns/1ps -top tb_takum_prng_pipe -snapshot pipe_snap \
      -log xelab_pipe.log
xsim pipe_snap -R

rm -rf xsim.dir *.pb *.wdb *.str xsim_webtalk.tcl
