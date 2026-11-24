#!/usr/bin/env python3
"""So vet tung lenh cua 3 loi voi Spike (trinh mo phong ISA chuan cua RISC-V).

Chuong trinh: bo test ISA riscv-tests (rv32ui, rv32um) va hai benchmark C (bench, bench_m), bien dich dat o
0x8000_0000 (ban do bo nho mac dinh cua Spike). Spike chay voi --log-commits; RTL chay cosim/tb_cosim.v voi
RESET_PC = 0x8000_0000. Moi lenh hoan tat duoc so: pc, ma lenh, thanh ghi dich va gia tri ghi, dia chi / do rong /
gia tri cua lenh store. Dung o lenh dau tien lech va in ngu canh.

Can: spike (https://github.com/riscv-software-src/riscv-isa-sim), riscv64-unknown-elf-gcc, iverilog,
     ma nguon riscv-tests.
Dung:  python3 cosim/run_cosim.py <thu_muc_riscv-tests> [--spike <duong dan spike>] [--only=<ten>] [--core=<loi>]
"""
import argparse, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BASE = 0x80000000
TOHOST = 0x80100000
SKIP = {}
# test can mo rong Z (them vao -march va --isa cua Spike; chi chay tren loi co mo rong do).
# Zicclsm (load/store lech dia chi bang phan cung, Spike chi cho phep khi co mo rong nay) chi la nhan cho Spike va de
# chon loi; GCC khong biet ten nay nen bi bo khi bien dich (xem gcc_march).
ZEXT = {"fence_i": "zifencei", "ma_data": "zicclsm"}


def gcc_march(march):
    return march.replace("_zicclsm", "")
CACHE_FILES = ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v", "rv32_icache.v", "rv32_dcache.v",
               "rv32_bus_arbiter.v"]
