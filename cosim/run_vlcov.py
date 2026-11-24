#!/usr/bin/env python3
"""Code coverage (Verilator --coverage: dong, nhanh, toggle) cua RTL khi chay cac chuong trinh ngau nhien cua cosim/gen_rand.py.
Moi cau hinh loi (chi so cua run_random.ALL_CORES) duoc dung bang Verilator mot lan, chay N chuong trinh (chi RTL, cac chuong
trinh nay da khop Spike trong run_random), gop file coverage, doc lai thanh so lieu theo file / loai. Chi tinh file RTL cua loi,
khong tinh testbench. Dung:  python3 cosim/run_vlcov.py --cores 0 1 3 9 --n 20 [--json out.json] [--list-uncovered]"""
import argparse, collections, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_rand                                   # noqa: E402
import run_cosim as rc                            # noqa: E402
import run_random as rr                           # noqa: E402

ROOT = rr.ROOT
C_RE = re.compile(r"^C '(.*)' (\d+)$")


def parse_dat(path):
    """-> {(file, line, type, comment_key): count}"""
    pts = {}
    for l in open(path, errors="replace"):
        m = C_RE.match(l.rstrip("\n"))
        if not m:
            continue
        key, cnt = m.group(1), int(m.group(2))
        f = dict(p.split("\x02", 1) for p in key.split("\x01") if "\x02" in p)
        typ = f.get("page", "v_?/").split("/")[0][2:]                  # v_line / v_branch / v_toggle
        pts[(f.get("f", "?"), int(f.get("l", 0)), typ, f.get("o", "") + "|" + f.get("h", "") + "|" + f.get("n", "") + "|" + f.get("S", ""))] = cnt
    return pts


def build(i, tmp):
    title, flag, files, arch, *plus = rr.ALL_CORES[i]
    mdir = os.path.join(tmp, f"vl{i}")
    cmd = ["verilator", "--cc", "--exe", "--build", "--timing", os.path.join(HERE, "vl_main.cpp"), "--coverage", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-DNO_VCD",
           "--top-module", "tb_cosim", "-Mdir", mdir] + flag.split() + [os.path.join(HERE, "tb_cosim.v")] + \
          [os.path.join(ROOT, f) for f in files]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-1500:], r.stderr[-1500:]); sys.exit(1)
    return os.path.join(mdir, "Vtb_cosim")


