#!/usr/bin/env python3
"""Tao vet nhanh co dieu kien (moi dong "pc_hex taken") tu log commit cua Spike cho cac chuong trinh: bench, bench_m,
bench_call, CoreMark (ITER vong) va bench_corr (nhanh tuong quan, xem bench/bench_corr.c).
Dung: python3 tage/gen_trace.py <thu_muc_ra> [--spike SPIKE] [--cm-iter N]
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "cosim"))
sys.path.insert(0, os.path.join(ROOT, "coremark"))
import run_cosim as rc  # noqa: E402

LINE = re.compile(r"core\s+\d+:\s+3\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)")


def is_branch(ins):
    if ins & 3 == 3:
        return ins & 0x7F == 0x63
    return (ins & 3) == 1 and ((ins >> 13) & 7) in (6, 7)          # c.beqz / c.bnez


def trace(spike, elf, isa, out):
    log = elf[:-4] + ".tlog"
    subprocess.run([spike, f"--isa={isa}", "--no-dm", f"-m0x{rc.BASE:x}:0x200000", "-l", "--log-commits",
                    f"--log={log}", elf], check=True, timeout=600, capture_output=True)
    seq = []
    for l in open(log):
        m = LINE.match(l)
        if m:
            pc = int(m.group(1), 16)
            if pc >= rc.BASE:
                seq.append((pc, int(m.group(2), 16)))
    n = 0
    with open(out, "w") as f:
        for (pc, ins), (npc, _) in zip(seq, seq[1:]):
            if is_branch(ins):
                ln = 4 if ins & 3 == 3 else 2
                f.write(f"{pc:08x} {int(npc != pc + ln)}\n")
                n += 1
    os.remove(log)
    return n


def progs(tmp, cm_iter):
    """-> [(ten, elf, isa)] dat o BASE nhu run_cosim (bench_corr dung chung bench.ld / crt0 nen phai doi BASE)"""
    out = []
    for n, m in (("bench", "rv32ic"), ("bench_m", "rv32imc"), ("bench_call", "rv32ic"), ("bench_corr", "rv32ic")):
        _, elf = rc.build_bench(n, m, tmp)
        out.append((n, elf, m + "_zicsr"))
    import run_coremark as cm  # noqa: E402
    cm.fetch_src()
    elf, _ = cm.build("rv32imc", cm_iter, tmp)
    out.append(("coremark", elf, "rv32imc_zicsr"))
    return out


def main():
    a = sys.argv[1:]
    outd = a[0]
    spike = a[a.index("--spike") + 1] if "--spike" in a else "/opt/spike/bin/spike"
    cm_iter = int(a[a.index("--cm-iter") + 1]) if "--cm-iter" in a else 2
    os.makedirs(outd, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="tg_")
    for name, elf, isa in progs(tmp, cm_iter):
        n = trace(spike, elf, isa, os.path.join(outd, name + ".trace"))
        print(f"{name}: {n} nhanh")


if __name__ == "__main__":
    main()
