#!/usr/bin/env python3
"""So rv32_tage.v (qua tage/tb_tage.v) voi mo hinh tham chieu tage/tage_model.py tung du doan, tren:
  - vet nhanh that tu Spike: bench, bench_m, bench_call, bench_corr, CoreMark (tage/gen_trace.py)
  - vet tong hop ngau nhien (it pc, huong lech / tuan hoan / ngau nhien) de ep cap phat that bai va lao hoa u
voi nhieu cau hinh (so bang, do rong chi so / tag, do dai lich su, chu ky lao hoa ngan).
Dung (tu thu muc goc repo): python3 tage/check_tage.py [--quick] [--spike SPIKE]
"""
import os, random, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import gen_trace  # noqa: E402
import tage_model  # noqa: E402

# (NT, IB, TB, BB, RST_LOG, HL)
CFGS = [(4, 6, 8, 7, 11, (4, 8, 16, 32)),
        (3, 5, 7, 6, 6, (5, 12, 24)),
        (2, 4, 5, 4, 4, (3, 9)),
        (5, 7, 9, 8, 8, (2, 5, 11, 23, 47))]


def synth(path, seed, n=6000):
    r = random.Random(seed)
    pcs = [0x80000000 + 2 * r.randrange(0, 4096) for _ in range(r.choice((4, 16, 64)))]
    kinds = [r.choice(("bias", "per", "rand", "corr")) for _ in pcs]
    per = [r.randrange(2, 20) for _ in pcs]
    last = 0
    with open(path, "w") as f:
        for i in range(n):
            j = r.randrange(len(pcs))
            k = kinds[j]
            t = (r.random() < 0.9) if k == "bias" else ((i // 1) % per[j] < per[j] // 2) if k == "per" else \
                (r.random() < 0.5) if k == "rand" else bool(last)
            last = int(t) if k != "corr" else last ^ int(r.random() < 0.1)
            f.write(f"{pcs[j]:08x} {int(t)}\n")


def run_cfg(cfg, traces, tmp, rtl=os.path.join(ROOT, "rv32_tage.v"), stop=False, quiet=False):
    nt, ib, tb, bb, rl, hl = cfg
    hlv = "{" + ", ".join(f"8'd{x}" for x in reversed(hl)) + "}"
    vvp = os.path.join(tmp, f"t{nt}_{ib}.vvp")
    subprocess.run(["iverilog", "-g2012", "-o", vvp, f"-DNT={nt}", f"-DIB={ib}", f"-DTB={tb}", f"-DBB={bb}",
                    f"-DRSTLOG={rl}", f"-DHLV={hlv}", os.path.join(HERE, "tb_tage.v"), rtl], check=True,
                   capture_output=True)
    bad = 0
    for tr in traces:
        out = subprocess.run(["vvp", "-n", vvp, f"+trace={tr}"], capture_output=True, text=True).stdout.split("\n")
        got = [int(l[2:]) for l in out if l.startswith("P ")]
        m = tage_model.Tage(nt, ib, tb, bb, 1, hl, rl)
        ref = []
        for line in open(tr):
            pc, t = line.split()
            p, meta = m.predict(int(pc, 16))
            ref.append(int(p))
            m.update(t == "1", meta)
            m.history(t == "1")
        miss = sum(1 for line, p in zip(open(tr), ref) if int(line.split()[1]) != p)
        first = next((i for i, (a, b) in enumerate(zip(got, ref)) if a != b), None)
        ok = len(got) == len(ref) and first is None
        bad += not ok
        if not quiet:
            print(f"  NT={nt} IB={ib} TB={tb} BB={bb} RST={rl} HL={hl} {os.path.basename(tr)}: {len(ref)} nhanh, "
                  f"doan sai {miss} ({100 * miss / max(len(ref), 1):.1f} %): " +
                  ("KHOP" if ok else f"LECH (nhanh thu {first if first is not None else min(len(got), len(ref))})"),
                  flush=True)
        if stop and bad:
            break
    return bad


def main():
    quick = "--quick" in sys.argv
    spike = sys.argv[sys.argv.index("--spike") + 1] if "--spike" in sys.argv else "/opt/spike/bin/spike"
    tmp = tempfile.mkdtemp(prefix="tc_")
    real = []
    for name, elf, isa in gen_trace.progs(tmp, 1):
        if quick and name == "coremark":
            continue
        p = os.path.join(tmp, name + ".trace")
        gen_trace.trace(spike, elf, isa, p)
        real.append(p)
    syn = []
    for s in range(2 if quick else 6):
        p = os.path.join(tmp, f"synth{s}.trace")
        synth(p, s)
        syn.append(p)
    bad = 0
    for k, cfg in enumerate(CFGS[:2] if quick else CFGS):
        bad += run_cfg(cfg, (real if k == 0 else real[:2]) + syn, tmp)
    print("TAGE: " + ("RTL khop mo hinh tren moi vet" if not bad else f"{bad} vet LECH"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