def run_core(i, n, seed0, tmp):
    title, flag, files, arch, *plus = rr.ALL_CORES[i]
    exe = build(i, tmp)
    dats = []
    for k in range(n):
        seed = seed0 + k
        prof, caps = rr.profile_of(i, seed)
        g = gen_rand.Gen(seed, prof["units"], c=prof["c"], m=prof["m"], csr=prof["csr"], ma=prof["ma"],
                         fencei=prof["fencei"], core_c=prof["core_c"], zb=prof["zb"])
        src = os.path.join(tmp, f"p{i}_{k}.S")
        open(src, "w").write(g.build())
        march = "rv32i" + ("m" if prof["m"] else "") + ("c" if prof["c"] else "") + "_zicsr_zifencei" + ("_zba_zbb_zbc_zbs_zicond" if prof["zb"] else "")
        elf = rr.build_elf(src, march, tmp, f"p{i}_{k}")
        if isinstance(elf, tuple):
            print("gcc:", elf[1][:200]); continue
        hexf = os.path.join(tmp, f"p{i}_{k}.hex")
        rc.to_hex(elf, hexf)
        dat = os.path.join(tmp, f"c{i}_{k}.dat")
        args = [exe, f"+prog={hexf}", "+tmax=2000000"] + (plus[0] if plus else [])
        wd = os.path.join(tmp, f"wd{i}_{k}")                     # Verilator 5.020 luon ghi coverage.dat o thu muc chay
        os.makedirs(wd)
        subprocess.run(args, capture_output=True, text=True, timeout=600, cwd=wd)
        if os.path.exists(os.path.join(wd, "coverage.dat")):
            shutil.move(os.path.join(wd, "coverage.dat"), dat)
            dats.append(dat)
    merged = os.path.join(tmp, f"m{i}.dat")
    subprocess.run(["verilator_coverage", "-write", merged] + dats, capture_output=True)
    return merged, len(dats)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cores", type=int, nargs="+", default=[0, 1, 2, 3, 4, 9, 13, 14, 16])
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--seed0", type=int, default=50000)
    ap.add_argument("--json", default="")
    ap.add_argument("--extra-dat", nargs="*", default=[], help="them file coverage.dat da co (vd. tu cosim ngat)")
    ap.add_argument("--list-uncovered", action="store_true")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="vlcov_")
    merged, per_core, runs = [], {}, 0
    for i in a.cores:
        print(f"[core {i}] {rr.ALL_CORES[i][0]}: dung Verilator + chay {a.n} chuong trinh ...", flush=True)
        m, k = run_core(i, a.n, a.seed0, tmp)
        runs += k
        merged.append(m)
        pts = parse_dat(m)
        per_core[i] = summarize(pts)
        print(f"  -> dong {per_core[i]['line']['pct']:.1f}%  nhanh {per_core[i]['branch']['pct']:.1f}%  toggle {per_core[i]['toggle']['pct']:.1f}%  ({k} chuong trinh)", flush=True)
    allm = os.path.join(tmp, "all.dat")
    subprocess.run(["verilator_coverage", "-write", allm] + merged + a.extra_dat, capture_output=True)
    pts = parse_dat(allm)
    tot = summarize(pts)
    print(f"GOP {len(a.cores)} cau hinh, {runs} chuong trinh: dong {tot['line']['hit']}/{tot['line']['all']} = {tot['line']['pct']:.1f}%, "
          f"nhanh {tot['branch']['hit']}/{tot['branch']['all']} = {tot['branch']['pct']:.1f}%, "
          f"toggle {tot['toggle']['hit']}/{tot['toggle']['all']} = {tot['toggle']['pct']:.1f}%")
    for f, d in sorted(tot["files"].items()):
        print(f"  {f:<24} dong {d['line'][0]:>5}/{d['line'][1]:<5} nhanh {d['branch'][0]:>5}/{d['branch'][1]:<5} toggle {d['toggle'][0]:>6}/{d['toggle'][1]:<6}")
    unc = collections.defaultdict(list)
    for (f, l, t, k), c in pts.items():
        if c == 0 and t in ("line", "branch") and keep_file(f):
            unc[os.path.basename(f)].append(l)
    if a.list_uncovered:
        for f, ls in sorted(unc.items()):
            print(f, sorted(set(ls)))
    if a.json:
        json.dump(dict(cores=a.cores, n=a.n, programs=runs, total={k: v for k, v in tot.items() if k != "files"}, files=tot["files"],
                       per_core=per_core, uncovered={f: sorted(set(ls)) for f, ls in unc.items()}), open(a.json, "w"), indent=1)
    shutil.rmtree(tmp, ignore_errors=True)


def keep_file(f):
    b = os.path.basename(f)
    return b.endswith(".v") and not b.startswith("tb_")


def summarize(pts):
    r = {t: dict(hit=0, all=0) for t in ("line", "branch", "toggle")}
    files = collections.defaultdict(lambda: {t: [0, 0] for t in ("line", "branch", "toggle")})
    for (f, l, t, k), c in pts.items():
        if t not in r or not keep_file(f):
            continue
        r[t]["all"] += 1
        files[os.path.basename(f)][t][1] += 1
        if c > 0:
            r[t]["hit"] += 1
            files[os.path.basename(f)][t][0] += 1
    for t in r:
        r[t]["pct"] = 100.0 * r[t]["hit"] / r[t]["all"] if r[t]["all"] else 0.0
    r["files"] = {f: d for f, d in files.items()}
    return r


if __name__ == "__main__":
    main()
