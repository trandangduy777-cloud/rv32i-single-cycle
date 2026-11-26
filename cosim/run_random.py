#!/usr/bin/env python3
"""So tung lenh voi Spike tren hang nghin chuong trinh ngau nhien (muc 9 cua lo trinh).

Moi (loi, seed): sinh chuong trinh assembly bang cosim/gen_rand.py (profile suy ra tu tap lenh cua loi: C, M, CSR + trap,
lech dia chi bang phan cung, FENCE.I), dich bang GCC, chay Spike (--log-commits) va RTL (cosim/tb_cosim.v), so pc, ma lenh,
thanh ghi dich + gia tri, store (dia chi / do rong / gia tri) bang dung cac ham cua run_cosim.py. Dung o lenh lech dau tien
cua tung chuong trinh; chuong trinh lech duoc giu lai trong thu muc --fail-dir (ma .S, vet Spike, vet RTL) de tai hien:
    python3 cosim/run_random.py --core "<ten loi>" --seed0 <seed> --n 1

Dung:  python3 cosim/run_random.py [--n 200] [--seed0 0] [--core <chuoi>] [--jobs 2] [--report cosim/random/report.json]
       [--spike /opt/spike/bin/spike] [--fail-dir /tmp/random_fail] [--cov] [--stop-on-fail]
"""
import argparse, json, multiprocessing as mp, os, random, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("RV_ROOT") or os.path.dirname(HERE)      # RV_ROOT: ban sao RTL (mutation test)
sys.path.insert(0, HERE)
import run_cosim as rc                      # noqa: E402  (CORES, GCC, spike_trace, rtl_trace, compare, exts, to_hex)
import gen_rand                             # noqa: E402

