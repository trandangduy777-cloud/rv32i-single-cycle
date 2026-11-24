#!/usr/bin/env python3
"""Chay test co huong do bo sinh ngau nhien dan ra (cosim/tests/csr_mie.S, ...) tren moi loi va so voi Spike tung lenh.
Khong sua cosim/run_cosim.py dung chung. Dung: python3 cosim/run_directed.py [--core CHUOI] [csr_mie ...]"""
import argparse, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_cosim as rc                           # noqa: E402
import run_random as rr                          # noqa: E402

# ten test -> (march bien dich, co chay duoc tren loi khong C hay khong, can C)
TESTS = {"csr_mie": "rv32i_zicsr"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tests", nargs="*", default=list(TESTS))
    ap.add_argument("--core", default="")
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="dir_")
    bad = 0
    for i, (title, flag, files, arch, *plus) in enumerate(rr.ALL_CORES):
        if a.core not in title or files == ["rv32i_pipeline.v"]:   # pipeline RV32I thuan khong co Zicsr: bo qua
            continue
        vvp = os.path.join(tmp, f"s{i}.vvp")
        r = rr.sh(["iverilog", "-g2012", "-DNO_VCD", "-o", vvp] + flag.split() + [os.path.join(HERE, "tb_cosim.v")] +
                  [os.path.join(rr.ROOT, f) for f in files])
        if r.returncode:
            print(r.stderr); sys.exit(1)
        for t in a.tests:
            src = os.path.join(HERE, "tests", t + ".S")
            elf = rr.build_elf(src, TESTS[t], tmp, t)
            if isinstance(elf, tuple):
                print(f"loi bien dich {t}: {elf[1][:300]}"); sys.exit(1)
            log = os.path.join(tmp, t + ".log")
            rr.sh([a.spike, f"--isa={rr.isa_of(TESTS[t])}", "--priv=m", "--no-dm", f"-m0x{rc.BASE:x}:0x200000",
                   "-l", "--log-commits", f"--log={log}", elf], timeout=60)
            hexf = os.path.join(tmp, t + ".hex")
            rc.to_hex(elf, hexf)
            ref = rr.spike_trace_x(log, rr.load_image(hexf))
            out = rr.sh(["vvp", "-n", vvp, f"+prog={hexf}", f"+tmax={30 * len(ref) + 5000}"] + (plus[0] if plus else []),
                        timeout=120).stdout.splitlines()
            err = rc.compare(ref, rc.rtl_trace(out))
            tohost_ok = bool(ref) and ref[-1][4] is not None and ref[-1][4][2] == 1
            if err or not tohost_ok:
                bad += 1
                print(f"FAIL {t} loi {i} ({title}): {err or 'TOHOST != 1'}")
            else:
                print(f"ok   {t} loi {i} ({title}): {len(ref)} lenh khop Spike")
    shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
