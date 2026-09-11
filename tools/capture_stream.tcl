# -----------------------------------------------------------------------------
# Extrai uma sequencia longa de bits do PRNG rodando na ZCU104, para alimentar
# a bateria NIST.
#
#   vivado -mode batch -source capture_stream.tcl -tclargs <janelas> [saida]
#
# Cada janela do ILA rende 4096 beats de 32 bits = 131072 bits, entao:
#
#     janelas |      bits | sequencias NIST de 1 Mbit
#     --------+-----------+--------------------------
#          8  |  1.048.576|   1
#         77  | 10.092.544|  10
#        763  |100.007.936| 100  (a bateria completa)
#
# COMO A CONTIGUIDADE E MANTIDA. O ILA guarda 4096 beats por vez, e entre uma
# captura e a proxima o upload por JTAG leva ~1 s -- tempo em que o PRNG, se
# deixado correndo, emitiria mais de um milhao de beats e abriria um buraco na
# sequencia. A saida e usar o determinismo do design: antes de cada janela o
# VIO afirma o reset, o que devolve o PRNG ao beat 0, e o trigger e armado no
# beat k*4096. Como a sequencia e sempre a mesma a partir das sementes fixas,
# as janelas se emendam exatamente, e o resultado e um fluxo continuo de
# verdade -- nao uma colagem de trechos avulsos.
#
# O preco disso e que a janela k exige esperar k*4096 beats, entao o tempo
# total de extracao cresce com o quadrado do numero de janelas. Para as 763
# janelas da bateria completa sao ~16 min de espera mais o tempo de upload.
# Isso e custo do caminho de depuracao por JTAG, e NAO deve ser confundido com
# o tempo que o design leva para gerar os bits: veja o resumo no fim.
# -----------------------------------------------------------------------------

set here [file normalize [file dirname [info script]]]
set proj [file normalize $here/../zcu104]
set impl $proj/vivado_debug/takum_prng_zcu104_debug.runs/impl_1

set janelas [expr {[llength $argv] > 0 ? [lindex $argv 0] : 8}]
set saida   [expr {[llength $argv] > 1 ? [lindex $argv 1] : "$here/captura"}]

set bit $impl/zcu104_takum_prng_debug_top.bit
set ltx $impl/zcu104_takum_prng_debug_top.ltx

foreach f [list $bit $ltx] {
    if {![file exists $f]} {
        puts "ERRO: nao encontrei $f -- rode build_debug.tcl antes."
        exit 1
    }
}
file mkdir $saida

set PROFUNDIDADE 4096
set BEATS_JANELA $PROFUNDIDADE

# ---- conectar e programar ---------------------------------------------------
open_hw_manager
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices xczu7*] 0]
refresh_hw_device -update_hw_probes false [current_hw_device]

set_property PROGRAM.FILE $bit [current_hw_device]
set_property PROBES.FILE  $ltx [current_hw_device]
set_property FULL_PROBES.FILE $ltx [current_hw_device]
program_hw_devices [current_hw_device]
refresh_hw_device [current_hw_device]

set ila [lindex [get_hw_ilas -of_objects [current_hw_device]] 0]
set vio [lindex [get_hw_vios -of_objects [current_hw_device]] 0]

if {$ila eq "" || $vio eq ""} {
    puts "ERRO: ILA ou VIO nao encontrados. O .ltx foi carregado junto do .bit?"
    exit 1
}

set p_rst  [lindex [get_hw_probes -of_objects $vio *vio_rst*] 0]
set p_trig [lindex [get_hw_probes -of_objects $vio *trig_beat*] 0]
set p_bcnt [lindex [get_hw_probes -of_objects $vio *beat_cnt*] 0]

set_property OUTPUT_VALUE_RADIX UNSIGNED $p_trig

# ---- configurar o ILA -------------------------------------------------------
# TRIGGER_POSITION 0: a janela comeca no proprio trigger, entao o primeiro
# beat capturado e exatamente o beat pedido.
set_property CONTROL.TRIGGER_POSITION 0 $ila
set_property CONTROL.DATA_DEPTH $PROFUNDIDADE $ila

# Qualificacao de armazenamento: guardar so os ciclos com ila_tvalid alto. Sem
# isso a janela pegaria ~69 beats em vez de 4096, porque um beat sai a cada
# ~59 ciclos e o resto seria ociosidade.
set_property CONTROL.CAPTURE_MODE BASIC $ila
set cap [lindex [get_hw_probes -of_objects $ila *ila_tvalid*] 0]
set_property CAPTURE_COMPARE_VALUE eq1'b1 $cap

set trg [lindex [get_hw_probes -of_objects $ila *ila_trig*] 0]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trg

# ---- laco de captura --------------------------------------------------------
set t0 [clock milliseconds]

for {set k 0} {$k < $janelas} {incr k} {
    set beat0 [expr {$k * $BEATS_JANELA}]

    # 1. segurar o PRNG em reset
    set_property OUTPUT_VALUE 1 $p_rst
    commit_hw_vio $p_rst

    # 2. dizer onde disparar
    set_property OUTPUT_VALUE $beat0 $p_trig
    commit_hw_vio $p_trig

    # 3. armar o ILA com o design ainda parado
    run_hw_ila $ila

    # 4. soltar: a sequencia recomeca do beat 0 e corre ate o trigger
    set_property OUTPUT_VALUE 0 $p_rst
    commit_hw_vio $p_rst

    # 5. esperar. O timeout e generoso porque a janela k precisa de
    #    k*4096*59 ciclos a 75 MHz antes de o trigger acontecer.
    wait_on_hw_ila -timeout 30 $ila
    upload_hw_ila_data $ila

    set csv [format "%s/janela_%05d.csv" $saida $k]
    write_hw_ila_data -csv_file -force $csv hw_ila_data_1

    if {$k % 10 == 0 || $k == $janelas - 1} {
        set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
        puts [format "  janela %d/%d  beat %d  (%.1f s)" \
              [expr {$k + 1}] $janelas $beat0 $dt]
    }
}

set extracao [expr {([clock milliseconds] - $t0) / 1000.0}]

# ---- resumo ------------------------------------------------------------------
# Duas grandezas distintas, e confundi-las seria reportar errado o desempenho
# do design:
#
#   geracao  -- quanto o PRNG leva, no FPGA, para produzir esses bits. E uma
#               propriedade do design: 0,5395 bits por ciclo a 75 MHz.
#   extracao -- quanto levou para tirar os bits pelo JTAG com o ILA. E custo do
#               instrumento, nao do gerador, e domina por ordens de grandeza.
set bits    [expr {$janelas * $BEATS_JANELA * 32}]
set ciclos  [expr {$janelas * $BEATS_JANELA * 59.0}]
set geracao [expr {$ciclos / 75.0e6}]

puts ""
puts "==================== EXTRACAO ===================="
puts [format "  janelas            : %d" $janelas]
puts [format "  bits               : %d" $bits]
puts [format "  CSVs em            : %s" $saida]
puts ""
puts [format "  tempo de GERACAO   : %.3f s  (o design produzindo os bits)" $geracao]
puts [format "  tempo de EXTRACAO  : %.1f s  (JTAG + ILA, custo do instrumento)" $extracao]
puts [format "  razao              : %.0fx" [expr {$extracao / $geracao}]]
puts ""
puts "  O numero que descreve o PRNG e o de GERACAO. O de extracao mede o"
puts "  cabo JTAG; para tirar bits em volume de verdade o caminho e AXI DMA"
puts "  pelo PS, nao o ILA."
puts "================================================="

close_hw_manager
