#!/bin/bash
# Chay riscv-formal cho pipeline RV32IMC.
#   bash formal/run.sh gen                  # chi sinh cac check (thu muc $WORK/cores/rv32im_pipeline/checks)
#   bash formal/run.sh run <regex>...       # chay cac check co ten khop regex (vd. 'insn_add_ch0' 'reg_ch0')
#   bash formal/run.sh all                  # chay moi check
# Check gap ERROR (loi cong cu, khong phai FAIL) duoc in 40 dong cuoi log roi chay lai 1 lan, TUAN TU, sau khi cac
# check khac xong; log lan dau giu o <check>.err1.log. Ket qua cuoi ghi "(chay lai tuan tu)" de khong bi che giau.
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
cp "$HERE/formal/rvfi_csrw_check.sv" "$WORK/riscv-formal/checks/rvfi_csrw_check.sv"   # ban sua: CSR ghi mot phan
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
        # Chay yosys mot lan truoc khi chay song song: YoWASP bien dich module WASM vao ~/.cache/YoWASP o lan dau,
        # nhieu tien trinh cung bien dich mot luc la nguon loi ERROR khong lap lai duoc.
        yosys -q -p 'help' > /dev/null 2>&1 || true
        one='ts=$(date +%s); sby -f {}.sby > {}.log 2>&1; \
            st=$(grep -E "DONE \(" {}.log | tail -1 | sed "s/.*DONE (\(.*\)).*/\1/"); \
            echo "{}: ${st:-KHONG CO KET QUA} ($(( $(date +%s) - ts )) s)"'
        ( cd checks && xargs -P "$JOBS" -I{} sh -c "$one" < "$WORK/selected.txt" ) | tee "$WORK/results.txt"
        # Check ERROR / khong co ket qua (loi cong cu, KHONG phai FAIL): in log de thay nguyen nhan, roi chay lai
        # TUAN TU sau khi moi check khac da xong (khong con tranh tai nguyen). FAIL khong bao gio duoc chay lai.
        retry=$(grep -vE ": (PASS|FAIL)" "$WORK/results.txt" | cut -d: -f1 || true)
        for c in $retry; do
            echo "=== $c loi cong cu, 40 dong cuoi log lan 1 (giu o checks/$c.err1.log) ==="
            cp "checks/$c.log" "checks/$c.err1.log"; tail -40 "checks/$c.err1.log"
            r=$( cd checks && echo "$c" | xargs -I{} sh -c "$one" )
            echo "$r (chay lai tuan tu)"
            sed -i "s|^$c: .*|$r (chay lai tuan tu)|" "$WORK/results.txt"
        done
        ! grep -v ": PASS" "$WORK/results.txt" | grep -q . ;;      # ma thoat khac 0 neu co check khong PASS
    all) bash "$HERE/formal/run.sh" run '.' ;;
esac
