#!/bin/bash
# Chay LibreLane cho cac cau hinh cua pipeline RV32IMC tren RTL hien tai va gom so lieu chinh vao results/flow_<ten>/.
# Dung trong container co LibreLane + PDK IHP SG13G2, tu thu muc goc repo:
#   bash flow/run_flow.sh                          # 3 cau hinh: mac dinh, S/U + MMU, Zb* day du
#   bash flow/run_flow.sh config_su_mmu.json       # chi mot cau hinh
#   bash flow/run_flow.sh --check                  # chi kiem file cau hinh + danh sach file Verilog, khong chay flow
# LibreLane in thanh tien do (buoc hien tai / tong so buoc) thang ra terminal; script chi them dong tong
# [cau hinh k/n], gio bat dau, thoi gian da chay, va bang tom tat o cuoi (cung ghi vao results/flow_summary.md).
# Log day du cua tung lan chay nam trong runs/<tag>/.
cd "$(dirname "$0")/.."
CHECK=0
if [ "$1" = "--check" ]; then CHECK=1; shift; fi
CFGS=${*:-config_pipeline_c.json config_su_mmu.json config_zb.json}

# kiem truoc: JSON doc duoc, moi file Verilog ton tai (loi o day ton vai giay thay vi vai chuc phut flow)
python3 - $CFGS <<'PY' || exit 1
import json, os, sys
bad = 0
for cfg in sys.argv[1:]:
    try:
        c = json.load(open(cfg))
    except Exception as e:
        print(f"[kiem] {cfg}: khong doc duoc JSON ({e})"); bad = 1; continue
    miss = [f for f in c.get("VERILOG_FILES", []) if not os.path.exists(f.replace("dir::", ""))]
    p = " ".join(c.get("SYNTH_PARAMETERS", [])) or "mac dinh"
    print(f"[kiem] {cfg}: {c['DESIGN_NAME']}, {c['CLOCK_PERIOD']} ns, tham so: {p}" +
          (f", THIEU FILE: {miss}" if miss else ""))
    bad |= bool(miss)
sys.exit(bad)
PY
[ $CHECK = 1 ] && exit 0

if command -v librelane >/dev/null; then LL="librelane"; else LL="python3 -m librelane"; fi
set -- $CFGS
total=$#; k=0; t_all=$(date +%s)
SUM=results/flow_summary.md
mkdir -p results
printf '| Cau hinh | Ma thoat | Thoi gian | Cell | Dien tich cell (um2) | WNS setup (ns) | WNS hold (ns) | Vi pham setup / hold | DRC | LVS |\n|---|---|---|---|---|---|---|---|---|---|\n' > "$SUM.tmp"
for cfg in $CFGS; do
    k=$((k + 1))
    name=$(basename "$cfg" .json)
    tag="flow_${name}_$(date +%Y%m%d_%H%M)"
    t0=$(date +%s)
    echo
    echo "=== [cau hinh $k/$total] $cfg -> runs/$tag (bat dau $(date +%H:%M), da chay tong $(( (t0 - t_all) / 60 )) phut)"
    # chay thang ra terminal (khong chuyen huong) de thay thanh tien do cua LibreLane
    $LL --run-tag "$tag" "$cfg"
    rc=$?
    dt=$(( ($(date +%s) - t0) / 60 ))
    echo "=== [cau hinh $k/$total] $cfg: ma thoat $rc sau $dt phut ($(date +%H:%M))"
    mkdir -p "results/flow_${name}"
    m=runs/$tag/final/metrics.json
    if [ -f "$m" ]; then
        cp "$m" "results/flow_${name}/metrics.json"
        python3 - "$m" "$name" "$rc" "$dt" >> "$SUM.tmp" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); name, rc, dt = sys.argv[2:5]
def g(k):
    for kk in (k, k + "__corner:nom_typ_1p20V_25C", k + "__corner:nom_fast_1p32V_m40C"):
        if kk in m: return m[kk]
    return "?"
def f(v, d=3): return f"{v:.{d}f}" if isinstance(v, (int, float)) else str(v)
print(f"| {name} | {rc} | {dt} phut | {g('design__instance__count')} | {f(g('design__instance__area'), 0)} | "
      f"{f(g('timing__setup__ws'))} | {f(g('timing__hold__ws'))} | "
      f"{g('timing__setup_vio__count')} / {g('timing__hold_vio__count')} | "
      f"{g('route__drc_errors')} / {g('magic__drc_error__count')} | {g('design__lvs_error__count')} |")
PY
    else
        echo "    khong thay $m: xem runs/$tag/flow.log (40 dong cuoi da chep vao results/flow_${name}/log_tail.txt)"
        tail -40 "runs/$tag/flow.log" > "results/flow_${name}/log_tail.txt" 2>/dev/null
        echo "| $name | $rc | $dt phut | loi, xem results/flow_${name}/log_tail.txt | | | | | | |" >> "$SUM.tmp"
    fi
done
mv "$SUM.tmp" "$SUM"
echo
echo "=== xong $total cau hinh sau $(( ($(date +%s) - t_all) / 60 )) phut. Tom tat (results/flow_summary.md):"
cat "$SUM"
