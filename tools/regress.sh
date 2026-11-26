#!/bin/bash
# Regression day du cua repo, chia thanh cac buoc de chay tung phan (moi buoc in mot dong ket qua, log o $LOGDIR).
# Dung (tu thu muc goc repo):
#   bash tools/regress.sh                 # nhom "nhanh" (buoc 1-9, 15, 17, 19, 22, 24, 26; khoang 2 gio)
#   bash tools/regress.sh dot-bien        # nhom mutation (buoc 10-14, 16, 18, 20, 21, 23, 25, 27; vai gio)
#   bash tools/regress.sh tat-ca          # ca hai nhom
#   bash tools/regress.sh 2 7             # chi cac buoc 2 va 7
# Can moi truong cua tools/setup_env.sh. Thoat ma 1 o buoc dau tien that bai (in 20 dong cuoi cua log buoc do).
set -u
cd "$(dirname "$0")/.."
RT=${RISCV_TESTS:-/tmp/riscv-tests}
SPIKE=${SPIKE:-/opt/spike/bin/spike}
LOGDIR=${LOGDIR:-/tmp/regress_logs}
mkdir -p "$LOGDIR"

NAMES=("" "testbench tu kiem tra 3 loi" "so vet voi ISS, 15 cau hinh" "bo nhan: thu het W <= 10, W = 33" \
       "chung minh hinh thuc bo nhan" "ngat + mutation ngat" "giai nen lenh C" "riscv-tests" \
       "bench, du doan nhanh dung tung chu ky, CoreMark 1 vong" "so vet voi Spike (17 loi)" \
       "mutation single-cycle" "mutation pipeline RV32I" "mutation pipeline RV32IM" "mutation lenh C, bo nhan, du doan nhanh" \
       "mutation cache" "so vet voi Spike khi co ngat" "mutation ngat qua so vet Spike" \
       "SoC: bus, UART, GPIO, timer, chuong trinh C" "mutation SoC (152 mutant)" \
       "riscv-formal: moi check RVFI" "riscv-formal: dot bien co y" "mutation Zba/Zbb/Zbs/Zbc/Zicond" \
       "so vet ngau nhien voi Spike (22 loi, 8 chuong trinh moi loi) + test co huong csr_mie" "mutation so vet ngau nhien (16 dot bien)" \
       "SoC AXI4 + DMA: interconnect ngau nhien, giao thuc, chuong trinh C, DMA, FreeRTOS" "mutation AXI4 + DMA (55 mutant)" \
       "TAGE: so tung du doan voi mo hinh tham chieu (35 vet, 4 cau hinh)" "mutation TAGE (28 dot bien)")

