#!/bin/sh
# Uoc luong dien tich SoC AXI4 (soc_axi_top: loi RV32IMC + cache lenh 2 KB + cache du lieu 1 KB + interconnect AXI4 3x3 + DMA 2 kenh + cau ngoai vi + CLINT / PLIC / UART / GPIO / SYSCON)
# theo tung khoi voi thu vien cell IHP SG13G2 (goc cham 1,08 V 125 C): yosys + ABC (cung abc.script voi synth/run_synth_sta.sh), TRUOC P&R (khong co day, buffer, CTS).
# ROM va RAM (axi_mem) la blackbox (mang flip-flop 16 KB moi cai, chua co macro SRAM). Cache lenh / du lieu o day cung la mang flip-flop (khong co macro SRAM) nen chiem phan lon dien tich:
# bang cung liet ke rieng "cache (mang FF)" va tong khong gom cache de so voi soc_top.
# Dung (tu thu muc goc repo): sh soc/synth/run_axi_area.sh <thu muc lib cua sg13g2_stdcell>      Ket qua: soc/synth/build/{stat_axi.txt, area_axi.txt}
set -e
LIBDIR=${1:?can duong dan toi ihp-sg13g2/libs.ref/sg13g2_stdcell/lib}
LIB=sg13g2_stdcell_slow_1p08V_125C.lib
YOSYS=$(command -v yosys || command -v yowasp-yosys)
cd "$(dirname "$0")"
mkdir -p build
cp "$LIBDIR/$LIB" ../../synth/abc.script build/
cd build
SRC="../blackbox_axi_mem.v ../../axi/axi_soc_top.v ../../axi/axi_xbar.v ../../axi/axi_cache_if.v ../../axi/axi_periph_bridge.v ../../axi/axi_dma.v \
     ../../soc_uart.v ../../soc_gpio.v ../../soc_bus.v ../../soc_syscon.v ../../soc_plic.v ../../../rv32_mtimer.v ../../../rv32_icache.v ../../../rv32_dcache.v \
     ../../../rv32im_pipeline.v ../../../rv32i_core.v ../../../rv32c_decompress.v"
$YOSYS -q -l syn_axi.log -p "read_verilog -sv $SRC; hierarchy -top soc_axi_top; synth -top soc_axi_top; dfflibmap -liberty $LIB; \
    abc -liberty $LIB -D 15000 -script abc.script -dont_use sg13g2_sighold -dont_use sg13g2_lgcp_1 -dont_use sg13g2_slgcp_1; \
    opt_clean; hilomap -singleton -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO; \
    tee -q -o stat_axi.txt stat -liberty $LIB -top soc_axi_top"
python3 - <<'PY'
import re
t = open('stat_axi.txt').read()
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
top = incl("soc_axi_top")
rows = [("soc_axi_top (glue)", own["soc_axi_top"])]
for k, c in subs["soc_axi_top"]:
    if c in own: rows.append((re.sub(r"\$paramod[^\\]*\\", "", c).split("\\")[0].split("=")[0], k * incl(c)))
agg = {}
for n, a in rows: agg[n] = agg.get(n, 0) + a
out = ["%-24s %10.1f um2  %5.1f %%" % (n, a, 100 * a / top) for n, a in sorted(agg.items(), key=lambda r: -r[1])]
caches = agg.get("rv32_icache", 0) + agg.get("rv32_dcache", 0)
axi = sum(agg.get(n, 0) for n in ("axi_xbar", "axi_dma", "axi_periph_bridge", "axi_icache_master", "axi_dcache_master"))
out.append("TONG soc_axi_top (khong gom ROM/RAM): %.1f um2" % top)
out.append("  trong do cache lenh + du lieu (mang FF): %.1f um2; bus AXI4 + DMA + cau (xbar, dma, periph_bridge, 2 cau cache): %.1f um2; con lai (loi + ngoai vi cu): %.1f um2" % (caches, axi, top - caches - axi))
open('area_axi.txt', 'w').write("\n".join(out) + "\n")
print("\n".join(out))
PY
