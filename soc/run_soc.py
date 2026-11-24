#!/usr/bin/env python3
"""Chay bo kiem chung cua SoC: 3 test rieng cho ngoai vi (bus/ROM/RAM/SYSCON, UART, GPIO) roi cac chuong trinh C tren SoC day du
(hello, bo nho, timer + ngat, UART, GPIO + ngat, ngat UART, PLIC, mepc voi lenh nen) va FreeRTOS (neu da build bang soc/freertos/build.sh). Moi buoc in mot dong; thoat ma 1 neu co buoc nao that bai.
Dung: python3 soc/run_soc.py [--build] [--stop-first]   (--build: bien dich lai phan mem bang soc/sw/build.sh truoc khi chay)"""
import os, subprocess, sys, time, shutil, argparse, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORE = ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v", "rv32_mtimer.v"]
UNITS = [("bus", ["soc_bus.v", "soc_rom.v", "soc_ram.v", "soc_syscon.v"]),
         ("gpio", ["soc_gpio.v"]),
         ("uart", ["soc_uart.v"]),
         ("uart_fifo", ["soc_uart.v"]),
         ("mtimer", ["../rv32_mtimer.v"]),
         ("plic", ["soc_plic.v"])]
# (ten chuong trinh, kich ban kich thich cua tb_soc, so chu ky toi da)
PROGS = [("hello", 0), ("t_mem", 0), ("t_mepc", 0), ("t_timer", 0), ("t_gpio", 2), ("t_uart", 1), ("t_irq_uart", 3), ("t_ramexec", 0), ("t_plic", 4)]


def sh(cmd, cwd, timeout=600):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", timeout=timeout)
    return p.returncode, p.stdout


def run_suite(rtl_root, sw_dir, work, stop_first=False, verbose=True, rtos=False):
    """rtl_root: thu muc co soc/ va cac file loi; sw_dir: noi co <ten>.hex va .exp. Tra ve danh sach (ten, dat, thong_tin, giay)."""
    res = []

    def add(name, ok, info, t0):
        res.append((name, ok, info, time.time() - t0))
        if verbose:
            print("[soc] %-22s %s  %s (%.1f s)" % (name, "DAT   " if ok else "THAT BAI", info, time.time() - t0), flush=True)
        return ok or not stop_first

    soc = lambda f: os.path.join(rtl_root, "soc", f)
    for name, files in UNITS:
        t0 = time.time()
        exe = os.path.join(work, "tb_" + name)
        rc, out = sh(["iverilog", "-g2012", "-o", exe, soc("tb/tb_%s.v" % name)] + [soc(f) for f in files], rtl_root)
        if rc != 0:
            add("tb_" + name, False, "loi bien dich: " + out.strip().splitlines()[-1][:100] if out.strip() else "loi bien dich", t0)
            return res
        rc, out = sh(["vvp", "-n", exe], rtl_root)
        line = [l for l in out.splitlines() if l.startswith("[%s]" % name.upper())]
        ok = rc == 0 and any("PASS" in l for l in line)
        if not add("tb_" + name, ok, (line[-1] if line else out.strip()[-100:]), t0):
            return res
    t0 = time.time()
    exe = os.path.join(work, "tb_soc")
    socfiles = [soc(f) for f in sorted(os.listdir(os.path.join(rtl_root, "soc"))) if f.startswith("soc_") and f.endswith(".v")]
    rc, out = sh(["iverilog", "-g2012", "-o", exe, soc("tb/tb_soc.v")] + socfiles + [os.path.join(rtl_root, f) for f in CORE], rtl_root)
    if rc != 0:
        add("tb_soc (bien dich)", False, out.strip().splitlines()[-1][:100], t0)
        return res
    for prog, scn in PROGS:
        t0 = time.time()
        args = ["vvp", "-n", exe, "+rom=%s/%s.hex" % (sw_dir, prog), "+exp=%s/../%s.exp" % (sw_dir, prog), "+scn=%d" % scn, "+max=400000"]
        try:
            rc, out = sh(args, rtl_root, timeout=300)
        except subprocess.TimeoutExpired:
            rc, out = 1, "het gio (vvp)"
        line = [l for l in out.splitlines() if l.startswith("[SOC]")]
        ok = rc == 0 and any("PASS" in l for l in line) and not any("FAIL" in l or "LOI" in l for l in line)
        if not add(prog, ok, (line[0] if ok and line else (line[-1] if line else out.strip()[-100:])), t0):
            return res
    if rtos:                                     # FreeRTOS: build bang soc/freertos/build.sh; trap/mark_wake lay tu ELF de do tre ngat
        t0 = time.time()
        fr = os.path.join(rtl_root, "soc", "freertos")
        elf = os.path.join(fr, "build", "rtos_demo.elf")
        sym = {}
        for l in sh(["riscv64-unknown-elf-nm", elf], rtl_root)[1].splitlines():
            f = l.split()
            if len(f) == 3:
                sym[f[2]] = f[0]
        args = ["vvp", "-n", exe, "+rom=%s/build/rtos_demo.hex" % fr, "+exp=%s/rtos_demo.exp" % fr, "+scn=5", "+max=400000",
                "+trap=" + sym["freertos_risc_v_trap_handler"], "+wake=" + sym["mark_wake"]]
        try:
            rc, out = sh(args, rtl_root, timeout=600)
        except subprocess.TimeoutExpired:
            rc, out = 1, "het gio (vvp)"
        line = [l for l in out.splitlines() if l.startswith("[SOC]")]
        ok = rc == 0 and any("PASS" in l for l in line) and not any("FAIL" in l or "LOI" in l for l in line)
        add("rtos_demo (FreeRTOS)", ok, (line[0] if ok and line else (line[-1] if line else out.strip()[-100:])), t0)
        if ok and verbose:
            for l in line[1:]:
                print("      " + l)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true", help="bien dich lai phan mem truoc")
    ap.add_argument("--stop-first", action="store_true")
    a = ap.parse_args()
    if a.build:
        rc, out = sh(["sh", os.path.join(HERE, "sw", "build.sh")], ROOT)
        print(out.strip())
        if rc != 0:
            sys.exit(1)
    sw = os.path.join(HERE, "sw", "build")
    if not os.path.exists(os.path.join(sw, "hello.hex")):
        print("chua co soc/sw/build/*.hex: chay voi --build (can riscv64-unknown-elf-gcc)")
        sys.exit(1)
    with tempfile.TemporaryDirectory() as work:
        res = run_suite(ROOT, sw, work, a.stop_first, rtos=os.path.exists(os.path.join(HERE, "freertos", "build", "rtos_demo.hex")))
    bad = [r for r in res if not r[1]]
    print("[soc] %s: %d/%d buoc dat" % ("DAT" if not bad else "THAT BAI", len(res) - len(bad), len(res)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
