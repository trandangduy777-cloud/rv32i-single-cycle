#!/bin/bash
# Regression day du cua repo, chia thanh cac buoc de chay tung phan (moi buoc in mot dong ket qua, log o $LOGDIR).
# Dung (tu thu muc goc repo):
#   bash tools/regress.sh                 # nhom "nhanh" (buoc 0-9, 15, 17, 19, 22, 24, 26, 28-30, 32, 34; khoang 2 gio)
#   bash tools/regress.sh dot-bien        # nhom mutation (buoc 0, 10-14, 16, 18, 20, 21, 23, 25, 27, 31, 33, 35 = coverage S/U + MMU + PMP + TAGE, ~1 gio; vai gio)
#   bash tools/regress.sh tat-ca          # ca hai nhom, tuan tu
#   bash tools/regress.sh may-2-nhan      # ca hai nhom, 2 hang chay song song (A: mo phong / SoC / Spike, B: so vet ngat,
#                                         #   mutation ngat, riscv-formal); khong dung o buoc that bai, tong ket o cuoi
#   bash tools/regress.sh 2 7 16b         # chi cac buoc 2, 7 va 16b
# Buoc dai co buoc con de chia lan chay (moi buoc con <= ~90 phut tren may 2 nhan): 13 = 13a-c, 15 = 15a-d (theo cau hinh
# loi), 16 = 16a-d (theo doan --range). Buoc 0: chuoi goc cua moi dot bien xuat hien dung 1 lan, YAML cua CI doc duoc.
# Can moi truong cua tools/setup_env.sh. Thoat ma 1 o buoc dau tien that bai (in 20 dong cuoi cua log buoc do).
set -u
cd "$(dirname "$0")/.."
RT=${RISCV_TESTS:-/tmp/riscv-tests}
SPIKE=${SPIKE:-/opt/spike/bin/spike}
LOGDIR=${LOGDIR:-/tmp/regress_logs}
mkdir -p "$LOGDIR"

NAMES=("kiem chuoi goc dot bien + YAML CI" "testbench tu kiem tra 3 loi" "so vet voi ISS, 15 cau hinh" "bo nhan: thu het W <= 10, W = 33" \
       "chung minh hinh thuc bo nhan" "ngat + mutation ngat" "giai nen lenh C" "riscv-tests" \
       "bench, du doan nhanh dung tung chu ky, CoreMark 1 vong" "so vet voi Spike (17 loi)" \
       "mutation single-cycle" "mutation pipeline RV32I" "mutation pipeline RV32IM" "mutation lenh C, bo nhan, du doan nhanh" \
       "mutation cache" "so vet voi Spike khi co ngat" "mutation ngat qua so vet Spike" \
       "SoC: bus, UART, GPIO, timer, chuong trinh C" "mutation SoC (152 mutant)" \
       "riscv-formal: moi check RVFI" "riscv-formal: dot bien co y" "mutation Zba/Zbb/Zbs/Zbc/Zicond" \
       "so vet ngau nhien voi Spike (22 loi, 8 chuong trinh moi loi) + test co huong csr_mie" "mutation so vet ngau nhien (16 dot bien)" \
       "SoC AXI4 + DMA: interconnect ngau nhien, giao thuc, chuong trinh C, DMA, FreeRTOS" "mutation AXI4 + DMA (55 mutant)" \
       "TAGE: so tung du doan voi mo hinh tham chieu (35 vet, 4 cau hinh)" "mutation TAGE (28 dot bien)" \
       "Verilator lint -Wall (13 muc tieu, cac mien tru co giai thich)" "so vet voi Spike bang Verilator (riscv-tests, bench, CoreMark; trace phai khop iverilog)" \
       "SVA bind (bo phan xu, cache, pipeline) tren RTL sach" "mutation SVA (25 dot bien, moi nhom assertion phai bat duoc)" \
       "cocotb: cache du lieu + he thong bo nho, scoreboard + functional coverage" "mutation cocotb (12 dot bien, khong co SVA ho tro)" \
       "Verilator --coverage cua pipeline (loi RV32IMC: riscv-tests + bench + CoreMark)")

