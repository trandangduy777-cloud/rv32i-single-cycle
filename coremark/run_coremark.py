#!/usr/bin/env python3
"""CoreMark tren cac loi cua repo (mo phong RTL bang iverilog, testbench cosim/tb_cosim.v).

- Ma nguon CoreMark cua EEMBC duoc lay tu GitHub o commit ghim (SRC_COMMIT) vao coremark/eembc (khong dua vao repo);
  port cho loi nay nam o coremark/port (dua tren ban barebones, giay phep Apache-2.0).
- Thoi gian: core_portme.c ghi 1 / 2 vao o nho MARK luc bat dau / ket thuc phan do; testbench in "CMARK cycles=.. instr=..".
  CoreMark/MHz = so vong lap * 10^6 / so chu ky phan do.
- Day KHONG phai ket qua nop chinh thuc: quy dinh can chay >= 10 giay, mo phong chi chay vai vong, nen CoreMark tu bao
  "phai chay it nhat 10 giay". Tinh dung dan kiem bang CRC: seedcrc, crclist, crcmatrix, crcstate phai bang gia tri
  chuan cua lan chay hieu nang (seed 0, 0, 0x66) va loi duy nhat duoc phep la loi 10 giay do.
Dung (tu thu muc goc repo): python3 coremark/run_coremark.py [--iter N] [--quick]
"""
import argparse, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(HERE, "eembc")
SRC_URL = "https://github.com/eembc/coremark.git"
SRC_COMMIT = "1f483d5"
BASE, TOHOST = 0x80000000, 0x80100000
OPT = "-O2"                         # doi bang --opt
GCC = ["riscv64-unknown-elf-gcc", "-mabi=ilp32", "-static", "-mcmodel=medany", "-nostdlib", "-nostartfiles",
       f"-Wl,--defsym=tohost=0x{TOHOST:x}", f"-Wl,--defsym=fromhost=0x{TOHOST + 0x40:x}"]   # Spike dung khi ghi tohost
# CRC chuan cua lan chay hieu nang 2K (core_main.c: list_known_crc / matrix_known_crc / state_known_crc, seedcrc)
KNOWN = {"seedcrc": "0xe9f5", "[0]crclist": "0xe714", "[0]crcmatrix": "0x1fd7", "[0]crcstate": "0x8e3a"}

PIPE_FILES = ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"]
CACHE_FILES = PIPE_FILES + ["rv32_icache.v", "rv32_dcache.v", "rv32_bus_arbiter.v"]
# (ten, march, co -D cho tb_cosim.v, file RTL, plusargs)
CORES = [
    ("single-cycle RV32IM", "rv32im", ["-DSC"], ["rv32i_core.v"], []),
    ("pipeline RV32I (nhan/chia bang libgcc)", "rv32i", ["-DPIPE"], ["rv32i_pipeline.v"], []),
    ("pipeline RV32IM, du doan cu (BTB/RAS tat), nhan lap", "rv32im", ["-DPIPE_FULL", "-DBTBN=0", "-DRASN=0", "-DMULLAT=0"],
     PIPE_FILES, []),
    ("pipeline RV32IM, BTB 16 + RAS 4, nhan lap", "rv32im", ["-DPIPE_FULL", "-DMULLAT=0"], PIPE_FILES, []),
    ("pipeline RV32IM, BTB 16 + RAS 4", "rv32im", ["-DPIPE_FULL"], PIPE_FILES, []),
    ("pipeline RV32IMC, BTB 16 + RAS 4, nhan lap", "rv32imc", ["-DPIPE_FULL", "-DRVC", "-DMULLAT=0"], PIPE_FILES, []),
    ("pipeline RV32IMC, BTB 16 + RAS 4, nhan 1 chu ky", "rv32imc", ["-DPIPE_FULL", "-DRVC", "-DMULLAT=1"], PIPE_FILES, []),
    ("pipeline RV32IMC, BTB 16 + RAS 4", "rv32imc", ["-DPIPE_FULL", "-DRVC"], PIPE_FILES, []),
    ("RV32IMC + cache 2 x 256 B, bo nho tre 1-4", "rv32imc", ["-DPIPE_FULL", "-DRVC", "-DCACHE"], CACHE_FILES,
     ["+lat=4", "+seed=1"]),
    ("RV32IMC + cache 2 x 4 KB (256 dong x 4 tu), bo nho tre 1-4", "rv32imc",
     ["-DPIPE_FULL", "-DRVC", "-DCACHE", "-DICL=256", "-DDCL=256"], CACHE_FILES, ["+lat=4", "+seed=1"]),
]
QUICK = [4, 7]          # pipeline RV32IM va RV32IMC mac dinh


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def fetch_src():
    if not os.path.isdir(SRC):
        r = sh(["git", "clone", "-q", SRC_URL, SRC])
        if r.returncode:
            sys.exit("khong lay duoc ma nguon CoreMark: " + r.stderr)
    sh(["git", "-C", SRC, "checkout", "-q", SRC_COMMIT])


