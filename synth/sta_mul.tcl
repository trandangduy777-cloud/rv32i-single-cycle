# STA rieng 2 tang cua bo nhan MUL_LAT = 2: vao cac flop mw_s / mw_c (cay Booth + CSA) va ra tu chung (bo cong 66 bit).
read_liberty sg13g2_stdcell_slow_1p08V_125C.lib
read_verilog net_2.v
link_design rv32imc_top
create_clock -name clk -period 15 [get_ports clk]
set_input_delay 3 -clock clk [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay 3 -clock clk [all_outputs]
set_false_path -from [get_ports rst_n]
# flop chot sum / carry cua cay CSA (tang 1 cua MUL_LAT = 2)
set mw {}
foreach c [get_cells *] { foreach p [get_pins -of_objects $c -filter "direction==output"] { set n [get_nets -of_objects $p]; if {[regexp {mw_[sc]} [get_full_name $n]]} { lappend mw $c } } }
puts "so flop mw: [llength $mw]"
puts "--- vao tang 1 (cay Booth + CSA):"
report_checks -to [get_pins -of_objects $mw -filter "direction==input"] -path_delay max -format end -digits 3 -group_path_count 1
report_checks -to [get_pins -of_objects $mw -filter "direction==input"] -path_delay max -digits 3 -fields {net} -group_path_count 1
puts "--- ra tu tang 1 (bo cong 66 bit + chon ket qua):"
report_checks -from $mw -path_delay max -digits 3 -fields {net} -group_path_count 1
