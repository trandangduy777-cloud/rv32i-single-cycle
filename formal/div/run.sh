#!/bin/bash
# Chung minh bo chia rv32m: (1) k-induction tren RTL (assert nam trong rv32m, `ifdef RISCV_FORMAL_DIV) voi 3 cau hinh dang dung
# (PREP, STEPS) = (1,2) pipeline, (0,1) don chu ky, (0,4); (2) phan dai so (z3); (3) doi chung am: moi dot bien RTL phai lam chung minh khong con PASS (FAIL hoac UNKNOWN).
#   bash formal/div/run.sh            # (1) + (2) + (3)
#   bash formal/div/run.sh nomut      # chi (1) + (2)
# Can sby + boolector (xem formal/setup_ci.sh) va z3-solver.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
W=${WORK:-/tmp/div-formal}; rm -rf "$W"; mkdir -p "$W"; rc=0
cp "$HERE/div.sby" "$HERE/div_harness.v" "$W/"; mkdir -p "$W/../x" 2>/dev/null
run() {   # run <dir> <task>
    ( cd "$1" && sby -f div.sby "$2" > "$2.log" 2>&1; grep -E "DONE \(" "$2.log" | sed "s/.*DONE/DONE/" )
}
cfg() { local d=$W/$1; mkdir -p "$d"; cp "$HERE/div.sby" "$HERE/div_harness.v" "$d/"; sed -i 's#\.\./\.\./rv32i_core.v#rv32i_core.v#' "$d/div.sby"; cp "${2:-$ROOT/rv32i_core.v}" "$d/rv32i_core.v"; }
cfg main
for t in p1s2 p0s1 p0s4; do
    s=$(date +%s); r=$(run "$W/main" $t); echo "k-induction $t: $r ($(( $(date +%s) - s )) s)"
    echo "$r" | grep -q "PASS" || rc=1
done
python3 "$HERE/div_algebra.py" | tail -1 | sed 's/^/dai so: /'; python3 "$HERE/div_algebra.py" >/dev/null || rc=1
[ "${1:-}" = nomut ] && exit $rc
MUTS=(
"so_sanh_lon_hon#ge  = (rem >= {1'b0, mm});#ge  = (rem > {1'b0, mm});"
"tru_thanh_cong#sub = rem - {1'b0, mm};#sub = rem + {1'b0, mm};"
"bit_thuong_sai#{rem[31:0], pp[30:0], 1'b0}#{rem[31:0], pp[30:0], 1'b1}"
"thieu_buoc#localparam [4:0] LAST = 32 / STEPS - 1;#localparam [4:0] LAST = 32 / STEPS - 2;"
"du_sai_dau#neg_rem <= sa_r;#neg_rem <= sb_r;"
"chia_0_dau#neg_res <= (sa_r ^ sb_r) & (m != 32'd0);#neg_res <= (sa_r ^ sb_r);"
"div_thieu_cong_1#3'b100:  result = neg_res ? (~p[31:0] + 32'd1) : p[31:0];#3'b100:  result = neg_res ? ~p[31:0] : p[31:0];"
)
for m in "${MUTS[@]}"; do
    IFS='#' read -r name old new <<< "$m"
    cfg "m_$name"; python3 - "$W/m_$name/rv32i_core.v" "$old" "$new" <<'PY' || { echo "$name: KHONG TIM THAY doan goc"; rc=1; continue; }
import sys
p, old, new = sys.argv[1:]
s = open(p).read(); assert s.count(old) == 1, s.count(old); open(p, "w").write(s.replace(old, new))
PY
    r=$(run "$W/m_$name" p1s2); echo "dot bien $name: $r"
    # bi bat = chung minh khong con PASS: FAIL (co phan vi du) hoac UNKNOWN (cac bat bien quy nap khong dong duoc nua)
    echo "$r" | grep -q "PASS" && rc=1
done
exit $rc
