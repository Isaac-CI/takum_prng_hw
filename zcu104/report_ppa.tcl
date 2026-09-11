# -----------------------------------------------------------------------------
# Relatorio consolidado de PPA (Power, Performance, Area) do PRNG.
#
#   vivado -mode batch -source report_ppa.tcl
#
# Le o PROJETO LIMPO (vivado/), nao o de debug. Isso e deliberado: o ILA e o
# VIO consomem BRAM, LUT e FF que nao fazem parte do gerador, e reportar area
# com eles dentro inflaria os numeros sem que nada disso va para um sistema
# final. O projeto de debug serve para provar que o design funciona; este e o
# que descreve quanto ele custa.
#
# Sobre a potencia: sem um SAIF de simulacao o Vivado estima a atividade de
# chaveamento por heuristica ("vectorless"), o que e uma aproximacao grosseira.
# Se voce quiser um numero defensavel, gere um SAIF a partir de uma simulacao
# pos-sintese e passe o caminho:
#
#   vivado -mode batch -source report_ppa.tcl -tclargs /caminho/prng.saif
# -----------------------------------------------------------------------------

set here    [file normalize [file dirname [info script]]]
set projdir $here/vivado
set xpr     $projdir/takum_prng_zcu104.xpr
set saif    [expr {[llength $argv] > 0 ? [lindex $argv 0] : ""}]

# O prefixo a remover dos caminhos do SAIF depende de qual banco o gerou:
#   tools/gen_saif.sh          -> tb_takum_prng_rate      (instancia takum_prng_axis)
#   tools/gen_saif_postimpl.sh -> tb_netlist_saif/dut     (instancia o topo inteiro)
# O padrao serve ao primeiro, que e o caminho rapido; cada script imprime o
# comando com o valor certo ao terminar.
set strip   [expr {[llength $argv] > 1 ? [lindex $argv 1] : "tb_takum_prng_rate"}]

if {![file exists $xpr]} {
    puts "ERRO: $xpr nao existe -- rode create_project.tcl e build.tcl antes."
    exit 1
}

open_project $xpr
open_run impl_1

# ---- Performance -------------------------------------------------------------
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]

set clk [get_clocks -quiet -of_objects [get_pins -quiet u_clkdiv/O]]
set per [expr {[llength $clk] ? [get_property PERIOD [lindex $clk 0]] : 0}]
if {$per <= 0} {
    puts "AVISO: nao achei o clock em u_clkdiv/O; assumindo 13.333 ns."
    set per 13.333
}
set fop  [expr {1000.0 / $per}]
set fmax [expr {1000.0 / ($per - $wns)}]

# Vazao. Sao dois numeros medidos, nao estimados: 48 ciclos por iteracao
# (constante, medido na simulacao do nucleo) e 25,87 bits por iteracao (media
# sobre 200 mil iteracoes do modelo -- varia de 20 a 27 conforme o regime dos
# dois takums de cada passo).
set ciclos_it 48.0
set bits_it   25.87
set bpc       [expr {$bits_it / $ciclos_it}]
set mbps      [expr {$bpc * $fop}]
set mbps_max  [expr {$bpc * $fmax}]

# ---- Area --------------------------------------------------------------------
set lut    [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ LUT*}]]
set ff     [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD*}]]
set ram36  [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB36*}]]
set ram18  [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB18*}]]
set dsp    [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ DSP48*}]]

# ---- Power -------------------------------------------------------------------
set reports $here/reports
file mkdir $reports

# -strip_path tira o prefixo do testbench dos caminhos do SAIF. Os nomes
# gravados sao tb_takum_prng_rate/u_prng/..., e o design implementado tem
# u_prng/... sob o topo -- entao remover "tb_takum_prng_rate" faz os dois
# coincidirem. Se os caminhos nao casassem, o Vivado NAO reclamaria: deixaria
# os nos sem anotacao e voltaria a heuristica, produzindo um numero quase
# identico ao vectorless. Por isso o nivel de confianca e impresso adiante --
# e ele que denuncia uma anotacao que nao pegou.
if {$saif ne "" && [file exists $saif]} {
    read_saif -strip_path $strip $saif
    set fonte "SAIF ([file tail $saif], strip=$strip)"
} else {
    set fonte "estimativa vectorless (sem SAIF)"
}
report_power -file $reports/power_ppa.rpt

# O total sai do texto do relatorio em vez de STATS.TOTAL_POWER porque essa
# propriedade so e preenchida quando a potencia roda como etapa do run, e vem
# vazia quando report_power e chamado a mao como aqui.
report_power -hierarchical_depth 3 -file $reports/power_hier.rpt

set p_tot 0
set p_din 0
set p_est 0
set texto [report_power -return_string]
regexp {Total On-Chip Power \(W\)[^0-9]*([0-9]+\.[0-9]+)}  $texto -> p_tot
regexp {Dynamic \(W\)[^0-9]*([0-9]+\.[0-9]+)}              $texto -> p_din
regexp {Device Static \(W\)[^0-9]*([0-9]+\.[0-9]+)}        $texto -> p_est
if {$p_tot == 0} {
    puts "AVISO: nao consegui extrair a potencia; veja $reports/power_ppa.rpt"
}