# Zifencei: single-cycle nap moi lenh sau khi lenh truoc xong nen tu nhien dung; pipeline RV32IM xoa cache lenh va
# nap lai khi gap FENCE.I. Pipeline RV32I coi FENCE.I la NOP nen khong ho tro.
ZBARCH = "zba_zbb_zbc_zbs_zicond"
ZBFLAGS = "-DZBA=1 -DZBB=1 -DZBS=1 -DZBC=1 -DZICOND=1"
CORES = [("single-cycle", "-DSC", ["rv32i_core.v"], "rv32im_zifencei"),
         ("pipeline RV32I", "-DPIPE", ["rv32i_pipeline.v"], "rv32i"),
         ("pipeline RV32IM", "-DPIPE_FULL", ["rv32im_pipeline.v", "rv32i_core.v"], "rv32im_zifencei"),
         ("pipeline RV32IMC", "-DPIPE_FULL -DRVC", ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"],
          "rv32imc_zifencei"),
         # co cache lenh/du lieu va bo nho chung co do tre ngau nhien
         ("RV32IMC + cache 16x4, tre 1-4", "-DPIPE_FULL -DRVC -DCACHE", CACHE_FILES, "rv32imc_zifencei",
          ["+lat=4", "+seed=1"]),
         ("RV32IMC + cache 2x2, tre 1-8", "-DPIPE_FULL -DRVC -DCACHE -DICL=2 -DICW=2 -DDCL=2 -DDCW=2", CACHE_FILES,
          "rv32imc_zifencei", ["+lat=8", "+seed=7"]),
         # cache set-associative cung dung luong: 2 duong, va 4 duong trong 1 tap duy nhat (thay the lien tuc)
         ("RV32IMC + cache 16x4 2 duong, tre 1-4", "-DPIPE_FULL -DRVC -DCACHE -DCWY=2", CACHE_FILES,
          "rv32imc_zifencei", ["+lat=4", "+seed=3"]),
         ("RV32IMC + cache 4x2 4 duong, tre 1-8", "-DPIPE_FULL -DRVC -DCACHE -DCWY=4 -DICL=4 -DICW=2 -DDCL=4 -DDCW=2",
          CACHE_FILES, "rv32imc_zifencei", ["+lat=8", "+seed=11"]),
         # load/store lech dia chi bang phan cung (MISALIGNED = 1): bo nho to hop, va qua cache 2x2 de truy cap vat
         # qua tu cung vat qua dong cache, va cham bo dem ghi
         ("RV32IMC lech phan cung", "-DPIPE_FULL -DRVC -DMA", ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"],
          "rv32imc_zifencei_zicclsm"),
         ("RV32IMC lech phan cung + cache 2x2, tre 1-8", "-DPIPE_FULL -DRVC -DMA -DCACHE -DICL=2 -DICW=2 -DDCL=2 -DDCW=2",
          CACHE_FILES, "rv32imc_zifencei_zicclsm", ["+lat=8", "+seed=5"]),
         # bo du doan "ep loi": BTB 4 muc tag 1 bit (trung nham lien tuc), RAS 2 muc, gshare 2 bit, qua cache 2x2
         # 2 kieu bo nhan con lai (mac dinh MUL_LAT = 2): lap nhu ban cu, va song song xong trong 1 chu ky
         ("RV32IMC nhan lap", "-DPIPE_FULL -DRVC -DMULLAT=0", ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"],
          "rv32imc_zifencei"),
         ("RV32IMC nhan 1 chu ky + cache 2x2, tre 1-8", "-DPIPE_FULL -DRVC -DMULLAT=1 -DCACHE -DICL=2 -DICW=2 -DDCL=2 -DDCW=2",
          CACHE_FILES, "rv32imc_zifencei", ["+lat=8", "+seed=13"]),
         ("RV32IMC du doan ep + cache 2x2, tre 1-6", "-DPIPE_FULL -DRVC -DCACHE -DICL=2 -DICW=2 -DDCL=2 -DDCW=2 -DBTBN=4 "
          "-DRASN=2 -DGHRB=2 -DBTAG=1", CACHE_FILES, "rv32imc_zifencei", ["+lat=6", "+seed=9"]),
         # Zba, Zbb, Zbs, Zbc, Zicond (tham so ZBA... = 1): chay them zb.S va benchmark / CoreMark bien dich co Zb
         ("RV32IMC + Zba/Zbb/Zbs/Zbc/Zicond", "-DPIPE_FULL -DRVC " + ZBFLAGS,
          ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v"], "rv32imc_zifencei_" + ZBARCH),
         ("RV32IMC + Zb* + cache 2x2, tre 1-8", "-DPIPE_FULL -DRVC -DCACHE -DICL=2 -DICW=2 -DDCL=2 -DDCW=2 " + ZBFLAGS,
          CACHE_FILES, "rv32imc_zifencei_" + ZBARCH, ["+lat=8", "+seed=17"])]


def exts(march):
    """'rv32imc_zifencei' -> {'i', 'm', 'c', 'zifencei'}"""
    base, *z = march.split("_")
    return set(base[4:]) | set(z)


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
    name = os.path.basename(os.path.dirname(src)) + "-" + os.path.splitext(os.path.basename(src))[0] + \
        ("-c" if "c" in exts(march) else "")
    elf = os.path.join(tmp, name + ".elf")
    macros = os.path.join(os.path.dirname(os.path.dirname(src)), "macros", "scalar")
    r = sh(GCC + [f"-march={gcc_march(march)}", "-fvisibility=hidden", "-I", env, "-I", macros,
                  "-T", os.path.join(env, "link.ld"), src, "-o", elf])
    return (name, elf) if r.returncode == 0 else (name, None)


def build_asm(src, march, tmp):
    """Chuong trinh assembly tu viet trong cosim/tests (dung bench.ld, dat o BASE)."""
    name = "tests-" + os.path.splitext(os.path.basename(src))[0]
    ld = os.path.join(tmp, "bench80.ld")
    open(ld, "w").write(open(os.path.join(ROOT, "bench", "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    elf = os.path.join(tmp, name + ".elf")
    r = sh(GCC + [f"-march={gcc_march(march)}", f"-DTOHOST_ADDR=0x{TOHOST:x}", "-T", ld, src, "-o", elf])
    if r.returncode:
        print(r.stderr); sys.exit(1)
    return name, elf


def build_bench(name, march, tmp):
    b = os.path.join(ROOT, "bench")
    ld = os.path.join(tmp, "bench80.ld")
    open(ld, "w").write(open(os.path.join(b, "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    tag = name + ("-c" if "c" in exts(march) else "") + ("-zb" if any(e.startswith("zb") for e in exts(march)) else "")
    elf = os.path.join(tmp, tag + ".elf")
    r = sh(GCC + [f"-march={march}", "-O2", "-fno-builtin", "-fno-tree-loop-distribute-patterns",
                  f"-DSTACK_TOP=0x{BASE + 0x3F000:x}", f"-DTOHOST_ADDR=0x{TOHOST:x}",
                  f"-DRESULT_ADDR=0x{BASE + 0x30000:x}", "-T", ld,
                  os.path.join(b, "crt0.S"), os.path.join(b, name + ".c"), "-o", elf])
    if r.returncode:
        print(r.stderr); sys.exit(1)
    return tag, elf


# ---- doc vet ----
def norm_store(addr, size, value):
    """(dia chi byte, so byte, gia tri) -> bo chuan hoa"""
    return (addr, size, value & ((1 << (8 * size)) - 1))


RTL_RE = re.compile(r"pc=(\w+) ins=(\w+) rd=(\w+) val=(\w+) st=(\w) addr=(\w+) data=(\w+) strb=(\w+)")  # store vat qua tu: data 64 bit, strb 8 bit


def rtl_trace(lines):
    out = []
    for l in lines:
        m = RTL_RE.match(l)
        if not m:
            continue
        pc, ins, rd, val, st, addr, data, strb = m.groups()
        try:
            pc, ins, rd, val, addr, data, strb = int(pc, 16), int(ins, 16), int(rd), int(val, 16), \
                int(addr, 16), int(data, 16), int(strb, 16)
            if st not in ("0", "1"):
                raise ValueError(st)
        except ValueError:                     # gia tri X/Z trong RTL: chac chan lech
            out.append((-1, 0, 0, 0, l.strip()))
            break
        if ins in TRAPPING:                     # ECALL/EBREAK/C.EBREAK vao trap, Spike khong ghi vao vet cam ket
            continue
        s = None
        if st == "1":
            off = (strb & -strb).bit_length() - 1
            size = bin(strb).count("1")
            s = norm_store((addr & ~3) + off, size, data >> (8 * off))
        out.append((pc, ins, rd, val if rd else 0, s))
        if s and s[0] == TOHOST:
            break
    return out


TRAPPING = (0x00000073, 0x00100073, 0x9002)

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
                    if i + 2 <= len(tok) - 1 and tok[i + 2].startswith("0x"):     # store: "mem dia_chi gia_tri"
                        # lenh nen chi co c.sw / c.swsp (4 byte); lenh 32 bit: do rong theo funct3
                        size = 4 if (ins & 3) != 3 else 1 << ((ins >> 12) & 3)
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
    if pc < 0:
        return f"gia tri X/Z: {s}"
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
    # moi chuong trinh (riscv-tests, benchmark, test tu viet) ghi 1 vao TOHOST khi tu kiem dat; gia tri khac la
    # chuong trinh tu bao loi, ke ca khi Spike va RTL cung sai giong nhau
    if ref[-1][4][2] != 1:
        return f"chuong trinh tu bao loi: TOHOST = {ref[-1][4][2]:#x}"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("riscv_tests", nargs="?", default="riscv-tests")
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    ap.add_argument("--no-coremark", action="store_true", help="bo CoreMark (can lay ma nguon tu GitHub)")
    ap.add_argument("--only", default="", help="chi chay chuong trinh co ten chua chuoi nay (vd. --only=-c)")
    ap.add_argument("--core", default="", help="chi chay loi co ten chua chuoi nay (vd. --core=RV32IMC)")
    ap.add_argument("--stop-on-fail", action="store_true", help="dung o chuong trinh lech dau tien (mutation test)")
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

    # Moi chuong trinh duoc bien dich 2 lan: khong co C (cho ca 4 loi) va voi -march=...c (trinh hop dich tu nen
    # lenh nao nen duoc, chi chay tren loi co ENABLE_C). rv32uc (rvc.S) chi co ban C.
    progs = []      # (ten, elf, march)
    # bo test Zba/Zbb/Zbc/Zbs/Zicond cua riscv-tests: bien dich voi -march tuong ung, chi chay tren loi co phan mo rong do
    zsuites = tuple((d, "rv32im_" + d[5:]) for d in ("rv32uzba", "rv32uzbb", "rv32uzbc", "rv32uzbs", "rv32uzicond")
                    if os.path.isdir(os.path.join(a.riscv_tests, "isa", d)))
    for suite, march in (("rv32ui", "rv32i"), ("rv32um", "rv32im"), ("rv32ui", "rv32ic"), ("rv32um", "rv32imc"),
                         ("rv32uc", "rv32ic")) + zsuites:
        d = os.path.join(a.riscv_tests, "isa", suite)
        for fn in sorted(os.listdir(d)):
            t = fn[:-2]
            if not fn.endswith(".S") or t in SKIP:
                continue
            m = march + ("_" + ZEXT[t] if t in ZEXT else "")
            name, elf = build_rvtest(os.path.join(d, fn), m, tmp, env)
            if elf is None:
                print(f"loi bien dich {name}"); sys.exit(1)
            progs.append((name, elf, m))
    # test tu viet: FENCE.I voi ma tu sua (chi chay tren loi co Zifencei); xung dot cache (moi loi)
    progs.append(build_asm(os.path.join(HERE, "tests", "fencei.S"), "rv32i_zifencei", tmp) + ("rv32i_zifencei",))
    progs.append(build_asm(os.path.join(HERE, "tests", "conflict.S"), "rv32i", tmp) + ("rv32i",))
    # load/store lech dia chi moi do rong, moi vi tri byte, vat qua tu va dong cache (chi loi co lech bang phan cung)
    progs.append(build_asm(os.path.join(HERE, "tests", "misaligned.S"), "rv32i_zicclsm", tmp) + ("rv32i_zicclsm",))
    # mepc bit 1 khi co C: trap tai pc = 2 mod 4, ghi/doc mepc (loi that do riscv-formal csrw_mepc tim ra)
    progs.append(build_asm(os.path.join(HERE, "tests", "mepc_c.S"), "rv32ic_zicsr", tmp) + ("rv32ic",))
    progs.append(build_bench("bench", "rv32i", tmp) + ("rv32i",))
    progs.append(build_bench("bench_m", "rv32im", tmp) + ("rv32im",))
    progs.append(build_bench("bench", "rv32ic", tmp) + ("rv32ic",))
    progs.append(build_bench("bench_m", "rv32imc", tmp) + ("rv32imc",))
    progs.append(build_bench("bench_call", "rv32i", tmp) + ("rv32i",))
    progs.append(build_bench("bench_call", "rv32ic", tmp) + ("rv32ic",))
    # Zba/Zbb/Zbs/Zbc/Zicond: test tu viet zb.S (moi lenh, gia tri bien, hazard) va benchmark bien dich co Zb
    # (trinh bien dich tu dung shNadd, andn, min/max, rori, bset...): chi chay tren loi co cac phan mo rong nay
    progs.append(build_asm(os.path.join(HERE, "tests", "zb.S"), "rv32im_" + ZBARCH, tmp) + ("rv32im_" + ZBARCH,))
    progs.append(build_bench("bench", "rv32imc_zba_zbb_zbs", tmp) + ("rv32imc_zba_zbb_zbs",))
    progs.append(build_bench("bench_m", "rv32imc_zba_zbb_zbs", tmp) + ("rv32imc_zba_zbb_zbs",))
    progs.append(build_bench("bench_call", "rv32imc_zba_zbb_zbs", tmp) + ("rv32imc_zba_zbb_zbs",))
    # CoreMark 1 vong (ma nguon EEMBC lay tu GitHub, port o coremark/port): so tung lenh, khoang 313 nghin lenh
    if not a.no_coremark:
        sys.path.insert(0, os.path.join(ROOT, "coremark"))
        import run_coremark as cm
        cm.fetch_src()
        progs.append(("coremark", cm.build("rv32im", 1, tmp)[0], "rv32im"))
        progs.append(("coremark-zb", cm.build("rv32imc_zba_zbb_zbs", 1, tmp)[0], "rv32imc_zba_zbb_zbs"))
    if a.only:
        progs = [p for p in progs if a.only in p[0]]

    sims = []
    for k, (title, flag, files, arch, *plus) in enumerate(c for c in CORES if a.core in c[0]):
        vvp = os.path.join(tmp, f"sim{k}.vvp")
        r = sh(["iverilog", "-g2012", "-o", vvp] + flag.split() + [os.path.join(HERE, "tb_cosim.v")] +
               [os.path.join(ROOT, f) for f in files])
        if r.returncode:
            print(r.stderr); sys.exit(1)
        sims.append((title, vvp, arch, plus[0] if plus else []))

    fails, n_instr = 0, {t: 0 for t, _, _, _ in sims}
    for name, elf, march in progs:
        log = elf[:-4] + ".spike.log"
        try:
            base, *z = march.split("_")
            isa = "_".join([base] + sorted(z + ["zicsr"]))
            r = sh([a.spike, f"--isa={isa}", "--no-dm", f"-m0x{BASE:x}:0x200000",
                    "-l", "--log-commits", f"--log={log}", elf], timeout=120)
        except subprocess.TimeoutExpired:
            print(f"FAIL {name}: Spike khong ket thuc (chuong trinh khong ghi TOHOST?)"); fails += 1; continue
        ref = spike_trace(log)
        if r.returncode or not ref:
            print(f"FAIL {name}: Spike bao loi (ma {r.returncode})"); fails += 1; continue
        hexf = elf[:-4] + ".hex"
        to_hex(elf, hexf)
        res = []
        for title, vvp, arch, plus in sims:
            if not exts(march) <= exts(arch):            # chuong trinh dung mo rong ma loi khong co
                continue
            out = sh(["vvp", "-n", vvp, f"+prog={hexf}"] + plus, timeout=600).stdout.splitlines()
            err = compare(ref, rtl_trace(out))
            if err:
                fails += 1
                print(f"FAIL {name} tren {title}: {err}", flush=True)
                if a.stop_on_fail:
                    shutil.rmtree(tmp, ignore_errors=True)
                    sys.exit(1)
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
