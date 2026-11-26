#!/usr/bin/env python3
"""So vet tung lenh voi Spike khi co ngat (pipeline RV32IM, tb_cosim.v -DIRQ + cosim/irq/spike_irq.cc).

Chuong trinh: irq_storm.S (ngat timer / phan mem / ngoai xen moi loai lenh, ECALL, doan khoa ngat, WFI; ban -DMA co them
truy cap lech dia chi) va cac benchmark C (bench, bench_m, bench_call, CoreMark 1 vong) chay duoi "bao" ngat qua
crt0_irq.S. Moi chuong trinh chay tren nhieu cau hinh loi va nhieu seed cua nguon ngat ngoai ngau nhien.
Spike duoc dung nhu thu vien (can ban Spike cai kem header va libriscv, vd. /opt/spike tu tools/setup_env.sh).
Dung (tu thu muc goc repo): python3 cosim/irq/run_irq_cosim.py [--spike /opt/spike/bin/spike] [--quick]
                            [--core <chuoi>] [--only <chuoi>] [--seeds N] [--stop-on-fail]
"""
import argparse, hashlib, os, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "cosim"))
sys.path.insert(0, os.path.join(ROOT, "coremark"))
import run_cosim as rc            # noqa: E402

BASE, TOHOST = rc.BASE, rc.TOHOST
PIPE = ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v", "rv32_mtimer.v", "rv32_mmu.v"]
CACHE = PIPE + ["rv32_icache.v", "rv32_dcache.v", "rv32_bus_arbiter.v"]
C22 = "-DCACHE -DICL=2 -DICW=2 -DDCL=2 -DDCW=2"
# (ten, co -D, file RTL, ISA cua loi, plusargs)
CORES = [
    ("RV32IMC", "-DRVC", PIPE, "rv32imc", []),
    ("RV32IMC + cache 2x2, tre 1-8", "-DRVC " + C22, CACHE, "rv32imc", ["+lat=8", "+irqdly=600"]),
    ("RV32IMC nhan lap", "-DRVC -DMULLAT=0", PIPE, "rv32imc", []),
    ("RV32IM + cache 16x4 2 duong, tre 1-4", "-DCACHE -DCWY=2", CACHE, "rv32im", ["+lat=4", "+irqdly=100"]),
    ("RV32IMC lech phan cung + cache 2x2, tre 1-8", "-DRVC -DMA " + C22, CACHE, "rv32imc_zicclsm",
     ["+lat=8", "+irqdly=600"]),
    ("RV32IMC du doan ep + cache 2x2, tre 1-6", "-DRVC -DBTBN=4 -DRASN=2 -DGHRB=2 -DBTAG=1 " + C22, CACHE, "rv32imc",
     ["+lat=6", "+irqdly=500"]),
    # che do Supervisor / User (SU = 1): "xsu" chi la nhan noi bo (chuong trinh can S / U), Spike chay voi che do MSU
    ("RV32IMC + S/U + MMU Sv32", "-DRVC -DSU -DMMUON -DBIGMEM", PIPE, "rv32imc_xsu_xmmu", []),
    ("RV32IM + S/U + cache 2x2, tre 1-8", "-DSU " + C22, CACHE, "rv32im_xsu", ["+lat=8", "+irqdly=600"]),
    ("RV32IMC + S/U + MMU Sv32 + cache 2x2, tre 1-8", "-DRVC -DSU -DMMUON -DBIGMEM " + C22, CACHE, "rv32imc_xsu_xmmu",
     ["+lat=8", "+irqdly=600"]),
    # A + S / U + MMU: AMO / SC dich nhu store (loi trang 15, loi truy cap 7), LR nhu load; AMO tranh bo duyet bang trang
    ("RV32IMAC + S/U + MMU Sv32", "-DRVC -DSU -DMMUON -DBIGMEM -DA_EXT=1", PIPE, "rv32imac_xsu_xmmu", []),
    ("RV32IMAC + S/U + MMU Sv32 + cache 2x2, tre 1-8", "-DRVC -DSU -DMMUON -DBIGMEM -DA_EXT=1 " + C22, CACHE,
     "rv32imac_xsu_xmmu", ["+lat=8", "+irqdly=600"]),
]


