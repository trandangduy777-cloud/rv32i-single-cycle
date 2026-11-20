#!/usr/bin/env python3
"""So vet tung lenh cua 3 loi voi Spike (trinh mo phong ISA chuan cua RISC-V).

Chuong trinh: bo test ISA riscv-tests (rv32ui, rv32um) va hai benchmark C (bench, bench_m), bien dich dat o
0x8000_0000 (ban do bo nho mac dinh cua Spike). Spike chay voi --log-commits; RTL chay cosim/tb_cosim.v voi
RESET_PC = 0x8000_0000. Moi lenh hoan tat duoc so: pc, ma lenh, thanh ghi dich va gia tri ghi, dia chi / do rong /
gia tri cua lenh store. Dung o lenh dau tien lech va in ngu canh.

Can: spike (https://github.com/riscv-software-src/riscv-isa-sim), riscv64-unknown-elf-gcc, iverilog,
     ma nguon riscv-tests.
Dung:  python3 cosim/run_cosim.py <thu_muc_riscv-tests> [--spike <duong dan spike>] [--only <ten>]
"""
import argparse, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BASE = 0x80000000
TOHOST = 0x80100000
SKIP = {"fence_i": "can Zifencei", "ma_data": "can truy cap lech do phan cung xu ly"}
CORES = [("single-cycle", "-DSC", ["rv32i_core.v"], "rv32im"),
         ("pipeline RV32I", "-DPIPE", ["rv32i_pipeline.v"], "rv32i"),
         ("pipeline RV32IM", "-DPIPE_FULL", ["rv32im_pipeline.v", "rv32i_core.v"], "rv32im")]


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def to_hex(elf, hexf):
    binf = hexf[:-4] + ".bin"
    sh(["riscv64-unknown-elf-objcopy", "-O", "binary", elf, binf])
    d = open(binf, "rb").read()
    d += b"\0" * (-len(d) % 4)
    with open(hexf, "w") as f:
        f.write("".join("%08x\n" % int.from_bytes(d[i:i + 4], "little") for i in range(0, len(d), 4)))


GCC = ["riscv64-unknown-elf-gcc", "-mabi=ilp32", "-static", "-mcmodel=medany", "-nostdlib", "-nostartfiles",
       f"-Wl,--defsym=tohost=0x{TOHOST:x}", f"-Wl,--defsym=fromhost=0x{TOHOST + 0x40:x}"]


def build_rvtest(src, march, tmp, env):
    name = os.path.basename(os.path.dirname(src)) + "-" + os.path.splitext(os.path.basename(src))[0]
    elf = os.path.join(tmp, name + ".elf")
    macros = os.path.join(os.path.dirname(os.path.dirname(src)), "macros", "scalar")
    r = sh(GCC + [f"-march={march}", "-fvisibility=hidden", "-I", env, "-I", macros,
                  "-T", os.path.join(env, "link.ld"), src, "-o", elf])
    return (name, elf) if r.returncode == 0 else (name, None)


