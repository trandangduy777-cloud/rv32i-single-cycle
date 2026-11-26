#!/usr/bin/env python3
"""Chay cac assertion SVA (verilator/sva/*.sv, bind khong sua RTL) bang Verilator --assert --coverage-user tren 3 loai tai:
  cache   cache/tb_cache_random.v, 5 cau hinh (kich thuoc, so duong, bo dem ghi)       -> sva_arbiter, sva_dcache, sva_icache
  core    cosim/tb_cosim.v + chuong trinh ngau nhien cua cosim/gen_rand.py (loi co cache) -> them sva_pipeline
  irq     irq/tb_irq.v (ngat timer / ngoai / phan mem)                                  -> sva_pipeline (ngat khong mat)
Moi assertion bao loi phai dung ngay (Verilator $error); bao cao: so lan chay, thong ke gioi han (cho lau nhat), va cover point (khong rong).
Dung: python3 verilator/run_sva.py [--n 6] [--groups cache core irq] [--json out.json]
Bien moi truong RV_ROOT: thu muc chua RTL (cho mutate_sva.py); file SVA luon lay tu repo."""
import argparse, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = os.environ.get("RV_ROOT") or REPO
sys.path.insert(0, os.path.join(REPO, "cosim"))
import run_cosim as rc            # noqa: E402
import run_random as rr           # noqa: E402
import gen_rand                   # noqa: E402

SVA = {k: os.path.join(HERE, "sva", f"sva_{k}.sv") for k in ("arbiter", "dcache", "icache", "pipeline")}
CACHE_CFGS = [["-DL=4", "-DW=2"], ["-DL=2", "-DW=8"], ["-DL=16", "-DW=4", "-DQ=2"], ["-DL=8", "-DW=2", "-DWY=2"], ["-DL=4", "-DW=2", "-DWY=4"]]
CORE_CFGS = [3, 4, 5, 7, 16]                  # chi so trong run_random.ALL_CORES (khong cache / cache 16x4 / 2x2 / 4 duong / bo dem ghi 1)
CACHE_SVA = ["arbiter", "dcache", "icache"]
FAIL_RE = re.compile(r"SVA (\w+)")
COV_RE = re.compile(r"^C '(.*)' (\d+)$")


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def build(top, srcs, defs, tmp, name):
    mdir = os.path.join(tmp, name)
    cmd = ["verilator", "--cc", "--exe", "--build", "--timing", "--assert", "--coverage-user", "-Wno-fatal", "-Wno-lint", "-Wno-style",
           "-DNO_VCD", "--top-module", top, "-Mdir", mdir, "-j", "2", "-CFLAGS", f'-DVTOP=V{top} -DVTOPH=\\"V{top}.h\\" -O1', "-o", "Vsim",
           os.path.join(HERE, "vl_main_top.cpp")] + defs + srcs
    r = sh(cmd)
    if r.returncode:
        print(r.stdout[-1500:], r.stderr[-1500:])
        sys.exit(2)
    return os.path.join(mdir, "Vsim")


def run(exe, args, tmp, tag):
    wd = os.path.join(tmp, "wd_" + tag)
    os.makedirs(wd, exist_ok=True)
    r = sh([exe] + args, cwd=wd, timeout=900)
    out = r.stdout + r.stderr
    cov = {}
    p = os.path.join(wd, "coverage.dat")
    if os.path.exists(p):
        for l in open(p, errors="replace"):
            m = COV_RE.match(l.rstrip("\n"))
            if m and "v_user" in m.group(1):
                f = dict(x.split("\x02", 1) for x in m.group(1).split("\x01") if "\x02" in x)
                cov[(f.get("f", "?"), int(f.get("l", 0)))] = int(m.group(2))
    return r.returncode, out, cov