# Thoi gian do 26/11/2026 tren may 2 nhan, moi loi chay mot minh (run_irq_cosim.py --core N): loi 0: 13 phut, 1: 46, 2: 15,
# 3: 5, 4: 48, 5: 49, 6: 17, 7: 4, 8: 64 -> 15a = 8 (64), 15b = 1 3 (51), 15c = 6 7 4 (69), 15d = 0 2 5 (77).
# loi 9 (MMU + lech phan cung + cache, them 27/11): 62 phut, chay rieng o 15e. Doi nhom bang bien IRQ_CORES_A..E neu them loi. Buoc 16 (mutate_irq_cosim.py, 117 dot bien): CI do 0:14 = 17-23 phut, 14:21 ~ 17-25,
# 21:28 ~ 22-32, 28:42 = 22, 42: = 10 (may 2 nhan cham hon khoang 1,5 lan).
declare -A SUBNAMES=(
    [13a]="mutation lenh C (so vet Spike)" [13b]="mutation bo nhan song song" [13c]="mutation du doan nhanh"
    [15a]="so vet ngat voi Spike: loi ${IRQ_CORES_A:-8}" [15b]="so vet ngat voi Spike: loi ${IRQ_CORES_B:-1 3}"
    [15c]="so vet ngat voi Spike: loi ${IRQ_CORES_C:-6 7 4}" [15d]="so vet ngat voi Spike: loi ${IRQ_CORES_D:-0 2 5}"
    [15e]="so vet ngat voi Spike: loi ${IRQ_CORES_E:-9}"
    [16a]="mutation ngat qua Spike, doan 0:14" [16b]="mutation ngat qua Spike, doan 14:21"
    [16c]="mutation ngat qua Spike, doan 21:42" [16d]="mutation ngat qua Spike, doan 42:")
name_of() { if [ -n "${SUBNAMES[$1]+x}" ]; then echo "${SUBNAMES[$1]}"; else echo "${NAMES[$1]:-?}"; fi; }
irq_cores() { for c in $1; do python3 cosim/irq/run_irq_cosim.py --spike "$SPIKE" --core "$c" || return 1; done; }

