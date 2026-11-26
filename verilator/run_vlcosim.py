#!/usr/bin/env python3
"""So vet voi Spike bang Verilator (thay cho iverilog): chay lai dung bo chuong trinh cua cosim/run_cosim.py (riscv-tests, bench,
test tu viet, CoreMark) hoac cosim/run_random.py tren cac loi, nhung RTL duoc mo phong boi Verilator --binary --timing.
Ket qua so vet voi Spike phai giong ban iverilog. Cuoi cung in thoi gian bien dich / mo phong de so tocdo.
Dung:
  python3 verilator/run_vlcosim.py cosim  [/tmp/riscv-tests] [--core ...] [--only ...] [--engine iverilog|verilator]
  python3 verilator/run_vlcosim.py random [--n 8 --seed0 1000 --idx ...] [--engine ...]"""
import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "cosim"))
sys.path.insert(0, HERE)
import run_cosim as rc            # noqa: E402
import run_random as rr           # noqa: E402
import vl_shim                    # noqa: E402


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "cosim"
    args = sys.argv[2:]
    engine = "verilator"
    if "--engine" in args:
        i = args.index("--engine")
        engine = args[i + 1]
        del args[i:i + 2]
    vl_shim.install([rc, rr], engine)
    sys.argv = [mode] + args
    t0 = time.time()
    code = 0
    try:
        (rc.main if mode == "cosim" else rr.main)()
    except SystemExit as e:
        code = e.code or 0
    s = vl_shim.STATS
    if mode == "random":     # chuong trinh chay trong tien trinh con (--jobs), nen STATS chi dem phan bien dich o tien trinh cha
        print(f"[{engine}] tong {time.time() - t0:.0f} s, trong do bien dich {s['compile_s']:.0f} s ({s['compiles']} lan); thoi gian mo phong khong tach rieng o che do random")
        sys.exit(code)
    print(f"[{engine}] tong {time.time() - t0:.0f} s: bien dich {s['compile_s']:.0f} s ({s['compiles']} lan), mo phong {s['sim_s']:.0f} s ({s['runs']} lan chay)")
    sys.exit(code)


if __name__ == "__main__":
    main()