def gen_programs(idx, n, seed0, tmp):
    title, flag, files, arch, *plus = rr.ALL_CORES[idx]
    hexes = []
    for k in range(n):
        seed = seed0 + k
        prof, caps = rr.profile_of(idx, seed)
        g = gen_rand.Gen(seed, prof["units"], c=prof["c"], m=prof["m"], csr=prof["csr"], ma=prof["ma"], fencei=prof["fencei"],
                         core_c=prof["core_c"], zb=prof["zb"])
        src = os.path.join(tmp, f"g{idx}_{k}.S")
        open(src, "w").write(g.build())
        march = "rv32i" + ("m" if prof["m"] else "") + ("c" if prof["c"] else "") + "_zicsr_zifencei" + ("_zba_zbb_zbc_zbs_zicond" if prof["zb"] else "")
        elf = rr.build_elf(src, march, tmp, f"g{idx}_{k}")
        if isinstance(elf, tuple):
            continue
        h = os.path.join(tmp, f"g{idx}_{k}.hex")
        rc.to_hex(elf, h)
        hexes.append(h)
    return hexes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=6, help="so chuong trinh ngau nhien moi cau hinh core; so seed moi cau hinh cache")
    ap.add_argument("--groups", nargs="+", default=["cache", "core", "irq"], choices=["cache", "core", "irq"])
    ap.add_argument("--cache-cfgs", type=int, nargs="+", default=list(range(len(CACHE_CFGS))))
    ap.add_argument("--core-cfgs", type=int, nargs="+", default=CORE_CFGS)
    ap.add_argument("--seed0", type=int, default=31000)
    ap.add_argument("--stop-on-fail", action="store_true")
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="sva_")
    R = lambda *f: [os.path.join(ROOT, x) for x in f]
    fails, cov, stats, runs = {}, {}, [], 0

    def account(tag, rcode, out, c):
        nonlocal runs
        runs += 1
        for k, v in c.items():
            cov[k] = cov.get(k, 0) + v
        stats.extend(l for l in out.splitlines() if l.startswith("SVA_STAT"))
        names = FAIL_RE.findall(out)
        if names or "Assertion failed" in out:
            fails.setdefault(names[0] if names else "?", []).append(tag)
            print(f"  LOI [{tag}] assertion: {', '.join(sorted(set(names))) or '?'}")
            return True
        if os.environ.get("SVA_ONLY") and "FAIL" in out and rcode == 0:
            return False                      # scoreboard cua tb that bai nhung khong assertion nao ban: khong tinh la SVA bat duoc (xem mutate_sva)
        if rcode != 0 or ("PASS" not in out and "DONE" not in out):
            fails.setdefault("KHONG_KET_THUC", []).append(tag)
            print(f"  LOI [{tag}] khong ket thuc dung (ma {rcode}): {out[-200:]}")
            return True
        return False

    if "cache" in a.groups:
        for ci in a.cache_cfgs:
            cfg = CACHE_CFGS[ci]
            # tb_cache_random dung $urandom(seed): iverilog cap nhat bien seed moi lan goi, Verilator thi khong (moi lan cung mot so),
            # nen ban sao trong thu muc tam doi thanh $urandom (Verilator tu cap so ngau nhien, hat giong qua +verilator+seed+N)
            tbc = os.path.join(tmp, "tb_cache_random.v")
            tbt = open(os.path.join(REPO, "cache", "tb_cache_random.v")).read().replace("$urandom(seed)", "$urandom")
            if os.environ.get("SVA_ONLY"):
                # do kha nang bat cua RIENG assertion (mutation SVA): tb khong duoc $finish som khi scoreboard cua no that bai
                tbt = re.sub(r'(\$display\("\[CACHE\] FAIL[^;]*;)\s*\$finish;', r'\1', tbt)
            open(tbc, "w").write(tbt)
            exe = build("tb_cache_random", [tbc] + R("rv32_icache.v", "rv32_dcache.v", "rv32_bus_arbiter.v") +
                        [SVA[k] for k in CACHE_SVA], cfg, tmp, f"cache{ci}")
            for s in range(a.n):
                bad = account(f"cache{ci}:seed{s + 1}", *run(exe, [f"+verilator+seed+{s + 1}", "+n=5000", "+lat=6"], tmp, f"c{ci}_{s}"))
                if bad and a.stop_on_fail:
                    break
            print(f"cache cau hinh {cfg}: {a.n} lan chay xong", flush=True)
            if fails and a.stop_on_fail:
                break
    if "core" in a.groups and not (fails and a.stop_on_fail):
        for ci in a.core_cfgs:
            title, flag, files, arch, *plus = rr.ALL_CORES[ci]
            exe = build("tb_cosim", [os.path.join(REPO, "cosim", "tb_cosim.v")] + R(*files) + [SVA[k] for k in (CACHE_SVA + ["pipeline"] if "-DCACHE" in flag else ["pipeline"])],
                        flag.split() + ["-DSVA_ARB_FAIRNESS"], tmp, f"core{ci}")
            for k, h in enumerate(gen_programs(ci, a.n, a.seed0, tmp)):
                bad = account(f"core{ci}:prog{k}", *run(exe, [f"+prog={h}", "+quiet", "+tmax=2000000"] + (plus[0] if plus else []), tmp, f"p{ci}_{k}"))
                if bad and a.stop_on_fail:
                    break
            print(f"core [{ci}] {title}: {a.n} chuong trinh xong", flush=True)
            if fails and a.stop_on_fail:
                break
    if "irq" in a.groups and not (fails and a.stop_on_fail):
        exe = build("tb_irq", [os.path.join(REPO, "irq", "tb_irq.v")] + R("rv32im_pipeline.v", "rv32i_core.v", "rv32_mtimer.v") + [SVA["pipeline"]], [], tmp, "irq")
        account("irq", *run(exe, [f"+prog={os.path.join(REPO, 'irq', 'irq_test.hex')}"], tmp, "irq"))
        print("irq: xong", flush=True)

    # cover point khong rong
    zero = sorted(k for k, v in cov.items() if v == 0)
    names = sorted({k[0] for k in cov})
    shutil.rmtree(tmp, ignore_errors=True)
    for f, l in zero:
        txt = open(f, errors="replace").read().splitlines()[l - 1].strip() if os.path.exists(f) else "?"
        print(f"  cover chua toi: {os.path.basename(f)}:{l}  {txt[:110]}")
    # thong ke: gop theo mau cau, lay gia tri lon nhat tung vi tri so (so cuoi cung la gioi han, giu nguyen)
    agg = {}
    for st in stats:
        nums = [int(x) for x in re.findall(r"\d+", st)]
        tmpl = re.sub(r"\d+", "#", st)
        old_n = agg.get(tmpl, [0] * len(nums))
        agg[tmpl] = [max(a_, b_) for a_, b_ in zip(old_n, nums)]
    lines = []
    for tmpl, nums in sorted(agg.items()):
        for v in nums:
            tmpl = tmpl.replace("#", str(v), 1)
        lines.append(tmpl)
        print(tmpl)
    rep = dict(runs=runs, fails=fails, cover_points=len(cov), cover_hit=len(cov) - len(zero), stats=lines)
    print(f"SVA: {runs} lan chay, {'0 assertion that bai' if not fails else 'THAT BAI: ' + ', '.join(sorted(fails))}; cover point {len(cov) - len(zero)}/{len(cov)} da toi")
    if a.json:
        json.dump(rep, open(a.json, "w"), indent=1)
    sys.exit(1 if fails or zero else 0)


if __name__ == "__main__":
    main()