step() {   # step <so>: chay buoc, tra ve 0 neu dat
    case $1 in
    1) iverilog -g2012 -DNO_VCD -o /tmp/r_sc tb_rv32i_core.v rv32i_core.v && vvp /tmp/r_sc > /tmp/r1a && grep -q "\[TB\] PASS" /tmp/r1a &&
       iverilog -g2012 -DPIPE -DNO_VCD -o /tmp/r_p tb_rv32i_pipeline.v rv32i_pipeline.v && vvp /tmp/r_p +prog=prog_base.hex > /tmp/r1b && grep -q "\[TB\] PASS" /tmp/r1b &&
       iverilog -g2012 -DPIPE_FULL -DNO_VCD -o /tmp/r_pm tb_rv32i_pipeline.v rv32im_pipeline.v rv32i_core.v && vvp /tmp/r_pm +prog=prog.hex > /tmp/r1c && grep -q "\[TB\] PASS" /tmp/r1c &&
       echo "3/3 PASS" ;;
    2) (cd verify && for o in "" "--pipe" "--pipem" "--pipem --cache" "--pipem --cache --ways 2" "--pipem --ma" "--pipem --ma --cache" \
               "--pipem --bpstress" "--pipem --bpstress --cache" "--pipem --mul-lat 0" "--pipem --mul-lat 1" "--pipem --mul-lat 1 --cache" \
               "--pipem --zb all --zb-probe" "--pipem --zb zba,zbs --zb-probe --cache" "--pipem --zb zbb,zbc,zicond --zb-probe --bpstress --mul-lat 0"; do
           python3 run_verify.py $o --n 60 > /tmp/r2 2>&1; l=$(head -1 /tmp/r2); echo "  [$o] $l"
           echo "$l" | grep -q "that bai: 0$" || exit 1
       done) ;;
    3) for w in 3 4 5 8 9 10 33; do iverilog -g2012 -DW=$w -o /tmp/r_mul mul/tb_mul.v rv32i_core.v &&
       vvp -n /tmp/r_mul +n=20000 | tee -a /dev/stderr | grep -q "\[MUL\] PASS" || return 1; done 2>&1 ;;
    4) python3 mul/formal/run_formal.py ;;
    5) iverilog -g2012 -o /tmp/r_irq irq/tb_irq.v rv32im_pipeline.v rv32i_core.v rv32_mtimer.v && vvp /tmp/r_irq | grep "\[IRQ\] PASS" &&
       python3 irq/mutate_irq.py ;;
    6) python3 rvc/check_decompress.py ;;
    7) python3 riscv-tests/run_riscv_tests.py "$RT" ;;
    8) sh bench/run_bench.sh && python3 bpred/perf_bpred.py --check && python3 coremark/run_coremark.py --iter 1 --quick ;;
    9) python3 cosim/run_cosim.py "$RT" --spike "$SPIKE" ;;
    10) (cd verify && python3 run_verify.py --mutate --stop-on-fail) ;;
    11) (cd verify && python3 run_verify.py --pipe --mutate --stop-on-fail) ;;
    12) (cd verify && python3 run_verify.py --pipem --mutate --stop-on-fail) ;;
    13) python3 rvc/mutate_rvc.py "$RT" --spike "$SPIKE" && python3 mul/mutate_mul.py && python3 bpred/mutate_bpred.py ;;
    14) python3 cache/mutate_cache.py "$RT" --spike "$SPIKE" ;;
    15) python3 cosim/irq/run_irq_cosim.py --spike "$SPIKE" ;;
    16) python3 cosim/irq/mutate_irq_cosim.py --spike "$SPIKE" ;;
    17) sh soc/sw/build.sh && sh soc/freertos/build.sh && python3 soc/run_soc.py ;;
    18) sh soc/sw/build.sh && python3 soc/mutate_soc.py --jobs 4 ;;
    19) PATH=$HOME/.local/bin:$PATH bash formal/run.sh run '.' && PATH=$HOME/.local/bin:$PATH CFG=formal/checks_wfi.cfg WORK=/tmp/formal-wfi bash formal/run.sh run '^liveness_ch0$' && PATH=$HOME/.local/bin:$PATH bash formal/stitch/run.sh nomut && PATH=$HOME/.local/bin:$PATH bash formal/cache/run.sh nomut && PATH=$HOME/.local/bin:$PATH CFG=formal/checks_misal.cfg WORK=/tmp/formal-misal bash formal/run.sh run '^insn_(lb|lbu|lh|lhu|lw|sb|sh|sw)_ch0$' '^mon_misal_ch0$' ;;
    20) PATH=$HOME/.local/bin:$PATH bash formal/mutate.sh && PATH=$HOME/.local/bin:$PATH bash formal/stitch/run.sh && PATH=$HOME/.local/bin:$PATH bash formal/cache/run.sh ;;
    21) python3 zb/mutate_zb.py ;;
    22) python3 cosim/run_random.py --n 8 --seed0 1000 --jobs 2 --spike "$SPIKE" && python3 cosim/run_directed.py --spike "$SPIKE" ;;
    23) python3 cosim/mutate_random.py --n 80 --spike "$SPIKE" ;;
    24) AXI=1 sh soc/sw/build.sh && AXI=1 sh soc/freertos/build.sh && python3 soc/run_soc.py --axi ;;
    25) AXI=1 sh soc/sw/build.sh && python3 soc/mutate_axi.py --jobs 2 ;;
    26) python3 tage/check_tage.py --spike "$SPIKE" ;;
    27) python3 tage/mutate_tage.py --spike "$SPIKE" ;;
    *) echo "khong co buoc $1"; return 1 ;;
    esac
}

case "${1:-nhanh}" in
    nhanh)   STEPS="1 2 3 4 5 6 7 8 9 15 17 19 22 24 26" ;;
    dot-bien) STEPS="10 11 12 13 14 16 18 20 21 23 25 27" ;;
    tat-ca)  STEPS="1 2 3 4 5 6 7 8 9 15 17 19 22 24 26 10 11 12 13 14 16 18 20 21 23 25 27" ;;
    *)       STEPS="$*" ;;
esac
n=$(echo $STEPS | wc -w); k=0; t0=$(date +%s)
for s in $STEPS; do
    k=$((k + 1)); ts=$(date +%s)
    printf "[%d/%d] buoc %s: %s ... " $k $n $s "${NAMES[$s]:-?}"
    if step $s > "$LOGDIR/step$s.log" 2>&1; then
        echo "DAT ($(( $(date +%s) - ts )) s) | $(grep -v '^\s*$' "$LOGDIR/step$s.log" | tail -1 | cut -c1-110)"
    else
        echo "THAT BAI ($(( $(date +%s) - ts )) s), log: $LOGDIR/step$s.log"; tail -20 "$LOGDIR/step$s.log"; exit 1
    fi
done
echo "REGRESSION DAT: buoc $STEPS, $(( ($(date +%s) - t0) / 60 )) phut"
