#!/usr/bin/env python3
"""Verilator --coverage (dong / nhanh / toggle) cua pipeline khi chay riscv-tests + bench + test tu viet + CoreMark (chinh bo chuong
trinh cua cosim/run_cosim.py, so vet Spike van chay). Moi cau hinh loi chay xong ghi 1 file .dat; sau do gop va bao cao: ti le %,
tung file RTL, danh sach vung CHUA phu (dong/nhanh) theo khoang dong kem noi dung dong.
  python3 verilator/run_plcov.py run   --dat results/vlcov/dat [--cores 1 2 3 ...] [--no-coremark] [--only ...]
  python3 verilator/run_plcov.py run-priv --dat results/vlcov/dat [--irqext 250] [--no-coremark]   # S/U, MMU Sv32, PMP, TAGE
  python3 verilator/run_plcov.py merge --dat results/vlcov/dat [--extra-dat cac file khac] [--report results/vlcov/pipeline.txt]
Chia nho de khong bi gioi han 30 phut cua tac vu nen: chay `run` nhieu lan voi --cores khac nhau, cuoi cung `merge`."""
import argparse, collections, glob, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "cosim"))
sys.path.insert(0, HERE)
import run_cosim as rc            # noqa: E402
import run_vlcov as vc            # noqa: E402
import vl_shim                    # noqa: E402


def do_run(a):
    idx = a.cores if a.cores else [i for i, c in enumerate(rc.CORES) if c[0] != "single-cycle"]
    allc = list(rc.CORES)
    rc.CORES[:] = [allc[i] for i in idx]
    for k, i in enumerate(idx):                    # ten tep .dat theo thu tu sim<k>: doi sang chi so loi that
        pass
    vl_shim.install([rc], "verilator", covdir=a.dat)
    argv = [sys.argv[0], a.riscv_tests] + (["--spike", a.spike] if a.spike else []) + (["--no-coremark"] if a.no_coremark else []) + (["--only", a.only] if a.only else [])
    sys.argv = argv
    print(f"[plcov] cac loi: {', '.join(str(i) + ':' + allc[i][0] for i in idx)}", flush=True)
    code = 0
    try:
        rc.main()
    except SystemExit as e:
        code = e.code or 0
    # tep .dat ten theo sim<k>.dat (k = vi tri trong danh sach vua chay): doi thanh core<chi so that>.dat
    for k, i in enumerate(idx):
        src = os.path.join(a.dat, f"sim{k}.dat")
        if os.path.exists(src):
            os.replace(src, os.path.join(a.dat, f"core{i}.dat"))
    sys.exit(code)


