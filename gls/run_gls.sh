#!/bin/sh
# Mo phong muc cong (chuc nang, khong timing) netlist RV32IM sau P&R, so voi ket qua RTL.
# Dung (tu thu muc goc repo): sh gls/run_gls.sh <netlist.nl.v> [thu muc verilog cua thu vien sg13g2_stdcell]
# Mac dinh lay thu vien cell trong PDK: $PDK_ROOT/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog
set -e
cd "$(dirname "$0")/.."
NL=${1:?"can duong dan netlist, vi du runs/RUN_.../final/nl/rv32im_pipeline.nl.v"}
LIB=${2:-$PDK_ROOT/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog}
B=gls/build
mkdir -p $B
python3 gls/make_func_lib.py "$LIB/sg13g2_stdcell.v" $B/sg13g2_stdcell_func.v
CELLS="$B/sg13g2_stdcell_func.v $LIB/sg13g2_udp.v"

echo "== prog.hex: RTL va netlist"
iverilog -g2012 -DPIPE_FULL -DNO_VCD -o $B/rtl_prog tb_rv32i_pipeline.v rv32im_pipeline.v rv32i_core.v
iverilog -g2012 -DPIPE_FULL -DNO_VCD -o $B/gls_prog tb_rv32i_pipeline.v "$NL" $CELLS 2>/dev/null
vvp $B/rtl_prog +prog=prog.hex | grep TB
vvp $B/gls_prog +prog=prog.hex | grep TB

if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
    echo "== bench: RTL va netlist (netlist mat khoang 2 phut)"
    sh bench/build.sh >/dev/null
    iverilog -g2012 -DPIPE_FULL -o $B/rtl_bench bench/tb_bench.v rv32im_pipeline.v rv32i_core.v
    iverilog -g2012 -DPIPE_FULL -o $B/gls_bench bench/tb_bench.v "$NL" $CELLS 2>/dev/null
    vvp $B/rtl_bench +img=bench/bench.hex | grep -E "BENCH|CHECK"
    vvp $B/gls_bench +img=bench/bench.hex | grep -E "BENCH|CHECK"
else
    echo "bo qua bench: thieu riscv64-unknown-elf-gcc"
fi
