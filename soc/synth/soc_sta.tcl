# STA truoc P&R cho SoC (soc_top, flatten, ROM/RAM la blackbox): thu vien SG13G2 goc cham 1,08 V 125 C, khong co ky sinh day.
# Rang buoc giong flow cua loi (chu ky 15 ns, tre vao/ra 20 % chu ky). ROM/RAM chua co macro nen chi la blackbox khong co cung thoi gian:
# gia dinh doc to hop mat D_MEM ns (macro SRAM thuc se co thoi gian truy cap rieng): moi chan VAO cua bo nho bi coi la diem cuoi voi
# output delay D_MEM, moi chan RA cua bo nho la diem dau voi input delay 0. D_MEM va chu ky dat bang bien moi truong D_MEM, PERIOD.
set D_MEM [expr {[info exists ::env(D_MEM)] ? $::env(D_MEM) : 3.0}]
set PERIOD [expr {[info exists ::env(PERIOD)] ? $::env(PERIOD) : 15.0}]
read_liberty sg13g2_stdcell_slow_1p08V_125C.lib
read_liberty mem_stub.lib           ;# soc_rom / soc_ram: cell khong co cung thoi gian, chi co chan (mem_stub_lib.py)
read_verilog $::env(NET)
link_design soc_top
create_clock -name clk -period $PERIOD [get_ports clk]
set io_in [delete_from_list [all_inputs] [get_ports clk]]
set_input_delay [expr {0.2 * $PERIOD}] -clock clk $io_in
set_output_delay [expr {0.2 * $PERIOD}] -clock clk [all_outputs]
set_false_path -from [get_ports rst_n]
# chan bo nho: ROM (i_addr, d_addr vao; i_data, d_data ra), RAM (addr, wdata, we, wstrb, sel, i_addr vao; rdata, i_data ra)
foreach inst {u_rom u_ram} {
  foreach p [get_pins $inst/*] {
    set d [get_property $p direction]
    set n [get_property $p name]
    if {$n eq "clk"} continue
    if {$d eq "input"}  { set_output_delay $D_MEM -clock clk $p }
    if {$d eq "output"} { set_input_delay 0 -clock clk $p }
  }
}
puts "== D_MEM = $D_MEM ns, chu ky = $PERIOD ns =="
report_checks -path_delay max -group_path_count 3 -unique_paths_to_endpoint -format full -fields {fanout} -digits 3
report_wns -digits 3
report_tns -digits 3
report_checks -path_delay min -group_path_count 1 -format end -digits 3