def build_bench(name, march, tmp):
    b = os.path.join(ROOT, "bench")
    ld = os.path.join(tmp, "bench80.ld")
    open(ld, "w").write(open(os.path.join(b, "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    elf = os.path.join(tmp, name + ".elf")
    r = sh(GCC + [f"-march={march}", "-O2", "-fno-builtin", "-fno-tree-loop-distribute-patterns",
                  f"-DSTACK_TOP=0x{BASE + 0x3F000:x}", f"-DTOHOST_ADDR=0x{TOHOST:x}",
                  f"-DRESULT_ADDR=0x{BASE + 0x30000:x}", "-T", ld,
                  os.path.join(b, "crt0.S"), os.path.join(b, name + ".c"), "-o", elf])
    if r.returncode:
        print(r.stderr); sys.exit(1)
    return name, elf


# ---- doc vet ----
def norm_store(addr, size, value):
    """(dia chi byte, so byte, gia tri) -> bo chuan hoa"""
    return (addr, size, value & ((1 << (8 * size)) - 1))


RTL_RE = re.compile(r"pc=(\w+) ins=(\w+) rd=(\d+) val=(\w+) st=(\d) addr=(\w+) data=(\w+) strb=(\w)")


def rtl_trace(lines):
    out = []
    for l in lines:
        m = RTL_RE.match(l)
        if not m:
            continue
        pc, ins, rd, val, st, addr, data, strb = m.groups()
        pc, ins, rd, val, addr, data, strb = int(pc, 16), int(ins, 16), int(rd), int(val, 16), \
            int(addr, 16), int(data, 16), int(strb, 16)
        s = None
        if st == "1":
            off = (strb & -strb).bit_length() - 1
            size = bin(strb).count("1")
            s = norm_store((addr & ~3) + off, size, data >> (8 * off))
        out.append((pc, ins, rd, val if rd else 0, s))
        if s and s[0] == TOHOST:
            break
    return out


SP_RE = re.compile(r"core\s+\d+: 3 (0x[0-9a-f]+) \((0x[0-9a-f]+)\)(.*)")


def spike_trace(path):
    out = []
    with open(path) as f:
        for l in f:
            m = SP_RE.match(l)
            if not m:
                continue
            pc, ins = int(m.group(1), 16), int(m.group(2), 16)
            if pc < BASE:                      # bootrom cua Spike
                continue
            tok = m.group(3).split()
            rd, val, s = 0, 0, None
            i = 0
            while i < len(tok):
                t = tok[i]
                if re.fullmatch(r"x\d+", t):
                    rd, val = int(t[1:]), int(tok[i + 1], 16) & 0xFFFFFFFF
                    i += 2
                elif t == "mem":
                    if i + 2 < len(tok) + 1 and i + 2 <= len(tok) - 1 and tok[i + 2].startswith("0x") \
                            and (ins & 0x7F) == 0x23:
                        size = 1 << ((ins >> 12) & 3)
                        s = norm_store(int(tok[i + 1], 16) & 0xFFFFFFFF, size, int(tok[i + 2], 16))
                        i += 3
                    else:
                        i += 2                 # load: chi co dia chi
                else:
                    i += 1                     # CSR (c768_mstatus ...) va cac truong khac
            if rd == 0:
                val = 0
            out.append((pc, ins, rd, val, s))
            if s and s[0] == TOHOST:
                break
    return out


def fmt(e):
    pc, ins, rd, val, s = e
    st = f" store[{s[0]:08x}]({s[1]}B)={s[2]:x}" if s else ""
    return f"pc={pc:08x} ins={ins:08x}" + (f" x{rd}={val:08x}" if rd else "") + st


def compare(ref, dut):
    for i, (a, b) in enumerate(zip(ref, dut)):
        if a != b:
            ctx = "\n".join("      " + fmt(x) for x in ref[max(0, i - 3):i])
            return f"lenh thu {i} lech\n{ctx}\n   Spike: {fmt(a)}\n   RTL  : {fmt(b)}"
    if len(ref) != len(dut):
        return f"so lenh khac nhau: Spike {len(ref)}, RTL {len(dut)}"
    if not ref or ref[-1][4] is None or ref[-1][4][0] != TOHOST:
        return "khong ket thuc bang ghi TOHOST"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("riscv_tests", nargs="?", default="riscv-tests")
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    ap.add_argument("--only", default="")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="cosim_")
    env = os.path.join(tmp, "env")
    os.makedirs(env)
    # moi truong riscv-tests cua repo, doi dia chi TOHOST va diem dat chuong trinh sang vung nho cua Spike
    rt_env = os.path.join(ROOT, "riscv-tests")
    open(os.path.join(env, "riscv_test.h"), "w").write(open(os.path.join(rt_env, "riscv_test.h")).read()
        .replace("#define TOHOST_ADDR 0x00100000", f"#define TOHOST_ADDR 0x{TOHOST:08x}"))
    open(os.path.join(env, "link.ld"), "w").write(open(os.path.join(rt_env, "link.ld")).read()
        .replace(". = 0x00000000;", f". = 0x{BASE:08x};"))

    progs = []      # (ten, elf, march)
    for suite, march in (("rv32ui", "rv32i"), ("rv32um", "rv32im")):
        d = os.path.join(a.riscv_tests, "isa", suite)
        for fn in sorted(os.listdir(d)):
            t = fn[:-2]
            if not fn.endswith(".S") or t in SKIP:
                continue
            name, elf = build_rvtest(os.path.join(d, fn), march, tmp, env)
            if elf is None:
                print(f"loi bien dich {name}"); sys.exit(1)
            progs.append((name, elf, march))
    progs.append(build_bench("bench", "rv32i", tmp) + ("rv32i",))
    progs.append(build_bench("bench_m", "rv32im", tmp) + ("rv32im",))
    if a.only:
        progs = [p for p in progs if a.only in p[0]]

    sims = []
    for k, (title, flag, files, arch) in enumerate(CORES):
        vvp = os.path.join(tmp, f"sim{k}.vvp")
        r = sh(["iverilog", "-g2012", "-o", vvp, flag, os.path.join(HERE, "tb_cosim.v")] +
               [os.path.join(ROOT, f) for f in files])
        if r.returncode:
            print(r.stderr); sys.exit(1)
        sims.append((title, vvp, arch))

    fails, n_instr = 0, {t: 0 for t, _, _ in sims}
    for name, elf, march in progs:
        log = elf[:-4] + ".spike.log"
        try:
            r = sh([a.spike, f"--isa={march}_zicsr", "--no-dm", f"-m0x{BASE:x}:0x200000",
                    "-l", "--log-commits", f"--log={log}", elf], timeout=120)
        except subprocess.TimeoutExpired:
            print(f"FAIL {name}: Spike khong ket thuc (chuong trinh khong ghi TOHOST?)"); fails += 1; continue
        ref = spike_trace(log)
        if r.returncode or not ref:
            print(f"FAIL {name}: Spike bao loi (ma {r.returncode})"); fails += 1; continue
        hexf = elf[:-4] + ".hex"
        to_hex(elf, hexf)
        res = []
        for title, vvp, arch in sims:
            if march == "rv32im" and arch == "rv32i":
                continue
            out = sh(["vvp", "-n", vvp, f"+prog={hexf}"], timeout=600).stdout.splitlines()
            err = compare(ref, rtl_trace(out))
            if err:
                fails += 1
                print(f"FAIL {name} tren {title}: {err}")
            else:
                n_instr[title] += len(ref)
                res.append(title)
        print(f"  {name:<18} {len(ref):>6} lenh  khop: {', '.join(res)}")

    print("So lenh da so khop voi Spike: " + ", ".join(f"{t} {n}" for t, n in n_instr.items()))
    print(f"{len(progs)} chuong trinh, {'PASS' if fails == 0 else f'FAIL {fails}'}")
    shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
