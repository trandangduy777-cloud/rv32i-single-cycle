#!/bin/sh
# Tong hop pipeline RV32IMC (flow/rv32imc_top.v) voi thu vien cell IHP SG13G2 (goc cham 1,08 V 125 C) cho MUL_LAT = 0 / 1 / 2,
# roi STA truoc P&R bang OpenSTA. Day KHONG phai ket qua flow: khong co floorplan, CTS, ky sinh day; buffer va kich thuoc
# cell do ABC (buffer / upsize / dnsize) chon thay cho resizer cua OpenROAD. Dung de so sanh tuong doi giua cac cau hinh.
# Dung (tu thu muc goc repo): sh synth/run_synth_sta.sh <thu muc lib cua sg13g2_stdcell>
# Can: yosys (hoac yowasp-yosys), sta (OpenSTA). Ket qua: synth/build/{stat,sta}_<L>.txt
set -e
LIBDIR=${1:?can duong dan toi ihp-sg13g2/libs.ref/sg13g2_stdcell/lib}
LIB=sg13g2_stdcell_slow_1p08V_125C.lib
YOSYS=$(command -v yosys || command -v yowasp-yosys)
STA=${STA:-sta}
cd "$(dirname "$0")"
mkdir -p build
cp "$LIBDIR/$LIB" abc.script sta.tcl sta_mul.tcl build/
cp ../flow/rv32imc_top.v ../rv32im_pipeline.v ../rv32i_core.v ../rv32c_decompress.v build/
cd build
for L in 0 1 2; do
  echo "[$((L + 1))/3] tong hop MUL_LAT = $L ..."
  $YOSYS -q -l syn_$L.log -p "read_verilog rv32imc_top.v rv32im_pipeline.v rv32i_core.v rv32c_decompress.v; \
    chparam -set MUL_LAT $L rv32im_pipeline; synth -flatten -top rv32imc_top; dfflibmap -liberty $LIB; \
    abc -liberty $LIB -D 15000 -script abc.script -dont_use sg13g2_sighold -dont_use sg13g2_lgcp_1 -dont_use sg13g2_slgcp_1; \
    opt_clean; hilomap -singleton -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO; \
    tee -q -o stat_$L.txt stat -liberty $LIB; write_verilog -noattr -noexpr net_$L.v"
  NET=net_$L.v $STA -no_init -exit sta.tcl > sta_$L.txt 2>&1
  echo "      $(grep 'Chip area' stat_$L.txt | sed 's/.*: //') um2, $(grep -m1 'slack (' sta_$L.txt)"
done
echo "duong cua bo nhan 2 tang (MUL_LAT = 2):"
$STA -no_init -exit sta_mul.tcl 2>&1 | grep -E "^--- |^ +[0-9.]+ +data arrival|slack \("