def build(march, iters, tmp):
    """-> duong dan .hex cua CoreMark bien dich cho march, dat o BASE (giong cosim/run_cosim.py)"""
    ld = os.path.join(tmp, "cm.ld")
    open(ld, "w").write(open(os.path.join(ROOT, "bench", "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    elf = os.path.join(tmp, f"coremark_{march}_{iters}.elf")
    flags = f"{OPT} -march={march}"
    src = [os.path.join(SRC, f) for f in ("core_list_join.c", "core_main.c", "core_matrix.c", "core_state.c", "core_util.c")]
    src += [os.path.join(HERE, "port", f) for f in ("core_portme.c", "ee_printf.c")]
    r = sh(GCC + [f"-march={march}"] + OPT.split() + ["-fno-builtin", "-I", SRC, "-I", os.path.join(HERE, "port"),
                  f"-DITERATIONS={iters}", "-DPERFORMANCE_RUN=1", f'-DFLAGS_STR="{flags}"',
                  f"-DSTACK_TOP=0x{BASE + 0x37000:x}", f"-DTOHOST_ADDR=0x{TOHOST:x}", "-T", ld,
                  os.path.join(ROOT, "bench", "crt0.S")] + src + ["-lgcc", "-o", elf])
    if r.returncode:
        sys.exit(r.stderr)
    hexf = elf[:-4] + ".hex"
    binf = elf[:-4] + ".bin"
    sh(["riscv64-unknown-elf-objcopy", "-O", "binary", elf, binf])
    d = open(binf, "rb").read()
    d += b"\0" * (-len(d) % 4)
    open(hexf, "w").write("".join("%08x\n" % int.from_bytes(d[i:i + 4], "little") for i in range(0, len(d), 4)))
    return elf, hexf


def check(console):
    """-> (dung, ly do): CRC chuan va chi co loi 10 giay"""
    got = dict(re.findall(r"^(\S+)\s*:\s*(0x[0-9a-f]+)", console, re.M))
    bad = [f"{k} = {got.get(k)} (chuan {v})" for k, v in KNOWN.items() if got.get(k) != v]
    errs = [l for l in console.splitlines() if "ERROR" in l and "10 secs" not in l]
    return (not bad and not errs), "; ".join(bad + errs)


def run(core, hexf, iters, tmp):
    name, march, flags, files, plus = core
    vvp = os.path.join(tmp, "cm_" + re.sub(r"\W", "_", name) + ".vvp")
    r = sh(["iverilog", "-g2012", "-o", vvp] + flags + [os.path.join(ROOT, "cosim", "tb_cosim.v")] +
           [os.path.join(ROOT, f) for f in files])
    if r.returncode:
        sys.exit(r.stderr)
    out = sh(["vvp", "-n", vvp, f"+prog={hexf}", "+quiet", f"+tmax={iters * 2_000_000 + 2_000_000}"] + plus).stdout
    con = out.split("CONSOLE_BEGIN\n", 1)[1].split("CONSOLE_END", 1)[0] if "CONSOLE_BEGIN" in out else ""
    m = re.search(r"CMARK (.*)", out)
    if not m or "DONE" not in out:
        return None, "khong ket thuc / khong co danh dau thoi gian", con
    d = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", m.group(1))}
    ok, why = check(con)
    return d, ("" if ok else why), con


def main():
    global OPT
    ap = argparse.ArgumentParser()
    ap.add_argument("--iter", type=int, default=10)
    ap.add_argument("--quick", action="store_true", help="chi 2 cau hinh pipeline RV32IM / RV32IMC")
    ap.add_argument("--show", action="store_true", help="in toan bo dau ra cua CoreMark cau hinh dau tien")
    ap.add_argument("--only", default=None, help="chi chay cac loi co ten chua chuoi nay")
    ap.add_argument("--opt", default=OPT, help="co toi uu GCC, vd. \"-O3 -funroll-loops\"")
    a = ap.parse_args()
    OPT = a.opt
    fetch_src()
    tmp = tempfile.mkdtemp(prefix="cm_")
    hexes = {}
    cores = [CORES[i] for i in QUICK] if a.quick else CORES
    if a.only:
        cores = [c for c in cores if a.only in c[0]]
    print(f"CoreMark {SRC_COMMIT}, {a.iter} vong, GCC {OPT}; mo phong RTL, khong phai ket qua nop chinh thuc")
    print("| Loi | -march | Chu ky (phan do) | Lenh | CPI | CoreMark/MHz | Chu ky mat: lenh M / cho bo nho / redirect EX / "
          "load-use / nhay o ID | CRC |")
    print("|---|---|---|---|---|---|---|---|")
    fails = 0
    for k, core in enumerate(cores):
        if core[1] not in hexes:
            hexes[core[1]] = build(core[1], a.iter, tmp)[1]
        res, why, con = run(core, hexes[core[1]], a.iter, tmp)
        if a.show and k == 0:
            print(con)
        if res is None:
            fails += 1
            print(f"| {core[0]} | {core[1]} | - | - | - | - | LOI: {why} |", flush=True)
            continue
        cyc, n = res["cycles"], res["instr"]
        fails += bool(why)
        lost = (" / ".join(str(res[k]) for k in ("mstall", "frz", "redir", "loaduse", "idredir"))
                if "-DPIPE_FULL" in core[2] else "-")
        print(f"| {core[0]} | {core[1]} | {cyc} | {n} | {cyc / n:.3f} | {a.iter * 1e6 / cyc:.3f} | {lost} | "
              f"{'dung' if not why else 'SAI: ' + why} |", flush=True)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
