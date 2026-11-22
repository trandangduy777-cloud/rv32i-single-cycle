#!/usr/bin/env python3
"""Do bo du doan nhanh cua pipeline RV32IMC (bo nho to hop, khong cache) theo cau hinh BTB / RAS / gshare:
so chu ky, CPI, ti le doan sai nhanh co dieu kien va JALR, so lan IF nhay theo BTB, so lan ID sua / nhay som.
Moc so sanh: BTB_N = 0, RAS_N = 0, GHR_BITS = 0 (bo du doan cu: bang dem doc o ID, JALR luon quyet dinh o EX).
Chuong trinh: bench, bench_m, bench_call (ban bien dich co lenh nen).
Dung (tu thu muc goc repo): python3 bpred/perf_bpred.py [--quick | --check]
  --check: kiem hieu nang dung tung chu ky (cho CI va cho dot bien chi lam cham, xem mutate_bpred.py): 3 cau hinh
           (cu, mac dinh, gshare 4 bit) tren 3 chuong trinh phai ra dung so chu ky va so lan doan sai da ghi o EXPECT.
           So nay phu thuoc ma may cua trinh bien dich: neu phien ban GCC khac GCC_REF thi chi kiem tuong doi
           (ban moi phai nhanh hon ban cu tren moi chuong trinh).
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "cosim"))
import run_cosim as rc  # noqa: E402

FILES = ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"]
FULL = [(0, 0, 0), (16, 0, 0), (0, 4, 0), (8, 4, 0), (16, 4, 0), (32, 4, 0), (64, 4, 0),
        (16, 2, 0), (16, 8, 0), (16, 16, 0), (16, 4, 4), (16, 4, 6)]
QUICK = [(0, 0, 0), (16, 4, 0)]
CHECK = [(0, 0, 0), (16, 4, 0), (16, 4, 4)]
GCC_REF = "13.2.0-11ubuntu1+12"
# (BTB, RAS, GHR) -> chuong trinh -> (chu ky, nhanh doan sai, JALR doan sai)
EXPECT = {
    (0, 0, 0):  {"bench-c": (43738, 990, 3), "bench_m-c": (73314, 335, 2), "bench_call-c": (83226, 1816, 4199)},
    (16, 4, 0): {"bench-c": (38272, 990, 0), "bench_m-c": (71238, 335, 0), "bench_call-c": (70811, 1816, 685)},
    (16, 4, 4): {"bench-c": (38368, 1020, 0), "bench_m-c": (71509, 425, 0), "bench_call-c": (67531, 702, 685)},
}


def main():
    check = "--check" in sys.argv
    cfgs = CHECK if check else QUICK if "--quick" in sys.argv else FULL
    gcc = subprocess.run(["riscv64-unknown-elf-gcc", "--version"], capture_output=True, text=True).stdout
    exact = GCC_REF in gcc
    got = {}
    tmp = tempfile.mkdtemp(prefix="bp_")
    progs = [rc.build_bench(n, m, tmp) for n, m in (("bench", "rv32ic"), ("bench_m", "rv32imc"), ("bench_call", "rv32ic"))]
    for _, elf in progs:
        rc.to_hex(elf, elf[:-4] + ".hex")
    print("| Chuong trinh | BTB / RAS / GHR | Chu ky | CPI | Nhanh doan sai | JALR doan sai | IF nhay theo BTB | ID sua / nhay |")
    print("|---|---|---|---|---|---|---|---|")
    for btb, ras, ghr in cfgs:
        vvp = os.path.join(tmp, "bp.vvp")
        subprocess.run(["iverilog", "-g2012", "-o", vvp, "-DPIPE_FULL", "-DRVC", f"-DBTBN={btb}", f"-DRASN={ras}",
                        f"-DGHRB={ghr}", os.path.join(rc.HERE, "tb_cosim.v")] + [os.path.join(ROOT, f) for f in FILES],
                       check=True, capture_output=True)
        for name, elf in progs:
            out = subprocess.run(["vvp", "-n", vvp, f"+prog={elf[:-4]}.hex"], capture_output=True, text=True).stdout
            d = {}
            for l in out.splitlines():
                if l.startswith(("BPRED", "DONE")):
                    d.update(t.split("=") for t in l.split()[1:])
            if "cycles" not in d:                         # chuong trinh khong ket thuc: treo / chay sai
                print(f"| {name} | {btb} / {ras} / {ghr} | TREO (khong ghi TOHOST) | | | | | |", flush=True)
                got[(btb, ras, ghr), name] = (-1, -1, -1)
                continue
            cyc, n = int(d["cycles"]), int(d["instr"])
            br, brm, jr, jrm = (int(d[k]) for k in ("br", "brmiss", "jalr", "jalrmiss"))
            got[(btb, ras, ghr), name] = (cyc, brm, jrm)
            print(f"| {name} | {btb} / {ras} / {ghr} | {cyc} | {cyc / n:.3f} | {brm}/{br} ({100 * brm / max(br, 1):.1f} %) | "
                  f"{jrm}/{jr} | {d['btbtaken']} | {d['idredir']} |", flush=True)
    if check:
        bad = []
        for (cfg, name), v in got.items():
            if exact and EXPECT[cfg][name] != v:
                bad.append(f"{name} {cfg}: (chu ky, nhanh sai, JALR sai) = {v}, mong doi {EXPECT[cfg][name]}")
            if v[0] < 0:
                bad.append(f"{name} {cfg}: chuong trinh khong ket thuc")
            elif cfg != (0, 0, 0) and v[0] >= got[(0, 0, 0), name][0]:
                bad.append(f"{name} {cfg}: {v[0]} chu ky, khong nhanh hon ban cu ({got[(0, 0, 0), name][0]})")
        print(("kiem dung tung chu ky" if exact else f"GCC khac {GCC_REF}: chi kiem tuong doi") +
              (": PASS" if not bad else ": FAIL\n  " + "\n  ".join(bad)))
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
