#!/bin/sh
# Tong hop SoC (soc_top, flatten, ROM/RAM blackbox) voi IHP SG13G2 goc cham 1,08 V 125 C roi STA truoc P&R bang OpenSTA (soc_sta.tcl).
# KHONG phai ket qua flow: khong floorplan/CTS/ky sinh day, buffer do ABC chon; ROM/RAM la blackbox voi gia dinh thoi gian truy cap D_MEM (xem soc_sta.tcl).
# Dung (tu thu muc goc repo): sh soc/synth/run_soc_sta.sh <thu muc lib cua sg13g2_stdcell>     Bien: STA=duong dan toi sta, D_MEM (ns), PERIOD (ns)
# Ket qua: soc/synth/build/{stat_sta.txt, sta_soc.txt}
set -e
LIBDIR=${1:?can duong dan toi ihp-sg13g2/libs.ref/sg13g2_stdcell/lib}
LIB=sg13g2_stdcell_slow_1p08V_125C.lib
YOSYS=$(command -v yosys || command -v yowasp-yosys)
STA=${STA:-sta}
cd "$(dirname "$0")"
mkdir -p build
cp "$LIBDIR/$LIB" ../../synth/abc.script soc_sta.tcl build/
python3 mem_stub_lib.py build/mem_stub.lib
cd build
SRC="../blackbox_mem.v ../../soc_uart.v ../../soc_gpio.v ../../soc_bus.v ../../soc_syscon.v ../../soc_plic.v ../../soc_top.v ../../../rv32_mtimer.v \
     ../../../rv32im_pipeline.v ../../../rv32i_core.v ../../../rv32c_decompress.v"
$YOSYS -q -l syn_sta.log -p "read_verilog $SRC; hierarchy -top soc_top; synth -flatten -top soc_top; dfflibmap -liberty $LIB; \
    abc -liberty $LIB -D 15000 -script abc.script -dont_use sg13g2_sighold -dont_use sg13g2_lgcp_1 -dont_use sg13g2_slgcp_1; \
    opt_clean; hilomap -singleton -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO; \
    tee -q -o stat_sta.txt stat -liberty $LIB -top soc_top; write_verilog -noattr -noexpr net_soc.v"
# OpenSTA khong doc duoc "#(.THAM_SO(..))" o instance cua blackbox: bo tham so (cac blackbox khong dung chung tham so de tinh thoi gian)
perl -0pi -e 's/#\(\s*\.\w+\([^)]*\)(\s*,\s*\.\w+\([^)]*\))*\s*\)//g' net_soc.v
NET=net_soc.v $STA -no_init -exit soc_sta.tcl > sta_soc.txt 2>&1
grep -E "Chip area|wns|tns|slack \(|D_MEM" stat_sta.txt sta_soc.txt
