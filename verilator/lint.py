#!/usr/bin/env python3
"""verilator --lint-only -Wall cho pipeline, cache, bo phan xu bus va SoC voi danh sach waiver verilator/waivers.vlt.
Moi muc waiver phai co ly do (xem tep). Thoat ma 1 neu con canh bao khong duoc waiver hoac muc waiver da cu (khong khop canh bao nao).
Dung: python3 verilator/lint.py [--no-waiver]"""
import argparse, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORE = ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"]
SOC = ["soc/soc_top.v", "soc/soc_bus.v", "soc/soc_gpio.v", "soc/soc_plic.v", "soc/soc_ram.v", "soc/soc_rom.v", "soc/soc_syscon.v",
       "soc/soc_uart.v", "rv32_mtimer.v"] + CORE + ["rv32_icache.v", "rv32_dcache.v", "rv32_bus_arbiter.v"]
ZB = ["-GZBA=1", "-GZBB=1", "-GZBS=1", "-GZBC=1", "-GZICOND=1"]
# (ten, top, file, tham so -G): cau hinh mac dinh va cac cau hinh bat het tinh nang de lint phu moi nhanh generate
TARGETS = [("rv32im_pipeline", "rv32im_pipeline", CORE, []), ("rv32i_core", "rv32i_core", ["rv32i_core.v"], []),
           ("rv32_icache", "rv32_icache", ["rv32_icache.v"], []), ("rv32_dcache", "rv32_dcache", ["rv32_dcache.v"], []),
           ("rv32_bus_arbiter", "rv32_bus_arbiter", ["rv32_bus_arbiter.v"], []), ("rv32_mtimer", "rv32_mtimer", ["rv32_mtimer.v"], []),
           ("soc_top", "soc_top", SOC, []),
           ("pipeline C+MA+gshare+Zb*", "rv32im_pipeline", CORE, ["-GENABLE_C=1", "-GMISALIGNED=1", "-GGHR_BITS=4", "-GMUL_LAT=0"] + ZB),
           ("pipeline MUL_LAT=1, BTB/RAS 0", "rv32im_pipeline", CORE, ["-GMUL_LAT=1", "-GBTB_N=0", "-GRAS_N=0", "-GENABLE_C=1"]),
           ("icache 4 duong", "rv32_icache", ["rv32_icache.v"], ["-GWAYS=4", "-GLINES=8"]),
           ("icache 2 duong", "rv32_icache", ["rv32_icache.v"], ["-GWAYS=2", "-GLINES=4", "-GWORDS=2"]),
           ("dcache 4 duong, bo dem ghi 1", "rv32_dcache", ["rv32_dcache.v"], ["-GWAYS=4", "-GWBUF=1", "-GLINES=8"]),
           ("dcache 2 duong, bo dem ghi 4", "rv32_dcache", ["rv32_dcache.v"], ["-GWAYS=2", "-GWBUF=4", "-GLINES=4", "-GWORDS=2"])]
W_RE = re.compile(r'lint_off -rule (\w+) -file "\*([^"]+)" -lines (\d+)(?:-(\d+))?')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-waiver", action="store_true", help="khong dung waiver (liet ke het canh bao)")
    a = ap.parse_args()
    waivers = [(m.group(1), m.group(2), int(m.group(3)), int(m.group(4) or m.group(3))) for m in W_RE.finditer(open(os.path.join(HERE, "waivers.vlt")).read())]
    used = set()
    bad = 0
    for name, top, files, gf in TARGETS:
        cmd = ["verilator", "--lint-only", "-Wall", "--top-module", top, "-Wno-fatal"] + gf + [os.path.join(ROOT, f) for f in files]
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
        warns = re.findall(r"^%(?:Warning|Error)-?(\w*): ([^:]+):(\d+):", r.stderr, re.M)
        n_w = n_open = 0
        for rule, f, ln in warns:
            ln = int(ln)
            n_w += 1
            hit = [w for w in waivers if w[0] == rule and f.endswith(w[1]) and w[2] <= ln <= w[3]]
            if hit and not a.no_waiver:
                used.update(hit)
            else:
                n_open += 1
                print(f"  [{name}] chua waiver: {rule} {f}:{ln}")
        # kiem tra bang chinh co che waiver cua Verilator: dung .vlt, khong -Wno-fatal, phai thoat ma 0 va khong canh bao nao
        rv = subprocess.run(["verilator", "--lint-only", "-Wall", "--top-module", top] + gf + [os.path.join(HERE, "waivers.vlt")] +
                            [os.path.join(ROOT, f) for f in files], capture_output=True, text=True, cwd=ROOT)
        if rv.returncode or "%Warning" in rv.stderr:
            print(rv.stderr[-600:])
        ok = n_open == 0 and (rv.returncode == 0 or a.no_waiver)
        if any(l.startswith("%Error") and "Exiting due to" not in l for l in r.stderr.splitlines()):
            ok = False
            print(r.stderr[-800:])
        print(f"{'OK  ' if ok else 'LOI '} {name:<30} {n_w:>3} canh bao, {n_w - n_open} duoc waiver, {n_open} chua")
        bad += 0 if ok else 1
    stale = [w for w in waivers if w not in used]
    if stale and not a.no_waiver:
        print("waiver cu (khong khop canh bao nao): " + ", ".join(f"{w[0]} {w[1]}:{w[2]}-{w[3]}" for w in stale))
        bad += 1
    print(f"LINT {'SACH' if not bad else 'CON LOI'}: {len(TARGETS)} muc tieu, {len(waivers)} dong waiver ({len({(w[0], w[1]) for w in waivers})} nhom file/rule)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
