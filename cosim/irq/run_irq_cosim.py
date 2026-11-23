#!/usr/bin/env python3
"""So vet tung lenh voi Spike khi co ngat (pipeline RV32IM, tb_cosim.v -DIRQ + cosim/irq/spike_irq.cc).

Chuong trinh: irq_storm.S (ngat timer / phan mem / ngoai xen moi loai lenh, ECALL, doan khoa ngat, WFI; ban -DMA co them
truy cap lech dia chi) va cac benchmark C (bench, bench_m, bench_call, CoreMark 1 vong) chay duoi "bao" ngat qua
crt0_irq.S. Moi chuong trinh chay tren nhieu cau hinh loi va nhieu seed cua nguon ngat ngoai ngau nhien.
Spike duoc dung nhu thu vien (can ban Spike cai kem header va libriscv, vd. /opt/spike tu tools/setup_env.sh).
Dung (tu thu muc goc repo): python3 cosim/irq/run_irq_cosim.py [--spike /opt/spike/bin/spike] [--quick]
                            [--core <chuoi>] [--only <chuoi>] [--seeds N] [--stop-on-fail]
"""
import argparse, os, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "cosim"))
sys.path.insert(0, os.path.join(ROOT, "coremark"))
import run_cosim as rc            # noqa: E402

BASE, TOHOST = rc.BASE, rc.TOHOST
PIPE = ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v", "rv32_mtimer.v"]
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
]


def exts(march):
    return rc.exts(march)


def build_storm(march, tmp, ma=False):
    name = f"irq_storm-{march.split('_')[0][4:]}" + ("-ma" if ma else "")
    elf = os.path.join(tmp, name + ".elf")
    ld = os.path.join(tmp, "irq80.ld")
    open(ld, "w").write(open(os.path.join(ROOT, "bench", "bench.ld")).read().replace(". = 0x0;", f". = 0x{BASE:x};"))
    r = rc.sh(rc.GCC + [f"-march={rc.gcc_march(march)}_zicsr", f"-DTOHOST_ADDR=0x{TOHOST:x}", "-I", HERE] +
              (["-DMA"] if ma else []) + ["-T", ld, os.path.join(HERE, "irq_storm.S"), "-o", elf])
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
    ap.add_argument("--core", default="")
    ap.add_argument("--only", default="")
    ap.add_argument("--seeds", type=int, default=2, help="so seed nguon ngat ngoai cho moi cap (chuong trinh, loi)")
    ap.add_argument("--irqext", type=int, default=250, help="ngat ngoai ngau nhien: trung binh moi N chu ky")
    ap.add_argument("--stop-on-fail", action="store_true")
    ap.add_argument("--tmax", type=int, default=20_000_000, help="so chu ky toi da moi lan chay RTL")
    ap.add_argument("--rtl-dir", default=ROOT, help="thu muc chua RTL (mutation test dung ban sao)")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="irqcs_")
    exe = build_harness(a.spike, tmp)

    progs = [build_storm("rv32im", tmp) + ("rv32im",), build_storm("rv32imc", tmp) + ("rv32imc",),
             build_storm("rv32imc", tmp, ma=True) + ("rv32imc_zicclsm",),
             build_bench_irq("bench", "rv32ic", tmp) + ("rv32ic",),
             build_bench_irq("bench_m", "rv32imc", tmp) + ("rv32imc",),
             build_bench_irq("bench_call", "rv32ic", tmp) + ("rv32ic",),
             build_bench_irq("bench_m", "rv32im", tmp) + ("rv32im",)]
    cores = CORES
    seeds = a.seeds
    if a.quick:
        cores, seeds = [CORES[0], CORES[1]], 1
    else:
        import run_coremark as cm
        cm.fetch_src()
        elf = cm.build("rv32imc", 1, tmp, crt0=os.path.join(HERE, "crt0_irq.S"), inc=[HERE])[0]
        progs.append(("coremark-irq-c", elf, "rv32imc"))
    if a.only:
        progs = [p for p in progs if a.only in p[0]]
    cores = [c for c in cores if a.core in c[0]]

    sims = []
    for k, (title, flags, files, isa, plus) in enumerate(cores):
        vvp = os.path.join(tmp, f"irq{k}.vvp")
        r = rc.sh(["iverilog", "-g2012", "-o", vvp, "-DPIPE_FULL", "-DIRQ"] + flags.split() +
                  [os.path.join(ROOT, "cosim", "tb_cosim.v")] + [os.path.join(a.rtl_dir, f) for f in files])
        if r.returncode:
            sys.exit(r.stderr)
        sims.append((title, vvp, isa, plus))

    jobs = [(p, s, sd) for p in progs for s in sims if exts(p[2]) <= exts(s[2]) for sd in range(1, seeds + 1)]
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
        r = rc.sh([exe, binf, trf, "_".join([base] + sorted(z + ["zicsr", "zifencei"]))])
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