def do_run_priv(a):
    """Coverage cua phan RTL ma bo chuong trinh M-mode cua run_cosim.py khong cham toi: che do S / U (SU = 1), MMU Sv32, PMP, TAGE.
    Dung lai chuong trinh va cau hinh loi cua cosim/irq/run_irq_cosim.py (su.S, mmu.S, pmp.S, riscv-tests rv32si / rv32mi / rv32ui-v,
    irq_storm, counters, bench duoi bao ngat); chay bang Verilator --coverage voi testbench cosim/tb_cosim.v -DIRQ, khong can Spike
    (so khop voi Spike cua cac chuong trinh nay da co o cosim/irq, buoc 15 cua tools/regress.sh). Ghi core<90+k>.dat."""
    sys.path.insert(0, os.path.join(ROOT, "cosim", "irq"))
    import run_irq_cosim as ic        # noqa: E402
    vl_shim.install([rc], "verilator", covdir=a.dat)
    tmp = tempfile.mkdtemp(prefix="plpriv_")
    progs = [ic.build_storm("rv32imc", tmp) + ("rv32imc",), ic.build_storm("rv32imc", tmp, vec=True) + ("rv32imc",),
             ic.build_counters("rv32imc", tmp) + ("rv32imc",), ic.build_pmp("rv32imc", tmp) + ("rv32imc",),
             ic.build_pmp("rv32imc", tmp, ma=True) + ("rv32imc_zicclsm",),
             ic.build_su("rv32im", tmp) + ("rv32im_xsu",), ic.build_su("rv32imc", tmp) + ("rv32imc_xsu",),
             ic.build_mmu("rv32im", tmp) + ("rv32im_xsu_xmmu",), ic.build_mmu("rv32imc", tmp) + ("rv32imc_xsu_xmmu",),
             ic.build_bench_irq("bench", "rv32ic", tmp) + ("rv32ic",), ic.build_bench_irq("bench_m", "rv32imc", tmp) + ("rv32imc",)]
    rt = a.riscv_tests
    if os.path.isdir(os.path.join(rt, "isa", "rv32si")):
        for suite, t in ic.RT_SU:
            for m in ("rv32im", "rv32imc"):
                progs.append(ic.build_rt_su(rt, suite, t, m, tmp) + (m + "_xsu",))
        for m in ("rv32im", "rv32imc"):
            progs.append(ic.build_rt_su(rt, "rv32si", "dirty", m, tmp) + (m + "_xsu_xmmu",))
        for t in ic.RT_V:
            v = ic.build_rt_v(rt, t, "rv32im", tmp)
            if v:
                progs.append(v + ("rv32im_xsu_xmmu",))
    if not a.no_coremark:
        import run_coremark as cm
        cm.fetch_src()
        progs.append(("coremark-irq-c", cm.build("rv32imc", 1, tmp, crt0=os.path.join(ic.HERE, "crt0_irq.S"), inc=[ic.HERE])[0], "rv32imc"))
    cores = [ic.CORES[0], ic.CORES[1]] + ic.CORES[6:9] + [
        ("RV32IMC + S/U + MMU Sv32 + TAGE", "-DRVC -DSU -DMMUON -DBIGMEM -DTAGEON", ic.PIPE + ["rv32_tage.v"], "rv32imc_xsu_xmmu", []),
        ("RV32IMC + S/U + MMU Sv32 + TAGE + cache 2x2, tre 1-8", "-DRVC -DSU -DMMUON -DBIGMEM -DTAGEON " + ic.C22,
         ic.CACHE + ["rv32_tage.v"], "rv32imc_xsu_xmmu", ["+lat=8", "+irqdly=600"])]
    print(f"[plcov-priv] {len(progs)} chuong trinh x {len(cores)} loi (chi chay chuong trinh hop ISA)", flush=True)
    for k, (title, flags, files, isa, plus) in enumerate(cores):
        if k < a.first_core:
            continue
        vvp = os.path.join(a.dat, f"core{90 + k}.vvp")
        os.makedirs(a.dat, exist_ok=True)
        r = rc.sh(["iverilog", "-g2012", "-o", vvp, "-DPIPE_FULL", "-DIRQ"] + flags.split() +
                  [os.path.join(ROOT, "cosim", "tb_cosim.v")] + [os.path.join(ROOT, f) for f in files])
        if r.returncode:
            sys.exit(f"{title}: bien dich Verilator loi:\n{r.stderr[-1500:]}")
        n = 0
        for name, elf, march in progs:
            if not ic.exts(march) <= ic.exts(isa):     # chuong trinh can ISA / che do ma loi khong co (ke ca xsu, xmmu)
                continue
            binf, hexf = ic.to_bin_hex(elf)
            memw = (1 << 18) if "-DBIGMEM" in flags else (1 << 16)
            L = open(hexf).read().split("\n")
            if len(L) > memw + 1:        # .tohost nam o 0x80100000, ngoai bo nho testbench (iverilog chi canh bao, Verilator bao loi)
                open(hexf, "w").write("\n".join(L[:memw]) + "\n")
            r = rc.sh(["vvp", "-n", vvp, f"+prog={hexf}", f"+irqext={a.irqext}", "+irqseed=1", "+seed=1", f"+tmax={a.tmax}"] + plus)
            m = re.search(r"DONE cycles=(\d+)", r.stdout[-4000:])
            n += 1
            print(f"  [{k + 1}/{len(cores)}] {title}: {name} {'xong ' + m.group(1) + ' chu ky' if m else 'KHONG XONG'}", flush=True)
            if not m:
                sys.exit(1)
        print(f"[plcov-priv] {title}: {n} chuong trinh", flush=True)
    shutil.rmtree(tmp, ignore_errors=True)


