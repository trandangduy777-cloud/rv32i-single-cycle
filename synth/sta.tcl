# STA truoc P&R: netlist yosys + ABC, thu vien SG13G2 goc cham 1,08 V 125 C, khong co ky sinh day (chi tai chan cell).
# Rang buoc giong mac dinh LibreLane: chu ky 15 ns, tre vao/ra 20 % chu ky. Duong reset bo qua (flow dung cay buffer rieng).
read_liberty sg13g2_stdcell_slow_1p08V_125C.lib
read_verilog $::env(NET)
link_design rv32imc_top
create_clock -name clk -period 15 [get_ports clk]
set_input_delay 3 -clock clk [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay 3 -clock clk [all_outputs]
set_false_path -from [get_ports rst_n]
report_checks -path_delay max -group_path_count 1 -format full -fields {fanout net} -digits 3
report_wns -digits 3
report_tns -digits 3
