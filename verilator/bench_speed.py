#!/usr/bin/env python3
"""So toc do mo phong iverilog (vvp) voi Verilator --binary --timing tren cung testbench cosim/tb_cosim.v va cung chuong trinh
(CoreMark 1 vong, khong in vet tung lenh: +quiet). Moi lan: thoi gian bien dich, thoi gian chay, chu ky mo phong / giay.
Dung: python3 verilator/bench_speed.py [--iters 1] [--cores 2 4]  (chi so trong cosim/run_cosim.CORES)"""
import argparse, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "cosim"))
sys.path.insert(0, os.path.join(ROOT, "coremark"))
import run_cosim as rc            # noqa: E402
import run_coremark as cm         # noqa: E402


def timed(cmd, **kw):
    t = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    return r, time.time() - t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=1)
    ap.add_argument("--cores", type=int, nargs="+", default=[0, 2, 4])
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="vlspeed_")
    cm.fetch_src()
    rows = []
    for ci in a.cores:
        title, flag, files, arch, *plus = rc.CORES[ci]
        march = "rv32imc" if "RVC" in flag else "rv32im"
        elf = cm.build(march, a.iters, tmp)[0]
        hexf = os.path.join(tmp, f"cm{ci}.hex")
        rc.to_hex(elf, hexf)
        srcs = [os.path.join(rc.HERE, "tb_cosim.v")] + [os.path.join(ROOT, f) for f in files]
        res = {}
        # iverilog
        vvp = os.path.join(tmp, f"i{ci}.vvp")
        r, tc = timed(["iverilog", "-g2012", "-DNO_VCD", "-o", vvp] + flag.split() + srcs)
        assert r.returncode == 0, r.stderr
        r, tr = timed(["vvp", "-n", vvp, f"+prog={hexf}", "+quiet"] + (plus[0] if plus else []), timeout=3600)
        res["iverilog"] = (tc, tr, r.stdout)
        # verilator
        mdir = os.path.join(tmp, f"v{ci}")
        r, tc = timed(["verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-DNO_VCD", "--top-module", "tb_cosim",
                       "-O2", "-j", "2", "-Mdir", mdir, "-o", "Vsim"] + flag.split() + srcs)
        assert r.returncode == 0, r.stderr[-800:]
        r, tr = timed([os.path.join(mdir, "Vsim"), f"+prog={hexf}", "+quiet"] + (plus[0] if plus else []), timeout=3600)
        res["verilator"] = (tc, tr, r.stdout)
        cyc = {k: int(re.search(r"DONE cycles=(\d+) instr=(\d+)", v[2]).group(1)) for k, v in res.items()}
        ins = int(re.search(r"DONE cycles=(\d+) instr=(\d+)", res["iverilog"][2]).group(2))
        # loi khong cache: hai bo mo phong phai cho dung so chu ky; loi co cache dung $urandom(seed) cho do tre bo nho nen so chu ky
        # lech nhau chut it giua hai bo mo phong (cung kieu phan phoi, khac day so), khong phai loi
        assert "CACHE" in flag or len(set(cyc.values())) == 1, f"so chu ky khac nhau: {cyc}"
        for k, (tc, tr, _) in res.items():
            rows.append((title, k, tc, tr, cyc[k], cyc[k] / tr))
        print(f"{title}: {ins} lenh; chu ky iverilog {cyc['iverilog']}, Verilator {cyc['verilator']}" +
              ("" if "CACHE" in flag else " (bang nhau)"))
        for k, (tc, tr, _) in res.items():
            print(f"   {k:<10} bien dich {tc:6.1f} s   chay {tr:7.1f} s   {cyc[k] / tr:12.0f} chu ky/s")
        print(f"   Verilator nhanh gap {res['iverilog'][1] / res['verilator'][1]:.1f} lan khi chay (bien dich cham gap {res['verilator'][0] / max(res['iverilog'][0], 0.01):.0f} lan)", flush=True)


if __name__ == "__main__":
    main()
