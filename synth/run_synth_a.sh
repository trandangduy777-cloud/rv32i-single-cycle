#!/bin/sh
# So sanh dien tich / tre uoc luong (TRUOC P&R) cua pipeline RV32IMC khi bat mo rong A (LR/SC + 9 AMO).
# Cung quy trinh run_synth_sta.sh (yosys + ABC, SG13G2 goc cham 1,08 V 125 C, 15 ns). Luon in dien tich; neu co OpenSTA
# (lenh "sta", hoac bien STA=/duong/dan/sta) thi chay them STA truoc P&R va in slack xau nhat; khong co thi ghi "chua do".
# KHONG phai ket qua flow: khong floorplan, CTS, ky sinh day. Chi dung so sanh tuong doi giua cac cau hinh.
# Dung (tu thu muc goc repo): sh synth/run_synth_a.sh <thu muc lib cua sg13g2_stdcell>
set -e
LIBDIR=${1:?can duong dan toi ihp-sg13g2/libs.ref/sg13g2_stdcell/lib}
LIB=sg13g2_stdcell_slow_1p08V_125C.lib
YOSYS=$(command -v yosys || command -v yowasp-yosys)
cd "$(dirname "$0")"
mkdir -p build_a
cp "$LIBDIR/$LIB" abc.script sta.tcl build_a/
cp ../flow/rv32imc_top.v ../rv32im_pipeline.v ../rv32i_core.v ../rv32c_decompress.v build_a/
cd build_a
i=0
for CFG in "0 0 khong A (A_EXT = 0)" "1 0 A_EXT = 1" "1 1 A_EXT = 1, A_ST_CLR = 1"; do
  set -- $CFG; A=$1; S=$2; shift 2; NAME="$*"; i=$((i + 1))
  $YOSYS -l syn_$i.log -p "read_verilog rv32imc_top.v rv32im_pipeline.v rv32i_core.v rv32c_decompress.v; \
    chparam -set A_EXT $A -set A_ST_CLR $S rv32im_pipeline; synth -flatten -top rv32imc_top; \
    dfflibmap -liberty $LIB; abc -liberty $LIB -D 15000 -script abc.script -dont_use sg13g2_sighold -dont_use sg13g2_lgcp_1 -dont_use sg13g2_slgcp_1; \
    opt_clean; hilomap -singleton -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO; \
    tee -q -o stat_$i.txt stat -liberty $LIB; write_verilog -noattr -noexpr net_$i.v" >/dev/null
  AREA=$(grep 'Chip area' stat_$i.txt | sed 's/.*: //')
  CELLS=$(grep -m1 ' cells$' stat_$i.txt | awk '{print $1}')
  if command -v ${STA:-sta} >/dev/null 2>&1; then
    NET=net_$i.v ${STA:-sta} -no_init -exit sta.tcl > sta_$i.txt 2>&1
    SL=$(grep -m1 'slack (' sta_$i.txt | sed 's/^ *//')
  else
    SL="chua do (khong co OpenSTA)"
  fi
  echo "$NAME|$AREA um2|$CELLS cell|$SL"
done
