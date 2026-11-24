#!/usr/bin/env python3
"""Sinh thu vien liberty rat nho mo ta soc_rom / soc_ram nhu cell khong co cung thoi gian (chi co chan), de OpenSTA dat duoc rang buoc o chan bo nho."""
import sys
def bus(name, width, d):
    return f"    bus ({name}) {{ bus_type : b{width}; direction : {d}; capacitance : 0.005; }}\n"
def pin(name, d):
    return f"    pin ({name}) {{ direction : {d}; capacitance : 0.005; }}\n"
L = "library (mem_stub) {\n  delay_model : table_lookup;\n  time_unit : \"1ns\"; voltage_unit : \"1V\"; current_unit : \"1mA\";\n  pulling_resistance_unit : \"1kohm\"; capacitive_load_unit (1, pf);\n"
for w in (32, 4):
    L += f"  type (b{w}) {{ base_type : array; data_type : bit; bit_width : {w}; bit_from : {w-1}; bit_to : 0; }}\n"
L += "  cell (soc_rom) {\n    area : 0;\n" + bus("i_addr", 32, "input") + bus("i_data", 32, "output") + bus("d_addr", 32, "input") + bus("d_data", 32, "output") + "  }\n"
L += ("  cell (soc_ram) {\n    area : 0;\n" + pin("clk", "input") + pin("sel", "input") + pin("we", "input") + bus("addr", 32, "input") + bus("wstrb", 4, "input") +
      bus("wdata", 32, "input") + bus("rdata", 32, "output") + bus("i_addr", 32, "input") + bus("i_data", 32, "output") + "  }\n")
L += "}\n"
open(sys.argv[1], "w").write(L)