def exts(march):
    return rc.exts(march)


def build_storm(march, tmp, ma=False, vec=False):
    name = f"irq_storm-{march.split('_')[0][4:]}" + ("-ma" if ma else "") + ("-vec" if vec else "")
    elf = os.path.join(tmp, name + ".elf")
    ld = os.path.join(tmp, "irq80.ld")
    open(ld, "w").write(open(os.path.join(ROOT, "bench", "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    r = rc.sh(rc.GCC + [f"-march={rc.gcc_march(march)}_zicsr", f"-DTOHOST_ADDR=0x{TOHOST:x}", "-I", HERE] +
              (["-DMA"] if ma else []) + (["-DVEC"] if vec else []) + ["-T", ld, os.path.join(HERE, "irq_storm.S"), "-o", elf])
    if r.returncode:
        sys.exit(r.stderr)
    return name, elf


def build_counters(march, tmp):
    name = f"counters-{march[4:]}"
    elf = os.path.join(tmp, name + ".elf")
    ld = os.path.join(tmp, "irq80.ld")
    open(ld, "w").write(open(os.path.join(ROOT, "bench", "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    r = rc.sh(rc.GCC + [f"-march={march}_zicsr_zicntr", f"-DTOHOST_ADDR=0x{TOHOST:x}", "-I", HERE, "-T", ld,
                        os.path.join(HERE, "counters.S"), "-o", elf])
    if r.returncode:
        sys.exit(r.stderr)
    return name, elf


def build_pmp(march, tmp, ma=False):
    name = f"pmp-{march[4:]}" + ("-ma" if ma else "")
    elf = os.path.join(tmp, name + ".elf")
    ld = os.path.join(tmp, "irq80.ld")
    open(ld, "w").write(open(os.path.join(ROOT, "bench", "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    r = rc.sh(rc.GCC + [f"-march={march}_zicsr", f"-DTOHOST_ADDR=0x{TOHOST:x}", "-I", HERE] + (["-DMA"] if ma else []) +
              ["-T", ld, os.path.join(HERE, "pmp.S"), "-o", elf])
    if r.returncode:
        sys.exit(r.stderr)
    return name, elf


def build_su(march, tmp):
    name = f"su-{march[4:]}"
    elf = os.path.join(tmp, name + ".elf")
    ld = os.path.join(tmp, "irq80.ld")
    open(ld, "w").write(open(os.path.join(ROOT, "bench", "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    r = rc.sh(rc.GCC + [f"-march={march}_zicsr_zicntr", f"-DTOHOST_ADDR=0x{TOHOST:x}", "-I", HERE, "-T", ld,
                        os.path.join(HERE, "su.S"), "-o", elf])
    if r.returncode:
        sys.exit(r.stderr)
    return name, elf


# riscv-tests rv32si / rv32mi voi moi truong "p" chinh thuc (riscv-test-env): chay tren loi co S / U, Spike che do MSU.
# Bo qua: rv32si-dirty (can MMU), rv32mi-breakpoint (can trigger / Sdtrig, lo khong co), rv32mi-ma_fetch (tat bit C cua
# misa luc chay: Spike cho ghi, misa cua lo co dinh - WARL hop le nhung hai ben khac nhau)
RT_SU = [("rv32si", t) for t in ("csr", "ma_fetch", "sbreak", "scall", "wfi")] + \
        [("rv32mi", t) for t in ("csr", "mcsr", "illegal", "sbreak", "scall", "shamt", "zicntr",
                                 "instret_overflow", "pmpaddr", "ma_addr", "lh-misaligned", "lw-misaligned",
                                 "sh-misaligned", "sw-misaligned")]


def rt_env(rt, tmp):
    env = os.path.join(rt, "env", "p")
    if not os.path.isfile(os.path.join(env, "riscv_test.h")):
        env = os.path.join(tmp, "riscv-test-env", "p")
        if not os.path.isdir(env):
            r = rc.sh(["git", "clone", "-q", "--depth", "1", "https://github.com/riscv/riscv-test-env.git",
                       os.path.join(tmp, "riscv-test-env")])
            if r.returncode:
                sys.exit("khong lay duoc riscv-test-env: " + r.stderr)
    ld = os.path.join(tmp, "rt_su.ld")             # .tohost dat dung dia chi TOHOST cua testbench / harness
    open(ld, "w").write(f"""OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS {{
  . = 0x{BASE:x};
  .text.init : {{ *(.text.init) }}
  . = ALIGN(0x1000);
  .text : {{ *(.text) }}
  . = ALIGN(0x1000);
  .data : {{ *(.data) }}
  .bss : {{ *(.bss) }}
  _end = .;
  .tohost 0x{TOHOST:x} : {{ *(.tohost) }}
}}
""")
    return env, ld


def build_rt_su(rt, suite, test, march, tmp):
    env, ld = rt_env(rt, tmp)
    name = f"{suite}-{test}" + ("-c" if "c" in march[4:] else "")
    elf = os.path.join(tmp, name + ".elf")
    r = rc.sh(rc.GCC + [f"-march={march}_zicsr_zifencei", "-I", env, "-I", os.path.join(rt, "isa", "macros", "scalar"),
                        "-T", ld, os.path.join(rt, "isa", suite, test + ".S"), "-o", elf])
    if r.returncode:
        sys.exit(r.stderr)
    return name, elf


def build_mmu(march, tmp):
    name = f"mmu-{march[4:]}"
    elf = os.path.join(tmp, name + ".elf")
    ld = os.path.join(tmp, "irq80.ld")
    open(ld, "w").write(open(os.path.join(ROOT, "bench", "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    r = rc.sh(rc.GCC + [f"-march={march}_zicsr", f"-DTOHOST_ADDR=0x{TOHOST:x}", "-I", HERE, "-T", ld,
                        os.path.join(HERE, "mmu.S"), "-o", elf])
    if r.returncode:
        sys.exit(r.stderr)
    return name, elf


# riscv-tests moi truong "v" (bo nho ao Sv32 that: bang trang, phan trang theo yeu cau qua loi trang, chay o U) va
# rv32si-dirty: chi loi co MMU
RT_V = ["add", "addi", "and", "andi", "auipc", "beq", "bge", "bgeu", "blt", "bltu", "bne", "jal", "jalr", "lb", "lbu",
        "lh", "lhu", "lui", "lw", "or", "ori", "sb", "sh", "simple", "sll", "slli", "slt", "slti", "sltiu", "sltu",
        "sra", "srai", "srl", "srli", "sub", "sw", "xor", "xori", "ld_st", "st_ld"]


def build_rt_v(rt, test, march, tmp):
    rt_env(rt, tmp)
    env = os.path.join(rt, "env", "v")
    if not os.path.isfile(os.path.join(env, "vm.c")):
        env = os.path.join(tmp, "riscv-test-env", "v")
    ld = os.path.join(tmp, "rt_su.ld")
    name = f"rv32ui-v-{test}" + ("-c" if "c" in march[4:] else "")
    elf = os.path.join(tmp, name + ".elf")
    src = os.path.join(rt, "isa", "rv32ui", test + ".S")
    if not os.path.isfile(src):
        return None
    ent = int(hashlib.md5(name.encode()).hexdigest()[:7], 16)
    shim = os.path.join(tmp, "libc_shim")           # trinh bien dich khong co newlib: khai bao toi thieu cho vm.c
    if not os.path.isdir(shim):
        os.makedirs(shim)
        open(os.path.join(shim, "string.h"), "w").write(
            "#include <stddef.h>\nvoid* memcpy(void*, const void*, size_t);\nvoid* memset(void*, int, size_t);\n"
            "size_t strlen(const char*);\nint strcmp(const char*, const char*);\nint memcmp(const void*, const void*, size_t);\n"
            "char* strcpy(char*, const char*);\nlong atol(const char*);\n")
        open(os.path.join(shim, "ctype.h"), "w").write("#define isspace(c) ((c) == ' ' || ((c) >= 9 && (c) <= 13))\n"
                                                       "#define isdigit(c) ((c) >= '0' && (c) <= '9')\n")
        open(os.path.join(shim, "stdio.h"), "w").write("")
    # vm.c co ma lenh fssr lam du lieu (nhan dien test FP): bien dich them F, ma C cua vm.c khong dung so thuc
    r = rc.sh(rc.GCC + [f"-march={march}f_zicsr_zifencei", f"-DENTROPY=0x{ent:x}", "-std=gnu99", "-O2", "-I", shim, "-I", env,
                        "-I", os.path.join(rt, "isa", "macros", "scalar"), "-T", ld, os.path.join(env, "entry.S"),
                        os.path.join(env, "vm.c"), os.path.join(env, "string.c"), src, "-o", elf])
    if r.returncode:
        sys.exit(r.stderr)
    return name, elf


def build_bench_irq(bname, march, tmp):
    b = os.path.join(ROOT, "bench")
    ld = os.path.join(tmp, "irq80.ld")
    open(ld, "w").write(open(os.path.join(b, "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    name = f"{bname}-irq" + ("-c" if "c" in exts(march) else "")
    elf = os.path.join(tmp, name + ".elf")
    r = rc.sh(rc.GCC + [f"-march={march}_zicsr", "-O2", "-fno-builtin", "-fno-tree-loop-distribute-patterns",
                        f"-DSTACK_TOP=0x{BASE + 0x3F000:x}", f"-DTOHOST_ADDR=0x{TOHOST:x}",
                        f"-DRESULT_ADDR=0x{BASE + 0x30000:x}", "-I", HERE, "-T", ld,
                        os.path.join(HERE, "crt0_irq.S"), os.path.join(b, bname + ".c"), "-o", elf])
    if r.returncode:
        sys.exit(r.stderr)
    return name, elf


def to_bin_hex(elf):
    hexf = elf[:-4] + ".hex"
    rc.to_hex(elf, hexf)                  # tao ca .bin
    return elf[:-4] + ".bin", hexf


def build_harness(spike, tmp):
    prefix = os.path.dirname(os.path.dirname(os.path.realpath(spike)))
    exe = os.path.join(tmp, "spike_irq")
    r = rc.sh(["g++", "-O2", "-std=c++20", "-w", f"-I{prefix}/include", "-o", exe, os.path.join(HERE, "spike_irq.cc"),
               f"-L{prefix}/lib", "-lriscv", f"-Wl,-rpath,{prefix}/lib"])
    if r.returncode:
        sys.exit("khong bien dich duoc spike_irq.cc (can Spike cai kem include/ va lib/libriscv.so):\n" + r.stderr)
    return exe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    ap.add_argument("--quick", action="store_true", help="2 cau hinh loi, 1 seed, khong CoreMark")
    ap.add_argument("--core", default="", help="chuoi con cua ten cau hinh loi, hoac so thu tu 0-5")
    ap.add_argument("--only", default="")
    ap.add_argument("--seeds", type=int, default=2, help="so seed nguon ngat ngoai cho moi cap (chuong trinh, loi)")
    ap.add_argument("--irqext", type=int, default=250, help="ngat ngoai ngau nhien: trung binh moi N chu ky")
    ap.add_argument("--stop-on-fail", action="store_true")
    ap.add_argument("--tmax", type=int, default=20_000_000, help="so chu ky toi da moi lan chay RTL")
    ap.add_argument("--rtl-dir", default=ROOT, help="thu muc chua RTL (mutation test dung ban sao)")
    ap.add_argument("--riscv-tests", default="/tmp/riscv-tests", help="riscv-tests (rv32si / rv32mi cho loi co S / U)")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="irqcs_")
    exe = build_harness(a.spike, tmp)

    progs = [build_storm("rv32im", tmp) + ("rv32im",), build_storm("rv32imc", tmp) + ("rv32imc",),
             build_storm("rv32imc", tmp, ma=True) + ("rv32imc_zicclsm",),
             build_storm("rv32imc", tmp, vec=True) + ("rv32imc",),
             build_counters("rv32im", tmp) + ("rv32im",), build_counters("rv32imc", tmp) + ("rv32imc",),
             build_pmp("rv32im", tmp) + ("rv32im",), build_pmp("rv32imc", tmp) + ("rv32imc",),
             build_pmp("rv32imc", tmp, ma=True) + ("rv32imc_zicclsm",),
             build_su("rv32im", tmp) + ("rv32im_xsu",), build_su("rv32imc", tmp) + ("rv32imc_xsu",),
             build_mmu("rv32im", tmp) + ("rv32im_xsu_xmmu",), build_mmu("rv32imc", tmp) + ("rv32imc_xsu_xmmu",),
             build_mmu("rv32imac", tmp) + ("rv32imac_xsu_xmmu",), build_mmu("rv32ima", tmp) + ("rv32ima_xsu_xmmu",),
             build_bench_irq("bench", "rv32ic", tmp) + ("rv32ic",),
             build_bench_irq("bench_m", "rv32imc", tmp) + ("rv32imc",),
             build_bench_irq("bench_call", "rv32ic", tmp) + ("rv32ic",),
             build_bench_irq("bench_m", "rv32im", tmp) + ("rv32im",)]
    if os.path.isdir(os.path.join(a.riscv_tests, "isa", "rv32si")):
        for suite, t in RT_SU:
            for m in ("rv32im", "rv32imc"):
                progs.append(build_rt_su(a.riscv_tests, suite, t, m, tmp) + (m + "_xsu",))
        for m in ("rv32im", "rv32imc"):
            progs.append(build_rt_su(a.riscv_tests, "rv32si", "dirty", m, tmp) + (m + "_xsu_xmmu",))
        for t in RT_V:
            v = build_rt_v(a.riscv_tests, t, "rv32im", tmp)
            if v:
                progs.append(v + ("rv32im_xsu_xmmu",))
    cores = CORES
    seeds = a.seeds
    if a.quick:
        cores, seeds = [CORES[0], CORES[1], CORES[6]], 1
    elif not a.only or a.only in "coremark-irq-c":
        import run_coremark as cm
        cm.fetch_src()
        elf = cm.build("rv32imc", 1, tmp, crt0=os.path.join(HERE, "crt0_irq.S"), inc=[HERE])[0]
        progs.append(("coremark-irq-c", elf, "rv32imc"))
    if a.only:
        progs = [p for p in progs if any(o in p[0] for o in a.only.split(","))]   # nhieu chuoi cach nhau dau phay
    if a.core.isdigit():                  # so thu tu trong CORES (chia lan chay dai thanh nhieu phan)
        cores = [CORES[int(a.core)]]
    else:
        cores = [c for c in cores if a.core in c[0]]

    sims = []
    for k, (title, flags, files, isa, plus) in enumerate(cores):
        vvp = os.path.join(tmp, f"irq{k}.vvp")
        r = rc.sh(["iverilog", "-g2012", "-o", vvp, "-DPIPE_FULL", "-DIRQ"] + flags.split() +
                  [os.path.join(ROOT, "cosim", "tb_cosim.v")] + [os.path.join(a.rtl_dir, f) for f in files])
        if r.returncode:
            sys.exit(r.stderr)
        sims.append((title, vvp, isa, plus))

    # loi co mo rong A chi chay cac chuong trinh lien quan (MMU, che do S / U, PMP, bao ngat): cac chuong trinh dai (CoreMark, bench)
    # khong dung lenh A, da chay tren loi khong co A
    def a_ok(p, s):
        return "a" not in exts(s[2]) or any(k in p[0] for k in ("mmu-", "irq_storm", "su-", "pmp", "rv32si", "rv32mi", "rv32ui-v-"))
    jobs = [(p, s, sd) for p in progs for s in sims if exts(p[2]) <= exts(s[2]) and a_ok(p, s) for sd in range(1, seeds + 1)]
    tot = {"instr": 0, "irq_ext": 0, "irq_soft": 0, "irq_timer": 0, "exceptions": 0}
    on, maxlag, fails, t0 = {}, 0, 0, time.time()
    print(f"{len(progs)} chuong trinh x {len(sims)} loi x {seeds} seed = {len(jobs)} lan chay (loi chi chay chuong "
          f"trinh hop ISA)", flush=True)
    for j, ((name, elf, march), (title, vvp, isa, plus), sd) in enumerate(jobs):
        binf, hexf = to_bin_hex(elf)
        trf = os.path.join(tmp, "trace.txt")
        with open(trf, "w") as f:
            subprocess.run(["vvp", "-n", vvp, f"+prog={hexf}", f"+irqext={a.irqext}", f"+irqseed={sd}",
                            f"+seed={sd}", f"+tmax={a.tmax}"] + plus, stdout=f, timeout=3600)
        cyc = re.search(r"DONE cycles=(\d+)", open(trf).read()[-4000:])
        base, *z = isa.split("_")
        privs = "MSU" if "xsu" in z else "M"
        mmu = ["sv32"] if "xmmu" in z else []
        z = [e for e in z if e not in ("xsu", "xmmu")]
        r = rc.sh([exe, binf, trf, "_".join([base] + sorted(z + ["zicntr", "zicsr", "zifencei", "zihpm"])), privs] + mmu)
        st = re.search(r"IRQSTAT (.*)", r.stdout)
        tag = f"[{j + 1}/{len(jobs)}] {name} / {title} / seed {sd}"
        if r.returncode or not st:
            fails += 1
            msg = "\n".join(r.stdout.strip().splitlines()[:8])
            print(f"{tag}: FAIL\n{msg}", flush=True)
            if a.stop_on_fail:
                shutil.rmtree(tmp, ignore_errors=True)
                sys.exit(1)
            continue
        d = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", st.group(1))}
        for k in tot:
            tot[k] += d[k]
        maxlag = max(maxlag, d["maxlag"])
        for k, v in re.findall(r"(\S+)=(\d+)", re.search(r"IRQON(.*)", r.stdout).group(1)):
            on[k] = on.get(k, 0) + int(v)
        print(f"{tag}: khop {d['instr']} lenh, ngat ngoai/phan mem/timer {d['irq_ext']}/{d['irq_soft']}/"
              f"{d['irq_timer']}, exception {d['exceptions']}, tre nhan ngat toi da {d['maxlag']} lenh, "
              f"{cyc.group(1) if cyc else '?'} chu ky "
              f"({time.time() - t0:.0f} s)", flush=True)
    n_irq = tot["irq_ext"] + tot["irq_soft"] + tot["irq_timer"]
    print(f"TONG: {tot['instr']} lenh khop Spike, {n_irq} ngat (ngoai {tot['irq_ext']}, phan mem {tot['irq_soft']}, "
          f"timer {tot['irq_timer']}), {tot['exceptions']} exception, tre nhan ngat toi da {maxlag} lenh")
    print("Ngat roi vao lenh loai: " + ", ".join(f"{k} {v}" for k, v in sorted(on.items(), key=lambda x: -x[1])))
    print(f"{len(jobs)} lan chay, {'PASS' if fails == 0 else f'FAIL {fails}'}")
    shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
