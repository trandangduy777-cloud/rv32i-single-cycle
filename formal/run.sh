#!/bin/bash
# Chay riscv-formal cho pipeline RV32IMC.
#   bash formal/run.sh gen                  # chi sinh cac check (thu muc $WORK/cores/rv32im_pipeline/checks)
#   bash formal/run.sh run <regex>...       # chay cac check co ten khop regex (vd. 'insn_add_ch0' 'reg_ch0')
#   bash formal/run.sh all                  # chay moi check
# Check gap ERROR (loi ha tang, khong phai FAIL) duoc chay lai 1 lan; log lan dau giu o <check>.err1.log.
# Bien: RTL_DIR (thu muc chua RTL, mac dinh repo; dung de chen loi co y vao ban sao), WORK (thu muc lam viec, mac dinh /tmp/formal-work), CFG (mac dinh formal/checks.cfg), JOBS (so tien trinh song song)
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/tmp/formal-work}
CFG=${CFG:-$HERE/formal/checks.cfg}
JOBS=${JOBS:-$(nproc)}
RF_SHA=c992aa61fdfe0846c5ed90324c596202a1c69b76          # YosysHQ/riscv-formal, ghim phien ban (cung ban voi CI)
mkdir -p "$WORK"
if [ ! -d "$WORK/riscv-formal/.git" ]; then
    git clone -q https://github.com/YosysHQ/riscv-formal.git "$WORK/riscv-formal"
    git -C "$WORK/riscv-formal" checkout -q $RF_SHA
fi
CORE=$WORK/riscv-formal/cores/rv32im_pipeline
mkdir -p "$CORE"
cp "$CFG" "$CORE/checks.cfg"
RTL_DIR=${RTL_DIR:-$HERE}
for f in formal/wrapper.sv rv32im_pipeline.v rv32i_core.v rv32c_decompress.v; do cp "$RTL_DIR/$f" "$CORE/$(basename $f)"; done
cmd=${1:-gen}; shift || true
cd "$CORE"
python3 ../../checks/genchecks.py > gen.log 2>&1 || { cat gen.log; exit 1; }
tail -1 gen.log
# yosys WASM (YoWASP) chi thay thu muc hien tai: dua RTL vao muc [files] cua sby va doc bang ten file
python3 - <<'PY'
import glob, re
rtl = ["wrapper.sv", "rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"]
for f in glob.glob("checks/*.sby"):
    s = open(f).read()
    s = re.sub(r"[^ \n]*/cores/rv32im_pipeline/(wrapper\.sv|rv32im_pipeline\.v|rv32i_core\.v|rv32c_decompress\.v)", r"\1", s)
    s = s.replace("[files]\n", "[files]\n" + "".join("../%s\n" % r for r in rtl), 1)
    open(f, "w").write(s)
PY
case $cmd in
    gen) ;;
    run)
        for pat in "$@"; do
            ls checks/*.sby | sed 's|checks/||; s|\.sby$||' | grep -E "$pat" 
        done | sort -u > "$WORK/selected.txt"
        echo "$(wc -l < "$WORK/selected.txt") check duoc chon"
        ( cd checks && xargs -P "$JOBS" -I{} sh -c 'ts=$(date +%s); sby -f {}.sby > {}.log 2>&1; rc=$?; \
            if grep -q "DONE (ERROR" {}.log; then cp {}.log {}.err1.log; sby -f {}.sby > {}.log 2>&1; fi; \
            st=$(grep -E "DONE \(" {}.log | tail -1 | sed "s/.*DONE (\(.*\)).*/\1/"); \
            echo "{}: $st ($(( $(date +%s) - ts )) s)"' < "$WORK/selected.txt" ) | tee "$WORK/results.txt"
        ! grep -v "PASS" "$WORK/results.txt" | grep -q . ;;      # ma thoat khac 0 neu co check khong PASS
    all) bash "$HERE/formal/run.sh" run '.' ;;
esac
