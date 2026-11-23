#!/bin/sh
# Uoc luong dien tich SoC (loi RV32IMC + bus + UART + GPIO + CLINT + SYSCON) theo tung khoi voi thu vien cell IHP SG13G2 (goc cham 1,08 V 125 C):
# yosys + ABC (cung script abc.script voi synth/run_synth_sta.sh), TRUOC P&R: khong co dien tich day, buffer cua resizer, CTS. ROM va RAM la blackbox
# (mang flip-flop 16 KB moi cai, chua co macro SRAM), nen khong nam trong so nay. Khong chay STA (can OpenSTA).
# Dung (tu thu muc goc repo): sh soc/synth/run_soc_area.sh <thu muc lib cua sg13g2_stdcell>      Ket qua: soc/synth/build/{stat.txt,area.txt}
set -e
LIBDIR=${1:?can duong dan toi ihp-sg13g2/libs.ref/sg13g2_stdcell/lib}
LIB=sg13g2_stdcell_slow_1p08V_125C.lib
YOSYS=$(command -v yosys || command -v yowasp-yosys)
cd "$(dirname "$0")"
mkdir -p build
cp "$LIBDIR/$LIB" ../../synth/abc.script build/
cd build
SRC="../blackbox_mem.v ../../soc_uart.v ../../soc_gpio.v ../../soc_bus.v ../../soc_syscon.v ../../soc_top.v ../../../rv32_mtimer.v \
     ../../../rv32im_pipeline.v ../../../rv32i_core.v ../../../rv32c_decompress.v"
$YOSYS -q -l syn.log -p "read_verilog $SRC; hierarchy -top soc_top; synth -top soc_top; dfflibmap -liberty $LIB; \
    abc -liberty $LIB -D 15000 -script abc.script -dont_use sg13g2_sighold -dont_use sg13g2_lgcp_1 -dont_use sg13g2_slgcp_1; \
    opt_clean; hilomap -singleton -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO; \
    tee -q -o stat.txt stat -liberty $LIB -top soc_top"
python3 - <<'PY'
import re
t = open('stat.txt').read()
t = t.split("=== design hierarchy ===")[0]
own, subs = {}, {}
for blk in re.split(r"\n=== ", "\n" + t):
    if not blk.strip(): continue
    nm = blk.split(" ===")[0].strip().lstrip("\\")
    m = re.search(r"Chip area for module '.*': ([0-9.]+)$", blk, re.M)
    if not m: continue
    own[nm] = float(m.group(1))
    subs[nm] = [(int(n), c.strip().lstrip("\\")) for n, c in re.findall(r"^\s+(\d+)\s+-\s+(\S.*)$", blk.split("- submodules")[1] if "- submodules" in blk else "", re.M) if not c.startswith("wire")]
def incl(n):
    return own[n] + sum(k * incl(c) for k, c in subs[n] if c in own)
top = incl("soc_top")
rows = [("soc_top (glue)", own["soc_top"])]
for k, c in subs["soc_top"]:
    if c in own: rows.append((re.sub(r"\$paramod[^\\]*\\", "", c).split("\\")[0].split("=")[0], incl(c)))
out = ["%-24s %10.1f um2  %5.1f %%" % (n, a, 100 * a / top) for n, a in sorted(rows, key=lambda r: -r[1])]
out.append("TONG soc_top (khong gom ROM/RAM): %.1f um2" % top)
open('area.txt', 'w').write("\n".join(out) + "\n")
print("\n".join(out))
PY