# Cau hinh them ngoai danh sach cua run_cosim.CORES (cung dinh dang: ten, co iverilog, file, arch, [plusargs])
EXTRA_CORES = [
    ("RV32IMC lech phan cung + nhan lap + cache 4x2 2 duong, tre 1-3",
     "-DPIPE_FULL -DRVC -DMA -DMULLAT=0 -DCACHE -DICL=4 -DICW=2 -DDCL=4 -DDCW=2 -DCWY=2", rc.CACHE_FILES,
     "rv32imc_zifencei_zicclsm", ["+lat=3", "+seed=21"]),
    ("RV32IM khong C, cache 8x2 4 duong + bo dem ghi 1 muc, tre 1-6",
     "-DPIPE_FULL -DCACHE -DICL=8 -DICW=2 -DDCL=8 -DDCW=2 -DCWY=4 -DDWB=1", rc.CACHE_FILES, "rv32im_zifencei",
     ["+lat=6", "+seed=23"]),
    ("RV32IMC khong BTB / RAS (BTBN=0, RASN=0)",
     "-DPIPE_FULL -DRVC -DBTBN=0 -DRASN=0", ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"], "rv32imc_zifencei"),
    ("RV32IMC gshare 6 bit + BTB 64 + cache 16x4, tre 1-2",
     "-DPIPE_FULL -DRVC -DGHRB=6 -DBTBN=64 -DRASN=8 -DCACHE", rc.CACHE_FILES, "rv32imc_zifencei", ["+lat=2", "+seed=27"]),    ("RV32IMC TAGE + BTB 64 + cache 4x2 2 duong, tre 1-5",
     "-DPIPE_FULL -DRVC -DTAGEON -DBTBN=64 -DRASN=8 -DCACHE -DICL=4 -DICW=2 -DDCL=4 -DDCW=2 -DCWY=2",
     rc.CACHE_FILES + ["rv32_tage.v"], "rv32imc_zifencei", ["+lat=5", "+seed=29"]),
]
# cac loi co A (-DSKIP_TRAPPED) khong in lenh bi trap; run_random can RTL bao lenh do, nen bo ra (loi A duoc kiem trong run_cosim.py)
# cac loi TAGE them sau vao run_cosim.CORES dat cuoi danh sach de chi so cu (--core, run_vlcov, run_directed) khong doi
ALL_CORES = ([c for c in rc.CORES if "TAGE" not in c[0] and "SKIP_TRAPPED" not in c[1]] + EXTRA_CORES +
             [c for c in rc.CORES if "TAGE" in c[0]])


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def isa_of(arch):
    base, *z = arch.split("_")
    return "_".join([base] + sorted(z + ["zicsr"]))


def profile_of(core_idx, seed):
    """suy ra tham so bo sinh tu tap lenh cua loi; ngau nhien chon co dung lenh nen hay khong tren loi co C"""
    title, flag, files, arch, *plus = ALL_CORES[core_idx]
    caps = rc.exts(arch)
    r = random.Random((seed << 8) ^ (core_idx * 7919))
    csr = "m" in caps or "zifencei" in caps or "zicclsm" in caps or arch.startswith("rv32im")
    csr = arch != "rv32i"
    return dict(
        c="c" in caps and r.random() < 0.8,
        core_c="c" in caps,
        m="m" in caps,
        csr=csr,
        ma="zicclsm" in caps,
        fencei="zifencei" in caps,
        zb="zba" in caps,
        units=r.choice([60, 120, 200, 320, 320, 480, 640]),
    ), caps


def build_elf(src, march, tmp, name):
    ld = os.path.join(tmp, "link.ld")
    if not os.path.exists(ld):
        open(ld, "w").write(open(os.path.join(os.path.dirname(HERE), "bench", "bench.ld")).read().replace(". = 0x0;", f". = 0x{rc.BASE:x};"))
    elf = os.path.join(tmp, name + ".elf")
    r = sh(rc.GCC + [f"-march={march}", "-mno-relax", "-T", ld, src, "-o", elf])
    return elf if r.returncode == 0 else (None, r.stderr)


EXC_RE = re.compile(r"core\s+\d+: exception (\w+), epc 0x([0-9a-f]+)")


def load_image(hexf):
    img = [int(x, 16) for x in open(hexf).read().split()]
    return img


def fetch(img, pc):
    """ma lenh tai pc (16 hoac 32 bit) tu anh bo nho (ma khong tu sua nen lenh gay trap khong bi ghi de)"""
    def half(a):
        i = (a - rc.BASE) >> 2
        w = img[i] if 0 <= i < len(img) else 0
        return (w >> (16 * ((a >> 1) & 1))) & 0xFFFF
    lo = half(pc)
    return lo if lo & 3 != 3 else lo | (half(pc + 2) << 16)


def spike_trace_x(path, img):
    """nhu run_cosim.spike_trace, them mot muc cho moi lenh gay trap (Spike khong ghi commit cho lenh do, con RTL bao no hoan
    tat nhung khong ghi thanh ghi / bo nho): (epc, ma lenh, 0, 0, None)"""
    out = []
    with open(path) as f:
        for l in f:
            m = EXC_RE.match(l)
            if m:
                epc = int(m.group(2), 16)
                ins = fetch(img, epc)
                if ins not in rc.TRAPPING:        # main: rtl_trace da bo ECALL/EBREAK/C.EBREAK, khong them muc gia cho chung
                    out.append((epc, ins, 0, 0, None))
                continue
            m = rc.SP_RE.match(l)
            if not m:
                continue
            pc, ins = int(m.group(1), 16), int(m.group(2), 16)
            if pc < rc.BASE:
                continue
            tok = m.group(3).split()
            rd, val, st = 0, 0, None
            i = 0
            while i < len(tok):
                t = tok[i]
                if re.fullmatch(r"x\d+", t):
                    rd, val = int(t[1:]), int(tok[i + 1], 16) & 0xFFFFFFFF
                    i += 2
                elif t == "mem":
                    if i + 2 <= len(tok) - 1 and tok[i + 2].startswith("0x"):
                        size = 4 if (ins & 3) != 3 else 1 << ((ins >> 12) & 3)
                        st = rc.norm_store(int(tok[i + 1], 16) & 0xFFFFFFFF, size, int(tok[i + 2], 16))
                        i += 3
                    else:
                        i += 2
                else:
                    i += 1
            out.append((pc, ins, rd, val if rd else 0, st))
            if st and st[0] == rc.TOHOST:
                break
    return out


def run_one(task):
    core_idx, seed, sim, spike, fail_dir, keep, want_cov = task
    title, flag, files, arch, *plus = ALL_CORES[core_idx]
    prof, caps = profile_of(core_idx, seed)
    tag = f"{core_idx:02d}_{seed}"
    tmp = tempfile.mkdtemp(prefix=f"rnd_{tag}_")
    res = dict(core=core_idx, seed=seed, n=0, status="PASS", err="", cov=None, units=prof["units"], c=prof["c"])
    try:
        g = gen_rand.Gen(seed, prof["units"], c=prof["c"], m=prof["m"], csr=prof["csr"], ma=prof["ma"],
                         fencei=prof["fencei"], core_c=prof["core_c"], zb=prof["zb"])
        src = os.path.join(tmp, "p.S")
        open(src, "w").write(g.build())
        base = "rv32i" + ("m" if prof["m"] else "") + ("c" if prof["c"] else "")
        march = base + "_zicsr_zifencei" + ("_zba_zbb_zbc_zbs_zicond" if prof["zb"] else "")
        out = build_elf(src, march, tmp, "p")
        if isinstance(out, tuple):
            res.update(status="GENERR", err="gcc: " + out[1][:400])
            return finish(res, tmp, fail_dir, True, src)
        elf = out
        log = os.path.join(tmp, "spike.log")
        try:
            r = sh([spike, f"--isa={isa_of(arch)}", "--priv=m", "--no-dm", f"-m0x{rc.BASE:x}:0x200000", "--instructions=3000000",
                    "-l", "--log-commits", f"--log={log}", elf], timeout=120)
        except subprocess.TimeoutExpired:
            res.update(status="GENERR", err="spike khong ket thuc")
            return finish(res, tmp, fail_dir, True, src)
        hexf = os.path.join(tmp, "p.hex")
        rc.to_hex(elf, hexf)
        img = load_image(hexf)
        ref = spike_trace_x(log, img)
        if not ref or ref[-1][4] is None or ref[-1][4][0] != rc.TOHOST:
            res.update(status="GENERR", err=f"Spike khong toi TOHOST (ma {r.returncode}, {len(ref)} lenh)")
            return finish(res, tmp, fail_dir, True, src)
        try:
            out = sh(["vvp", "-n", sim, f"+prog={hexf}", f"+tmax={30 * len(ref) + 20000}"] + (plus[0] if plus else []),
                     timeout=300).stdout.splitlines()
        except subprocess.TimeoutExpired:
            res.update(status="FAIL", err="RTL qua thoi gian")
            return finish(res, tmp, fail_dir, True, src, log)
        rtl = rc.rtl_trace(out)
        err = rc.compare(ref, rtl)
        res["n"] = len(ref)
        if want_cov:
            import cov_func
            res["cov"] = cov_func.collect(log, ref, rc.BASE, fetch=lambda a: fetch(img, a))
        if err:
            res.update(status="FAIL", err=err)
            open(os.path.join(tmp, "rtl.out"), "w").write("\n".join(out[-400:]))
            return finish(res, tmp, fail_dir, True, src, log)
        return finish(res, tmp, fail_dir, keep, src, log)
    except Exception as e:                       # loi trong chinh bo kiem chung: bao ro, khong nuot
        res.update(status="GENERR", err=f"ngoai le: {e!r}")
        return finish(res, tmp, fail_dir, True, None)


def finish(res, tmp, fail_dir, keep, src, log=None):
    if keep:
        d = os.path.join(fail_dir, f"{res['core']:02d}_{res['seed']}_{res['status']}")
        os.makedirs(d, exist_ok=True)
        for f in os.listdir(tmp):
            if f.endswith((".S", ".out", ".log", ".hex", ".elf")):
                shutil.copy(os.path.join(tmp, f), d)
        open(os.path.join(d, "why.txt"), "w").write(res["err"] + "\n")
    shutil.rmtree(tmp, ignore_errors=True)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=100, help="so chuong trinh moi loi")
    ap.add_argument("--seed0", type=int, default=0)
    ap.add_argument("--core", default="", help="chi chay loi co ten chua chuoi nay")
    ap.add_argument("--idx", type=int, nargs="*", default=None, help="chi chay cac loi co chi so nay (xem --list)")
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    ap.add_argument("--fail-dir", default="/tmp/random_fail")
    ap.add_argument("--report", default="")
    ap.add_argument("--cov", action="store_true", help="thu coverage chuc nang tu vet Spike")
    ap.add_argument("--keep", action="store_true", help="giu lai moi chuong trinh, khong chi chuong trinh loi")
    ap.add_argument("--stop-on-fail", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list:
        for i, c in enumerate(ALL_CORES):
            print(f"{i:2d}  {c[0]}")
        return
    idxs = [i for i, c in enumerate(ALL_CORES) if a.core in c[0] and c[3] != "rv32i" or (a.core in c[0] and c[3] == "rv32i")]
    if a.idx is not None:
        idxs = [i for i in idxs if i in a.idx]
    tmpd = tempfile.mkdtemp(prefix="rnd_sims_")
    sims = {}
    for i in idxs:
        title, flag, files, arch, *plus = ALL_CORES[i]
        vvp = os.path.join(tmpd, f"sim{i}.vvp")
        r = sh(["iverilog", "-g2012", "-DNO_VCD", "-o", vvp] + flag.split() + [os.path.join(HERE, "tb_cosim.v")] +
               [os.path.join(ROOT, f) for f in files])
        if r.returncode:
            print(r.stderr)
            sys.exit(1)
        sims[i] = vvp
    os.makedirs(a.fail_dir, exist_ok=True)
    tasks = [(i, a.seed0 + k, sims[i], a.spike, a.fail_dir, a.keep, a.cov) for k in range(a.n) for i in idxs]
    total = len(tasks)
    stats = {i: dict(title=ALL_CORES[i][0], programs=0, instrs=0, fail=0, generr=0) for i in idxs}
    cov, fails, t0 = {}, [], time.time()
    with mp.Pool(a.jobs) as pool:
        for k, res in enumerate(pool.imap_unordered(run_one, tasks, chunksize=1), 1):
            st = stats[res["core"]]
            if res["status"] == "PASS":
                st["programs"] += 1
                st["instrs"] += res["n"]
            elif res["status"] == "FAIL":
                st["fail"] += 1
                fails.append(res)
                print(f"\nFAIL loi {res['core']} ({st['title']}) seed {res['seed']}: {res['err'][:600]}", flush=True)
            else:
                st["generr"] += 1
                fails.append(res)
                print(f"\nGENERR loi {res['core']} seed {res['seed']}: {res['err'][:300]}", flush=True)
            if res["cov"]:
                for b, v in res["cov"].items():
                    cov[b] = cov.get(b, 0) + v
            if k % 25 == 0 or k == total:
                el = time.time() - t0
                print(f"\r[{k}/{total}] {el:6.0f}s  khop {sum(s['programs'] for s in stats.values())} chuong trinh, "
                      f"{sum(s['instrs'] for s in stats.values())} lenh, loi {len(fails)}", end="", flush=True)
            if a.stop_on_fail and res["status"] != "PASS":
                pool.terminate()
                break
    print()
    for i in idxs:
        s = stats[i]
        print(f"  [{i:2d}] {s['title'][:62]:<62} {s['programs']:>5} chuong trinh {s['instrs']:>9} lenh  loi {s['fail']} genErr {s['generr']}")
    tot_p = sum(s["programs"] for s in stats.values())
    tot_i = sum(s["instrs"] for s in stats.values())
    print(f"TONG: {tot_p} chuong trinh khop, {tot_i} lenh khop Spike, {len(fails)} that bai, {time.time() - t0:.0f} s")
    if a.report:
        os.makedirs(os.path.dirname(os.path.abspath(a.report)), exist_ok=True)
        json.dump(dict(seed0=a.seed0, n=a.n, cores=stats, fails=[{k: v for k, v in f.items() if k != "cov"} for f in fails],
                       programs=tot_p, instrs=tot_i, cov=cov), open(a.report, "w"), indent=1)
    shutil.rmtree(tmpd, ignore_errors=True)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
