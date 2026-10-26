#!/bin/sh
# Chay benchmark tren 3 loi va in CPI. Dung: sh bench/run_bench.sh (tu thu muc goc)
cd "$(dirname "$0")/.."
sh bench/build.sh >/dev/null
for cfg in "single-cycle:|rv32i_core.v" "pipeline RV32I:-DPIPE|rv32i_pipeline.v" "pipeline RV32IM:-DPIPE_FULL|rv32im_pipeline.v rv32i_core.v"; do
    name=${cfg%%:*}; rest=${cfg#*:}; flag=${rest%%|*}; files=${rest#*|}
    iverilog -g2012 -o /tmp/bench_sim $flag bench/tb_bench.v $files || exit 1
    echo "== $name"; vvp /tmp/bench_sim +img=bench/bench.hex | grep -E "BENCH|CHECK|TIMEOUT"
done
