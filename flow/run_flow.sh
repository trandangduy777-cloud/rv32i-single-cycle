#!/bin/bash
# Chay LibreLane cho cac cau hinh moi va gom so lieu chinh vao results/flow_<ten>/.
# Dung trong container co LibreLane + PDK IHP SG13G2, tu thu muc goc repo:
#   bash flow/run_flow.sh                 # ca 2 cau hinh: lenh nen C, va C + cache
#   bash flow/run_flow.sh config_cached.json
cd "$(dirname "$0")/.."
CFGS=${@:-config_pipeline_c.json config_cached.json}
if command -v librelane >/dev/null; then LL="librelane"; else LL="python3 -m librelane"; fi
set -- $CFGS
total=$#; k=0
for cfg in $CFGS; do
    k=$((k + 1))
    name=$(basename "$cfg" .json)
    tag="flow_${name}_$(date +%Y%m%d_%H%M)"
    echo "=== [$k/$total] $cfg -> runs/$tag (bat dau $(date +%H:%M))"
    # chay thang ra terminal de thay thanh tien do cua LibreLane; log day du nam trong runs/$tag/
    $LL --run-tag "$tag" "$cfg"
    echo "    [$k/$total] ma thoat $? ($(date +%H:%M))"
    m=$(ls -d runs/$tag/final/metrics.json 2>/dev/null)
    mkdir -p "results/flow_${name}"
    if [ -n "$m" ]; then
        cp "$m" "results/flow_${name}/metrics.json"
        python3 - "$m" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
keys = ["design__instance__count", "design__instance__area", "design__die__area",
        "timing__setup__ws", "timing__hold__ws", "timing__setup_vio__count", "timing__hold_vio__count",
        "power__total", "route__drc_errors", "magic__drc_error__count", "design__lvs_error__count",
        "antenna__violating__nets"]
for k in keys:
    hit = [(kk, v) for kk, v in m.items() if kk == k or kk.startswith(k + "__corner:nom_typ")]
    for kk, v in hit[:2]:
        print(f"    {kk} = {v}")
PY
    else
        echo "    khong thay runs/$tag/final/metrics.json"
        tail -40 "runs/$tag/flow.log" > "results/flow_${name}/log_tail.txt" 2>/dev/null
    fi
done
