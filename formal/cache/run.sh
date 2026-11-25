#!/bin/bash
# Chung minh cache lenh / cache du lieu bang k-quy nap tren RTL that (bat bien nam trong rv32_icache.v / rv32_dcache.v, ifdef RISCV_FORMAL_CACHE),
# voi nhieu cau hinh (LINES, WORDS, WAYS, WBUF); roi doi chung am: moi dot bien phai lam chung minh khong con PASS.
#   bash formal/cache/run.sh            # chung minh + dot bien
#   bash formal/cache/run.sh nomut      # chi chung minh
#   bash formal/cache/run.sh i|d [nomut]  # chi cache lenh / du lieu
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
W=${WORK:-/tmp/cache-formal}; rm -rf "$W"; mkdir -p "$W"; rc=0
which=${1:-all}; [ "$which" = nomut ] && { which=all; set -- all nomut; }
mut=${2:-mut}
stage() {   # stage <dir> <rtl-dir>: sby + harness + RTL vao thu muc
    mkdir -p "$1"; cp "$HERE"/*.sby "$HERE"/*_harness.v "$1/"; sed -i 's#\.\./\.\./##' "$1"/*.sby
    cp "$2/rv32_icache.v" "$2/rv32_dcache.v" "$1/"
}
prove() {   # prove <dir> <sby> <task>
    ( cd "$1" && sby -f "$2" "$3" > "$3.log" 2>&1; grep -E "DONE \(" "$3.log" | sed "s/.*DONE/DONE/" )
}
stage "$W/main" "$ROOT"
if [ "$which" = all ] || [ "$which" = i ]; then
    for t in w1 w2 w4 s1 big; do s=$(date +%s); r=$(prove "$W/main" icache.sby $t); echo "cache lenh $t: $r ($(( $(date +%s) - s )) s)"; echo "$r" | grep -q PASS || rc=1; done
fi
if [ "$which" = all ] || [ "$which" = d ]; then
    for t in w1 w2 w4 u2 big; do s=$(date +%s); r=$(prove "$W/main" dcache.sby $t); echo "cache du lieu $t: $r ($(( $(date +%s) - s )) s)"; echo "$r" | grep -q PASS || rc=1; done
fi
[ "$mut" = nomut ] && exit $rc
python3 "$HERE/mutate.py" "$W" "$ROOT" "$HERE" "$which" || rc=1
exit $rc
