#!/bin/sh
# Tong hop + STA truoc P&R cho tung cau hinh cua pipeline RV32IMC (flow/rv32imc_top.v), cung thu vien va rang buoc nhu
# run_synth_sta.sh (IHP SG13G2 goc cham 1,08 V 125 C, chu ky 15 ns, tre vao/ra 3 ns, bo duong reset).
# Moi cau hinh in: dien tich cell, WNS, diem dau / cuoi cua duong xau nhat (ten thanh ghi RTL) va slack xau nhat
# vao thanh ghi ket qua EX (exmem_result: ALU, Zb*, nhay, CSR).
# Dung (tu thu muc goc repo): sh synth/run_cfg_sta.sh <thu muc lib cua sg13g2_stdcell> [ten cau hinh ...]
#   khong ghi ten cau hinh = chay het. Can: yosys (hoac yowasp-yosys), sta (OpenSTA), python3.
# Ket qua: synth/build_cfg/<cau hinh>/{stat,sta,ex}.txt
set -e
LIBDIR=${1:?can duong dan toi ihp-sg13g2/libs.ref/sg13g2_stdcell/lib}
shift
LIB=sg13g2_stdcell_slow_1p08V_125C.lib
YOSYS=$(command -v yosys || command -v yowasp-yosys)
STA=${STA:-sta}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/flow/rv32imc_top.v $ROOT/rv32im_pipeline.v $ROOT/rv32i_core.v $ROOT/rv32c_decompress.v $ROOT/rv32_mmu.v $ROOT/rv32_tage.v"

# ten:tham so chparam cua flow/rv32imc_top.v (module dinh chuyen xuong rv32im_pipeline; chparam truc tiep tren
# rv32im_pipeline khong co tac dung vi instance da gan tham so)
CFGS="mac-dinh:
su-mmu:-set SU 1 -set MMU 1
tage:-set TAGE 1
su-mmu-tage:-set SU 1 -set MMU 1 -set TAGE 1
zb-khong-zbc:-set ZBA 1 -set ZBB 1 -set ZBS 1 -set ZICOND 1
zbc:-set ZBC 1
zb-day-du:-set ZBA 1 -set ZBB 1 -set ZBS 1 -set ZBC 1 -set ZICOND 1
rv32im-pmp0:-set ENABLE_C 0 -set PMP_N 0
phat-doi:-set ENABLE_C 0 -set PMP_N 0 -set DUAL 1"

WANT="$*"
N=$(echo "$CFGS" | wc -l); K=0
echo "$CFGS" | while IFS=: read -r NAME P; do
  K=$((K + 1))
  if [ -n "$WANT" ] && ! echo " $WANT " | grep -q " $NAME "; then continue; fi
  D="$ROOT/synth/build_cfg/$NAME"; mkdir -p "$D"; cd "$D"
  cp "$LIBDIR/$LIB" "$ROOT/synth/abc.script" .
  echo "[$K/$N] $NAME ($P): tong hop ..."
  DEFS=""; case "$P" in *DUAL*) DEFS="-DDUAL_FETCH" ;; esac   # phat doi: them cong imem_data2
  $YOSYS -q -l syn.log -p "read_verilog $DEFS $SRC; chparam $P rv32imc_top; synth -flatten -top rv32imc_top; \
    dfflibmap -liberty $LIB; \
    abc -liberty $LIB -D 15000 -script abc.script -dont_use sg13g2_sighold -dont_use sg13g2_lgcp_1 -dont_use sg13g2_slgcp_1; \
    opt_clean; hilomap -singleton -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO; \
    tee -q -o stat.txt stat -liberty $LIB; write_verilog -noattr -noexpr net.v" 2>/dev/null ||
    { echo "      tong hop loi, xem $D/syn.log"; exit 1; }
  # thanh ghi ket qua EX va ten RTL cua moi flip-flop (de doc duong toi han)
  python3 - <<'E'
import re
net = open("net.v").read(); q = {}; ex = []
for m in re.finditer(r"sg13g2_\w+ (_\d+_) \((.*?)\);", net, re.S):
    mm = re.search(r"\.Q\(([^)]*)\)", m.group(2))
    if mm:
        q[m.group(1)] = mm.group(1).strip().replace("\\", "").replace(" ", "")
        if "u_core.exmem_result" in mm.group(1):
            ex.append(m.group(1) + "/D")
open("ffname.txt", "w").write("".join(f"{k} {v}\n" for k, v in q.items()))
open("ex_pins.tcl", "w").write("set ex_pins [get_pins {%s}]\n" % " ".join(ex))
E
  cat > sta.tcl <<T
read_liberty $LIB
read_verilog net.v
link_design rv32imc_top
create_clock -name clk -period 15 [get_ports clk]
set_input_delay 3 -clock clk [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay 3 -clock clk [all_outputs]
set_false_path -from [get_ports rst_n]
report_checks -path_delay max -group_path_count 1 -format full -fields {fanout} -digits 3
report_wns -digits 3
source ex_pins.tcl
puts "--- EX"
report_checks -path_delay max -to \$ex_pins -format end -digits 3
T
  $STA -no_init -exit sta.tcl > sta.txt 2>&1
  python3 - "$NAME" <<'E'
import re, sys
q = dict(l.split() for l in open("ffname.txt"))
s = open("sta.txt").read(); full, ex = s.split("--- EX")
a = re.search(r"Startpoint: (\S+)", full).group(1); b = re.search(r"Endpoint: (\S+)", full).group(1)
wns = re.search(r"(-?[\d.]+)\s+slack", full).group(1)
exs = re.search(r"(-?[\d.]+)\s+\((?:MET|VIOLATED)\)", ex).group(1)
area = re.search(r"Chip area.*: ([\d.]+)", open("stat.txt").read()).group(1)
print(f"      {float(area):,.0f} um2, WNS {wns} ns ({q.get(a, a)} -> {q.get(b, b)}), slack vao exmem_result {exs} ns")
E
done
