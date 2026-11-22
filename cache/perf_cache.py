#!/usr/bin/env python3
"""Do hieu nang cua pipeline RV32IMC voi cache: so chu ky, CPI, so lan truot cache theo kich thuoc cache va do tre
bo nho, va so muc bo dem ghi cua cache du lieu, tren bench va bench_m (ban co lenh nen).
Moc so sanh: bo nho ly tuong (to hop, khong cache).
Do tre "toi da N": moi tu tren bus mat ngau nhien 1..N chu ky (trung binh khoang (N+1)/2).
Dung (tu thu muc goc repo): python3 cache/perf_cache.py   (can riscv64-unknown-elf-gcc, iverilog)
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "cosim"))
import run_cosim as rc  # noqa: E402

BASE = ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"]
CACHE = BASE + ["rv32_icache.v", "rv32_dcache.v", "rv32_bus_arbiter.v"]
CFGS = [("ly tuong (khong cache)", ["-DPIPE_FULL", "-DRVC"], BASE)] + [
    (f"cache {l}x{w}, bo dem ghi {q}", ["-DPIPE_FULL", "-DRVC", "-DCACHE", f"-DICL={l}", f"-DICW={w}", f"-DDCL={l}",
                                         f"-DDCW={w}", f"-DDWB={q}"], CACHE)
    for l, w, q in ((4, 4, 4), (16, 4, 1), (16, 4, 2), (16, 4, 4), (16, 4, 8), (64, 4, 4))]
LATS = [1, 4, 8]


def main():
    tmp = tempfile.mkdtemp(prefix="perf_")
    progs = [rc.build_bench("bench", "rv32ic", tmp), rc.build_bench("bench_m", "rv32imc", tmp)]
    for _, elf in progs:
        rc.to_hex(elf, elf[:-4] + ".hex")
    print("| Chuong trinh | Cau hinh | Do tre toi da | Chu ky | CPI | Truot I / D | Bo dem day (chu ky) | Tu forward |")
    print("|---|---|---|---|---|---|---|---|")
    for k, (title, flags, files) in enumerate(CFGS):
        vvp = os.path.join(tmp, f"p{k}.vvp")
        subprocess.run(["iverilog", "-g2012", "-o", vvp] + flags + [os.path.join(rc.HERE, "tb_cosim.v")] +
                       [os.path.join(ROOT, f) for f in files], check=True, capture_output=True)
        for name, elf in progs:
            for lat in (LATS if "-DCACHE" in flags else [0]):
                out = subprocess.run(["vvp", "-n", vvp, f"+prog={elf[:-4]}.hex", f"+lat={lat}"],
                                     capture_output=True, text=True).stdout
                d = dict(t.split("=") for l in out.splitlines() if l.startswith("DONE") for t in l.split()[1:])
                cyc, n = int(d["cycles"]), int(d["instr"])
                miss = f"{d['imiss']} / {d['dmiss']}" if "imiss" in d else "-"
                print(f"| {name} | {title} | {lat if lat else '-'} | {cyc} | {cyc / n:.2f} | {miss} | "
                      f"{d.get('wbfull', '-')} | {d.get('fwd', '-')} |", flush=True)


if __name__ == "__main__":
    main()