# A linha "Internal nodes activity" do relatorio diz que fracao dos nos
# internos teve atividade fornecida pelo usuario. E o unico indicador honesto
# de que o SAIF foi de fato aplicado: com anotacao boa ela fica alta, e sem
# anotacao fica em "less than 25%" mesmo tendo-se passado um arquivo.
set conf_int "?"
set det_int  ""
set conf_ger "?"
regexp {Internal nodes activity\s*\|\s*(\S+)\s*\|\s*([^|]*)\|} $texto \
       -> conf_int det_int
regexp {Overall confidence level\s*\|\s*(\S+)} $texto -> conf_ger
set det_int [string trim $det_int]

# Energia por bit: potencia dividida por vazao. E o numero que permite comparar
# geradores de vazoes diferentes, porque normaliza o custo pela producao.
#
# Sao reportados dois valores, e a distincao nao e detalhe:
#
#   dinamica -- so o consumo de chaveamento. E o custo atribuivel ao gerador, e
#               e este que deve ser citado ao comparar com outros PRNGs.
#   total    -- inclui a estatica do ZU7EV inteiro, que existiria com o FPGA
#               vazio e nao tem relacao com o tamanho do design. Serve como
#               limite superior do custo de um sistema que dedique esta peca ao
#               gerador, nao como custo do gerador.
#
# Mesmo a dinamica superestima: ela cobre o dispositivo todo, incluindo o que o
# ILA e o VIO nao consomem aqui (este e o projeto limpo) mas tambem os buffers
# de clock e a I/O. Para atribuir por hierarquia, veja power_hier.rpt.
proc pj_por_bit {watts mbps} {
    return [expr {$mbps > 0 ? ($watts * 1.0e12) / ($mbps * 1.0e6) : 0}]
}
set pj_din [pj_por_bit $p_din $mbps]
set pj_tot [pj_por_bit $p_tot $mbps]

# ---- saida -------------------------------------------------------------------
puts ""
puts "=================== PPA -- PRNG takum32 ==================="
puts ""
puts "PERFORMANCE"
puts [format "  clock de operacao      : %.1f MHz (periodo %.3f ns)" $fop $per]
puts [format "  WNS / WHS              : %+.3f / %+.3f ns" $wns $whs]
puts [format "  Fmax alcancavel        : %.1f MHz" $fmax]
puts [format "  ciclos por iteracao    : %.0f" $ciclos_it]
puts [format "  bits por iteracao      : %.2f (media, varia de 20 a 27)" $bits_it]
puts [format "  bits por ciclo         : %.4f" $bpc]
puts [format "  vazao a %.0f MHz        : %.2f Mbit/s" $fop $mbps]
puts [format "  vazao no Fmax          : %.2f Mbit/s" $mbps_max]
puts ""
puts "AREA"
puts [format "  LUT                    : %d" $lut]
puts [format "  FF                     : %d" $ff]
puts [format "  BRAM (RAMB36 / RAMB18) : %d / %d" $ram36 $ram18]
puts [format "  DSP48                  : %d" $dsp]
puts ""
puts "POTENCIA  ($fonte)"
puts [format "  confianca (geral)      : %s" $conf_ger]
puts [format "  confianca (nos int.)   : %s -- %s" $conf_int $det_int]
# O rotulo (Low/Medium/High) e generoso demais para servir de alarme: uma
# anotacao que cobre menos de um quarto dos nos internos ainda aparece como
# "Medium". Quem denuncia e o texto do detalhe.
if {$saif ne "" && [string match -nocase "*less than*" $det_int]} {
    puts "  >> A cobertura da anotacao e parcial. A dinamica abaixo mistura"
    puts "     atividade medida (registradores e portas de hierarquia, cujos"
    puts "     nomes sobrevivem a sintese) com atividade estimada (as redes"
    puts "     combinacionais internas, que viram saidas de LUT renomeadas)."
    puts "     E o teto do que um SAIF comportamental alcanca; para cobertura"
    puts "     alta e preciso simular o netlist pos-sintese."
}
puts ""
puts [format "  dinamica               : %.3f W" $p_din]
puts [format "  estatica do dispositivo: %.3f W" $p_est]
puts [format "  total on-chip          : %.3f W" $p_tot]
puts ""
puts [format "  energia por bit (din.) : %.2f nJ/bit  (%.0f pJ)  <-- cite este" \
      [expr {$pj_din / 1000.0}] $pj_din]
puts [format "  energia por bit (total): %.2f nJ/bit  (%.0f pJ)  (limite sup.)" \
      [expr {$pj_tot / 1000.0}] $pj_tot]
puts ""
puts [format "  A estatica e do ZU7EV inteiro e existiria com o FPGA vazio: este"]
puts [format "  design usa %d de 312 BRAMs e %d de ~230000 LUTs. Atribui-la ao" \
      $ram36 $lut]
puts [format "  gerador superestimaria o custo por bit em ordens de grandeza."]
puts ""
puts [format "TEMPO DE GERACAO (a %.0f MHz)" $fop]
foreach n {1000000 10000000 100000000} {
    puts [format "  %11d bits         : %8.3f s" $n [expr {$n / ($mbps * 1.0e6)}]]
}
puts ""
puts "  Este e o tempo que o DESIGN leva para produzir os bits. O tempo de"
puts "  extracao pelo JTAG/ILA (capture_stream.tcl) e ordens de grandeza"
puts "  maior e mede o cabo, nao o gerador."
puts ""
puts "  relatorio de potencia: $reports/power_ppa.rpt"
puts "==========================================================="