def do_merge(a):
    dats = sorted(glob.glob(os.path.join(a.dat, "core*.dat"))) + a.extra_dat
    if not dats:
        print("khong co tep .dat"); sys.exit(1)
    tmp = tempfile.mkdtemp(prefix="plcov_")
    allm = os.path.join(tmp, "all.dat")
    subprocess.run(["verilator_coverage", "-write", allm] + dats, capture_output=True, check=True)
    pts = vc.parse_dat(allm)
    tot = vc.summarize(pts)
    out = [f"Verilator coverage cua pipeline: riscv-tests + bench + test tu viet + CoreMark, gop {len(dats)} tep ({', '.join(os.path.basename(d) for d in dats)})",
           f"TONG: dong {tot['line']['hit']}/{tot['line']['all']} = {tot['line']['pct']:.1f}%, nhanh {tot['branch']['hit']}/{tot['branch']['all']} = "
           f"{tot['branch']['pct']:.1f}%, toggle {tot['toggle']['hit']}/{tot['toggle']['all']} = {tot['toggle']['pct']:.1f}%", ""]
    for f, d in sorted(tot["files"].items()):
        out.append(f"  {f:<22} dong {d['line'][0]:>5}/{d['line'][1]:<5} ({100.0 * d['line'][0] / max(1, d['line'][1]):5.1f}%)  nhanh {d['branch'][0]:>5}/{d['branch'][1]:<5} "
                   f"({100.0 * d['branch'][0] / max(1, d['branch'][1]):5.1f}%)  toggle {d['toggle'][0]:>6}/{d['toggle'][1]:<6} ({100.0 * d['toggle'][0] / max(1, d['toggle'][1]):5.1f}%)")
    unc = collections.defaultdict(set)
    for (f, l, t, k), c in pts.items():
        if c == 0 and t in ("line", "branch") and vc.keep_file(f):
            unc[f].add(l)
    out += ["", "VUNG CHUA PHU (dong hoac nhanh khong bao gio chay), theo khoang dong:"]
    for f in sorted(unc):
        src = {}
        try:
            for n, l in enumerate(open(os.path.join(ROOT, os.path.basename(f)) if not os.path.exists(f) else f, errors="replace"), 1):
                src[n] = l.rstrip()
        except OSError:
            pass
        ls = sorted(unc[f])
        runs, st = [], ls[0]
        for x, y in zip(ls, ls[1:] + [None]):
            if y != x + 1:
                runs.append((st, x))
                st = y
        out.append(f"  {os.path.basename(f)}: {len(ls)} dong, {len(runs)} khoang")
        for a0, b0 in runs:
            out.append(f"    {a0}-{b0}: {src.get(a0, '').strip()[:100]}")
    txt = "\n".join(out) + "\n"
    if a.report:
        os.makedirs(os.path.dirname(a.report), exist_ok=True)
        open(a.report, "w").write(txt)
    print("\n".join(out[:2 + len(tot['files']) + 2]))
    if a.annotate:
        subprocess.run(["verilator_coverage", "--annotate", a.annotate, allm], capture_output=True)
    print(f"bao cao day du: {a.report}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["run", "run-priv", "merge"])
    ap.add_argument("--dat", default=os.path.join(ROOT, "results", "vlcov", "dat"))
    ap.add_argument("--riscv-tests", dest="riscv_tests", default="/tmp/riscv-tests")
    ap.add_argument("--cores", type=int, nargs="*")
    ap.add_argument("--no-coremark", action="store_true")
    ap.add_argument("--spike", default="")
    ap.add_argument("--first-core", type=int, default=0, help="run-priv: bo qua cac loi dau (chia nho tac vu)")
    ap.add_argument("--irqext", type=int, default=250)
    ap.add_argument("--tmax", type=int, default=20_000_000)
    ap.add_argument("--only", default="")
    ap.add_argument("--extra-dat", nargs="*", default=[])
    ap.add_argument("--report", default=os.path.join(ROOT, "results", "vlcov", "pipeline.txt"))
    ap.add_argument("--annotate", default="")
    a = ap.parse_args()
    {"run": do_run, "run-priv": do_run_priv, "merge": do_merge}[a.mode](a)


if __name__ == "__main__":
    main()
