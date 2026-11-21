#!/usr/bin/env python3
"""Bien dich va chay bo test ISA chinh thuc riscv-tests (rv32ui, rv32um) tren 3 loi.

Can: riscv64-unknown-elf-gcc (Ubuntu: sudo apt install gcc-riscv64-unknown-elf), iverilog,
     ma nguon riscv-tests (git clone --recursive https://github.com/riscv-software-src/riscv-tests).
Dung:  python3 riscv-tests/run_riscv_tests.py <thu_muc_riscv-tests>
Bo qua: fence_i (can Zifencei), ma_data (can phan cung ho tro truy cap lech), cac test M-mode/S-mode (rv32mi, rv32si).
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SKIP = {"fence_i": "can Zifencei", "ma_data": "can truy cap lech do phan cung xu ly (loi nay bao trap)"}
CORES = [("single-cycle (rv32i_core.v)", "", ["rv32i_core.v"], "rv32i"),
         ("pipeline RV32I (rv32i_pipeline.v)", "-DPIPE", ["rv32i_pipeline.v"], "rv32i"),
         ("pipeline RV32IM (rv32im_pipeline.v)", "-DPIPE_FULL", ["rv32im_pipeline.v", "rv32i_core.v"], "rv32im")]
# Mo phong muc cong: GLS_FILES="<netlist.nl.v> <thu vien cell chuc nang> <udp>" chay them bo test tren netlist sau P&R
# (RV32I hoac RV32IM, nhan dien theo ten module trong netlist)
if os.environ.get("GLS_FILES"):
    _gls = os.environ["GLS_FILES"].split()
    with open(os.path.join(ROOT, _gls[0])) as _f:
        _nl = _f.read()
    _full = "module rv32im_pipeline" in _nl
    # netlist tong hop truoc khi co ngat thi khong co chan irq_timer/irq_soft/irq_ext
    _flag = ("-DPIPE_FULL" + ("" if "irq_soft" in _nl else " -DNO_IRQ_PORTS")) if _full else "-DPIPE"
    CORES.append(("netlist %s sau P&R (GLS)" % ("RV32IM" if _full else "RV32I"),
                  _flag, _gls, "rv32im" if _full else "rv32i"))


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def build(src, march, out_dir):
    name = os.path.splitext(os.path.basename(src))[0]
    elf = os.path.join(out_dir, name + ".elf")
    binf = os.path.join(out_dir, name + ".bin")
    hexf = os.path.join(out_dir, name + ".hex")
    macros = os.path.join(os.path.dirname(os.path.dirname(src)), "macros", "scalar")
    r = sh(["riscv64-unknown-elf-gcc", f"-march={march}", "-mabi=ilp32", "-static", "-mcmodel=medany",
            "-fvisibility=hidden", "-nostdlib", "-nostartfiles", "-I", HERE, "-I", macros,
            "-T", os.path.join(HERE, "link.ld"), src, "-o", elf])
    if r.returncode:
        return None, r.stderr.strip().splitlines()[-1] if r.stderr else "loi bien dich"
    sh(["riscv64-unknown-elf-objcopy", "-O", "binary", elf, binf])
    data = open(binf, "rb").read()
    data += b"\0" * (-len(data) % 4)
    with open(hexf, "w") as f:
        for i in range(0, len(data), 4):
            f.write("%08x\n" % int.from_bytes(data[i:i + 4], "little"))
    return hexf, len(data)


def main():
    rt = sys.argv[1] if len(sys.argv) > 1 else "riscv-tests"
    isa = os.path.join(rt, "isa")
    tests = []
    for suite in ("rv32ui", "rv32um"):
        d = os.path.join(isa, suite)
        for f in sorted(os.listdir(d)):
            if f.endswith(".S"):
                tests.append((suite, os.path.join(d, f)))
    tmp = tempfile.mkdtemp(prefix="rvtests_")
    sims = {}
    for k, (title, flag, files, arch) in enumerate(CORES):
        out = os.path.join(tmp, "sim_%d" % k)
        cmd = ["iverilog", "-g2012", "-o", out] + (flag.split() if flag else []) + \
              [os.path.join(HERE, "tb_riscv_tests.v")] + [os.path.join(ROOT, x) for x in files]
        r = sh(cmd)
        if r.returncode:
            print("loi iverilog:", r.stderr); sys.exit(1)
        sims[title] = out
    images = {}
    for suite, src in tests:
        name = suite + "-" + os.path.splitext(os.path.basename(src))[0]
        short = os.path.splitext(os.path.basename(src))[0]
        if short in SKIP:
            images[name] = (None, "bo qua: " + SKIP[short], suite); continue
        march = "rv32im" if suite == "rv32um" else "rv32i"
        hexf, info = build(src, march, tmp)
        images[name] = (hexf, info, suite)
    total_fail = 0
    for title, flag, files, arch in CORES:
        npass = nfail = nskip = 0
        fails = []
        for name, (hexf, info, suite) in images.items():
            if hexf is None:
                nskip += 1; continue
            if suite == "rv32um" and arch != "rv32im":
                nskip += 1; continue
            r = sh(["vvp", sims[title], f"+img={hexf}"])
            line = [l for l in r.stdout.splitlines() if l.startswith("RESULT")]
            res = line[-1] if line else "RESULT ?"
            if res.startswith("RESULT PASS"):
                npass += 1
            else:
                nfail += 1; fails.append(f"{name}: {res}")
        print(f"{title}: PASS {npass}, FAIL {nfail}, bo qua {nskip}")
        for f in fails:
            print("   ", f)
        total_fail += nfail
    skipped = sorted(n for n, (h, i, s) in images.items() if h is None)
    print("Bo qua (moi loi):", ", ".join(f"{n} ({images[n][1]})" for n in skipped))
    sys.exit(1 if total_fail else 0)


if __name__ == "__main__":
    main()
