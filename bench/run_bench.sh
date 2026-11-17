#!/bin/sh
# Chay benchmark va in CPI. Dung: sh bench/run_bench.sh (tu thu muc goc)
#   bench.hex   (RV32I thuan): ca 3 loi
#   bench_m.hex (nang lenh M): single-cycle va pipeline RV32IM
cd "$(dirname "$0")/.."
sh bench/build.sh >/dev/null
run() {   # run <ten hien thi> <co -D> <file hex> <cac file RTL...>
    name=$1; flag=$2; img=$3; shift 3
    iverilog -g2012 -o /tmp/bench_sim $flag bench/tb_bench.v "$@" || exit 1
    echo "== $name: $img"; vvp /tmp/bench_sim +img=$img | grep -E "BENCH|CHECK|TIMEOUT"
}
run "single-cycle"    ""           bench/bench.hex   rv32i_core.v
run "pipeline RV32I"  -DPIPE       bench/bench.hex   rv32i_pipeline.v
run "pipeline RV32IM" -DPIPE_FULL  bench/bench.hex   rv32im_pipeline.v rv32i_core.v
run "single-cycle"    ""           bench/bench_m.hex rv32i_core.v
run "pipeline RV32IM" -DPIPE_FULL  bench/bench_m.hex rv32im_pipeline.v rv32i_core.v
