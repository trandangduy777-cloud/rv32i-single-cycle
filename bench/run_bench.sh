#!/bin/sh
# Chay benchmark va in CPI. Dung: sh bench/run_bench.sh (tu thu muc goc)
#   bench.hex   (RV32I thuan): ca 3 loi
#   bench_m.hex (nang lenh M): single-cycle va pipeline RV32IM
# Thoat voi ma loi 1 neu co TIMEOUT hoac checksum cua mot loi khac voi loi dau tien cung chuong trinh.
cd "$(dirname "$0")/.."
sh bench/build.sh >/dev/null || exit 1
fail=0
run() {   # run <ten hien thi> <co -D> <file hex> <cac file RTL...>
    name=$1; flag=$2; img=$3; shift 3
    iverilog -g2012 -o /tmp/bench_sim $flag bench/tb_bench.v "$@" || exit 1
    out=$(vvp /tmp/bench_sim +img=$img | grep -E "BENCH|CHECK|TIMEOUT")
    echo "== $name: $img"; echo "$out"
    chk=$(echo "$out" | grep CHECK)
    if [ -z "$chk" ]; then echo "   -> LOI: khong co checksum (TIMEOUT?)"; fail=1; return; fi
    ref=$(cat /tmp/bench_ref_$(basename $img) 2>/dev/null)
    if [ -z "$ref" ]; then echo "$chk" > /tmp/bench_ref_$(basename $img)
    elif [ "$chk" != "$ref" ]; then echo "   -> LOI: checksum khac loi dau tien"; fail=1; fi
}
rm -f /tmp/bench_ref_*
run "single-cycle"    ""           bench/bench.hex   rv32i_core.v
run "pipeline RV32I"  -DPIPE       bench/bench.hex   rv32i_pipeline.v
run "pipeline RV32IM" -DPIPE_FULL  bench/bench.hex   rv32im_pipeline.v rv32i_core.v
run "single-cycle"    ""           bench/bench_m.hex rv32i_core.v
run "pipeline RV32IM" -DPIPE_FULL  bench/bench_m.hex rv32im_pipeline.v rv32i_core.v
run "single-cycle"    ""           bench/bench_call.hex rv32i_core.v
run "pipeline RV32I"  -DPIPE       bench/bench_call.hex rv32i_pipeline.v
run "pipeline RV32IM" -DPIPE_FULL  bench/bench_call.hex rv32im_pipeline.v rv32i_core.v
[ $fail -eq 0 ] && echo "Checksum khop giua cac loi" || echo "CO LOI"
exit $fail