step() {   # step <so>: chay buoc, tra ve 0 neu dat
    case $1 in
    0) python3 tools/check_mutants.py &&
       if python3 -c "import yaml" 2>/dev/null; then
           python3 -c "import sys, yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]; print('YAML CI: doc duoc', len(sys.argv) - 1, 'file')" .github/workflows/*.yml
       else echo "YAML CI: bo qua (khong co PyYAML)"; fi ;;
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
    13) step 13a && step 13b && step 13c ;;
    13a) python3 rvc/mutate_rvc.py "$RT" --spike "$SPIKE" ;;
    13b) python3 mul/mutate_mul.py ;;
    13c) python3 bpred/mutate_bpred.py ;;
    14) python3 cache/mutate_cache.py "$RT" --spike "$SPIKE" ;;
    15) step 15a && step 15b && step 15c && step 15d && step 15e ;;
    15a) irq_cores "${IRQ_CORES_A:-8}" ;;
    15b) irq_cores "${IRQ_CORES_B:-1 3}" ;;
    15c) irq_cores "${IRQ_CORES_C:-6 7 4}" ;;
    15d) irq_cores "${IRQ_CORES_D:-0 2 5}" ;;
    15e) irq_cores "${IRQ_CORES_E:-9}" ;;
    16) step 16a && step 16b && step 16c && step 16d ;;
    16a) python3 cosim/irq/mutate_irq_cosim.py --spike "$SPIKE" --range 0:14 ;;
    16b) python3 cosim/irq/mutate_irq_cosim.py --spike "$SPIKE" --range 14:21 ;;
    16c) python3 cosim/irq/mutate_irq_cosim.py --spike "$SPIKE" --range 21:42 ;;
    16d) python3 cosim/irq/mutate_irq_cosim.py --spike "$SPIKE" --range 42: ;;
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
    28) python3 verilator/lint.py ;;
    29) python3 verilator/run_vlcosim.py cosim "$RT" --spike "$SPIKE" --core "RV32IMC + cache 2x2" && python3 verilator/run_vlcosim.py random --n 4 --seed0 1000 --idx 3 4 ;;
    30) python3 verilator/run_sva.py --n 3 ;;
    31) python3 verilator/mutate_sva.py --jobs 2 ;;
    32) python3 verilator/run_cocotb.py --seeds 3 --nops 2000 ;;
    33) python3 verilator/mutate_cocotb.py ;;
    35) rm -rf /tmp/plcov_p && python3 verilator/run_plcov.py run-priv --dat /tmp/plcov_p --riscv-tests "$RT" --no-coremark && python3 verilator/run_plcov.py merge --dat /tmp/plcov_p --extra-dat $(ls /tmp/plcov_r/core*.dat 2>/dev/null) --report /tmp/plcov_p/pipeline.txt ;;
    34) rm -rf /tmp/plcov_r && python3 verilator/run_plcov.py run --dat /tmp/plcov_r --cores 3 --riscv-tests "$RT" --spike "$SPIKE" && python3 verilator/run_plcov.py merge --dat /tmp/plcov_r --report /tmp/plcov_r/pipeline.txt ;;
    *) echo "khong co buoc $1"; return 1 ;;
    esac
}

run_one() {   # run_one <buoc> <tien to>: chay 1 buoc, in DUNG 1 dong ket qua (in mot lan de 2 hang khong xen dong)
    local s=$1 ts=$(date +%s) line
    if step "$s" > "$LOGDIR/step$s.log" 2>&1; then
        line="$2buoc $s: $(name_of "$s") ... DAT ($(( $(date +%s) - ts )) s) | $(grep -v '^\s*$' "$LOGDIR/step$s.log" | tail -1 | cut -c1-110)"
        printf '%s\n' "$line"; return 0
    fi
    line="$2buoc $s: $(name_of "$s") ... THAT BAI ($(( $(date +%s) - ts )) s), log: $LOGDIR/step$s.log"
    printf '%s\n' "$line"; return 1
}

QA="0 1 2 3 4 5 6 7 8 9 10 11 12 13a 13b 13c 14 17 18 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35"   # cac buoc dung chung thu muc build (bench, soc/sw) o cung hang
QB="15a 15b 15c 15d 15e 16a 16b 16c 16d 19 20"                               # 20 can riscv-formal do 19 dung, nen di sau 19
case "${1:-nhanh}" in
    nhanh)   STEPS="0 1 2 3 4 5 6 7 8 9 15 17 19 22 24 26 28 29 30 32 34" ;;
    dot-bien) STEPS="0 10 11 12 13 14 16 18 20 21 23 25 27 31 33 35" ;;
    tat-ca)  STEPS="0 1 2 3 4 5 6 7 8 9 15 17 19 22 24 26 28 29 30 32 34 10 11 12 13 14 16 18 20 21 23 25 27 31 33 35" ;;
    may-2-nhan)
        t0=$(date +%s); fails="$LOGDIR/fails"; : > "$fails"
        # ma nguon CoreMark (coremark/eembc) duoc ca buoc 8 (hang A) va 15 (hang B) tu clone khi chua co: lay truoc mot lan,
        # neu khong hai hang clone cung luc va mot ben bien dich tren thu muc dang clone do (gap 26/11/2026)
        (cd coremark && python3 -c "import run_coremark as c; c.fetch_src()") || exit 1
        queue() { local q=$1 k=0 n; shift; n=$#; for s; do k=$((k + 1)); run_one "$s" "[$q $k/$n] " || echo "$s" >> "$fails"; done; }
        queue A $QA & queue B $QB & wait
        if [ -s "$fails" ]; then echo "REGRESSION THAT BAI o buoc: $(tr '\n' ' ' < "$fails")($(( ($(date +%s) - t0) / 60 )) phut)"; exit 1; fi
        echo "REGRESSION DAT: $(echo $QA $QB | wc -w) buoc tren 2 hang, $(( ($(date +%s) - t0) / 60 )) phut"; exit 0 ;;
    *)       STEPS="$*" ;;
esac
n=$(echo $STEPS | wc -w); k=0; t0=$(date +%s)
for s in $STEPS; do
    k=$((k + 1))
    run_one "$s" "[$k/$n] " || { tail -20 "$LOGDIR/step$s.log"; exit 1; }
done
echo "REGRESSION DAT: buoc $STEPS, $(( ($(date +%s) - t0) / 60 )) phut"
