#!/bin/bash
# Ghep bo nhan/chia vao pipeline: done cua RTL that == done cua ban ALTOPS va khong phu thuoc toan hang (xem stitch_harness.v).
#   bash formal/stitch/run.sh          # bmc (BMC 60 chu ky tu reset; k-quy nap khong dong duoc vi thieu bat bien trang thai) + dot bien
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
W=${WORK:-/tmp/stitch-formal}; rm -rf "$W"; mkdir -p "$W"; rc=0
gen() {   # gen <dir> <rv32i_core.v>: ban sao RTL + module rv32m_alt (rv32m doi ten, chi doc voi ALTOPS)
    mkdir -p "$1"; cp "$HERE/stitch.sby" "$HERE/stitch_harness.v" "$1/"; cp "$2" "$1/rv32i_core.v"
    python3 - "$1" <<'PY'
import sys, re
d = sys.argv[1]
s = open(d + "/rv32i_core.v").read()
i = s.index("module rv32m "); j = s.index("endmodule", i) + len("endmodule")
open(d + "/rv32m_alt.v", "w").write(s[i:j].replace("module rv32m ", "module rv32m_alt "))
PY
}
run() { ( cd "$1" && sby -f stitch.sby > "$2.log" 2>&1; grep -E "DONE \(" "$2.log" | sed "s/.*DONE/DONE/" ) ; }
gen "$W/main" "$ROOT/rv32i_core.v"
for t in bmc; do
    s=$(date +%s); r=$(run "$W/main" $t); echo "ghep $t: $r ($(( $(date +%s) - s )) s)"; echo "$r" | grep -q PASS || rc=1
done
[ "${1:-}" = nomut ] && exit $rc
MUTS=(
"chia_0_som#assign done = (state == FIN) | (state == MW) | f_now;#assign done = (state == FIN) | (state == MW) | f_now | (state == RUN \&\& cnt == LAST \&\& m == 32'd0);"
"cnt_phu_thuoc_du_lieu#if (cnt == LAST) state <= FIN;#if (cnt == LAST || (m == 32'd0 \&\& cnt == 5'd3)) state <= FIN;"
)
for m in "${MUTS[@]}"; do
    IFS='#' read -r name old new <<< "$m"
    gen "$W/m_$name" "$ROOT/rv32i_core.v"
    python3 - "$W/m_$name" "$old" "$new" <<'PY' || { echo "$name: KHONG TIM THAY doan goc"; rc=1; continue; }
import sys
d, old, new = sys.argv[1:]; new = new.replace("\\&", "&"); old = old.replace("\\&", "&")
for f in ("rv32i_core.v", "rv32m_alt.v"):
    s = open(d + "/" + f).read()
    if f == "rv32i_core.v":
        assert s.count(old) == 1, s.count(old); s = s.replace(old, new)
    elif old in s: s = s.replace(old, new.replace("rv32m ", "rv32m_alt "))
    open(d + "/" + f, "w").write(s)
PY
    r=$(run "$W/m_$name" bmc); echo "dot bien $name: $r"; echo "$r" | grep -q PASS && rc=1
done
exit $rc
