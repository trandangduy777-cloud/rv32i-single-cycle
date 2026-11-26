#!/usr/bin/env python3
"""Verilator --coverage (dong / nhanh / toggle) cua pipeline khi chay riscv-tests + bench + test tu viet + CoreMark (chinh bo chuong
trinh cua cosim/run_cosim.py, so vet Spike van chay). Moi cau hinh loi chay xong ghi 1 file .dat; sau do gop va bao cao: ti le %,
tung file RTL, danh sach vung CHUA phu (dong/nhanh) theo khoang dong kem noi dung dong.
  python3 verilator/run_plcov.py run   --dat results/vlcov/dat [--cores 1 2 3 ...] [--no-coremark] [--only ...]
  python3 verilator/run_plcov.py merge --dat results/vlcov/dat [--extra-dat cac file khac] [--report results/vlcov/pipeline.txt]
Chia nho de khong bi gioi han 30 phut cua tac vu nen: chay `run` nhieu lan voi --cores khac nhau, cuoi cung `merge`."""
import argparse, collections, glob, os, subprocess, sys, tempfile

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
    ap.add_argument("mode", choices=["run", "merge"])
    ap.add_argument("--dat", default=os.path.join(ROOT, "results", "vlcov", "dat"))
    ap.add_argument("--riscv-tests", dest="riscv_tests", default="/tmp/riscv-tests")
    ap.add_argument("--cores", type=int, nargs="*")
    ap.add_argument("--no-coremark", action="store_true")
    ap.add_argument("--spike", default="")
    ap.add_argument("--only", default="")
    ap.add_argument("--extra-dat", nargs="*", default=[])
    ap.add_argument("--report", default=os.path.join(ROOT, "results", "vlcov", "pipeline.txt"))
    ap.add_argument("--annotate", default="")
    a = ap.parse_args()
    (do_run if a.mode == "run" else do_merge)(a)


if __name__ == "__main__":
    main()
