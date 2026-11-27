#!/usr/bin/env python3
"""Chay bo kiem chung cua SoC: 3 test rieng cho ngoai vi (bus/ROM/RAM/SYSCON, UART, GPIO) roi cac chuong trinh C tren SoC day du
(hello, bo nho, timer + ngat, UART, GPIO + ngat, ngat UART, PLIC, mepc voi lenh nen) va FreeRTOS (neu da build bang soc/freertos/build.sh). Moi buoc in mot dong; thoat ma 1 neu co buoc nao that bai.
Dung: python3 soc/run_soc.py [--build] [--stop-first]   (--build: bien dich lai phan mem bang soc/sw/build.sh truoc khi chay)"""
import os, subprocess, sys, time, shutil, argparse, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORE = ["rv32im_pipeline.v", "rv32i_core.v", "rv32c_decompress.v", "rv32_mtimer.v", "rv32_mmu.v"]
CORE_AXI = CORE + ["rv32_icache.v", "rv32_dcache.v"]
AXI_RTL = ["axi/axi_soc_top.v", "axi/axi_xbar.v", "axi/axi_mem.v", "axi/axi_cache_if.v", "axi/axi_periph_bridge.v", "axi/axi_dma.v", "axi/axi_checker.v"]
# bo kiem rieng cua bus AXI4: cau ngoai vi (W tre, burst), interconnect + bo nho + bo kiem giao thuc voi 3 master ngau nhien (nhieu hat giong)
UNITS_AXI = [("axi_br", ["axi/axi_periph_bridge.v"], ["+seed=1", "+seed=2", "+seed=3"]),
              ("axi_rand", ["axi/axi_xbar.v", "axi/axi_mem.v", "axi/axi_checker.v"], ["+seed=1", "+seed=2", "+seed=3", "+seed=4", "+seed=5"])]
UNITS = [("bus", ["soc_bus.v", "soc_rom.v", "soc_ram.v", "soc_syscon.v"]),
         ("gpio", ["soc_gpio.v"]),
         ("uart", ["soc_uart.v"]),
         ("uart_fifo", ["soc_uart.v"]),
         ("mtimer", ["../rv32_mtimer.v"]),
         ("plic", ["soc_plic.v"]),
         ("plic_s", ["soc_plic.v"]),                    # PLIC hai context (M + S) so voi mo hinh ngau nhien
         ("ram", ["mem/rv32_ram.v"]),                    # bo boc RAM doc dong bo: phien ban mo phong
         ("ram_ihp", ["mem/rv32_ram.v", "mem/ihp_sram_stub.v"], {"tb": "ram", "flags": ["-DRV32_RAM_IHP"]})]   # phien ban macro IHP (qua stub giao dien gia dinh)
# (ten chuong trinh, kich ban kich thich cua tb_soc, so chu ky toi da)
# cau hinh Linux (--su): SoC voi SU = MMU = 1, CLINT bo cuc chuan, PLIC context S; chay lai moi chuong trinh o che do M (phan cung S / U khong duoc lam hong) va them t_su
SU_PROGS = [("t_su", 4)]
SU_UNITS = [("plic_s", ["soc_plic.v"])]
PROGS = [("hello", 0), ("t_mem", 0), ("t_mepc", 0), ("t_timer", 0), ("t_gpio", 2), ("t_uart", 1), ("t_irq_uart", 3), ("t_ramexec", 0), ("t_plic", 4)]


def sh(cmd, cwd, timeout=600):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", timeout=timeout)
    return p.returncode, p.stdout


def run_suite(rtl_root, sw_dir, work, stop_first=False, verbose=True, rtos=False, axi=False, axi_units=True, su=False):
    """rtl_root: thu muc co soc/ va cac file loi; sw_dir: noi co <ten>.hex va .exp. Tra ve danh sach (ten, dat, thong_tin, giay)."""
    res = []

    def add(name, ok, info, t0):
        res.append((name, ok, info, time.time() - t0))
        if verbose:
            print("[soc] %-22s %s  %s (%.1f s)" % (name, "DAT   " if ok else "THAT BAI", info, time.time() - t0), flush=True)
        return ok or not stop_first

    soc = lambda f: os.path.join(rtl_root, "soc", f)
    for name, files, *opt in (SU_UNITS if su else ([] if axi else UNITS)):
        t0 = time.time()
        exe = os.path.join(work, "tb_" + name)
        o = opt[0] if opt else {}
        rc, out = sh(["iverilog", "-g2012"] + o.get("flags", []) + ["-o", exe, soc("tb/tb_%s.v" % o.get("tb", name))] + [soc(f) for f in files], rtl_root)
        if rc != 0:
            add("tb_" + name, False, "loi bien dich: " + out.strip().splitlines()[-1][:100] if out.strip() else "loi bien dich", t0)
            return res
        rc, out = sh(["vvp", "-n", exe], rtl_root)
        line = [l for l in out.splitlines() if l.startswith("[%s]" % name.upper())]
        ok = rc == 0 and any("PASS" in l for l in line)
        if not add("tb_" + name, ok, (line[-1] if line else out.strip()[-100:]), t0):
            return res
    if axi and axi_units and not su:
        for name, files, seeds in UNITS_AXI:
            t0 = time.time()
            exe = os.path.join(work, "tb_" + name)
            rc, out = sh(["iverilog", "-g2012", "-o", exe, soc("tb/tb_%s.v" % name)] + [soc(f) for f in files], rtl_root)
            if rc != 0:
                add("tb_" + name, False, "loi bien dich: " + (out.strip().splitlines()[-1][:100] if out.strip() else ""), t0)
                return res
            ok, info = True, ""
            for sd in seeds:
                rc, out = sh(["vvp", "-n", exe, sd], rtl_root, timeout=900)
                line = [l for l in out.splitlines() if l.startswith("[%s]" % name.upper())]
                ok = ok and rc == 0 and any("PASS" in l for l in line)
                info = line[-1] if line else out.strip()[-100:]
                if not ok:
                    break
            if not add("tb_" + name + " (%d hat)" % len(seeds), ok, info, t0):
                return res
    t0 = time.time()
    exe = os.path.join(work, "tb_soc")
    if axi:
        socfiles = [soc(f) for f in sorted(os.listdir(os.path.join(rtl_root, "soc"))) if f.startswith("soc_") and f.endswith(".v") and f not in ("soc_top.v", "soc_rom.v", "soc_ram.v")] + [soc(f) for f in AXI_RTL]
        core, defs, progs, tag = CORE_AXI, ["-DAXI"], PROGS + [("t_dma", 0)], "axi: "
    else:
        socfiles = [soc(f) for f in sorted(os.listdir(os.path.join(rtl_root, "soc"))) if f.startswith("soc_") and f.endswith(".v")]
        core, defs, progs, tag = CORE, [], PROGS, ""
    if su:
        defs, progs, tag = defs + ["-DSUCFG", "-DSEIP_PIN"], progs + SU_PROGS, "su: " + tag
    rc, out = sh(["iverilog", "-g2012"] + defs + ["-o", exe, soc("tb/tb_soc.v")] + socfiles + [os.path.join(rtl_root, f) for f in core], rtl_root)
    if rc != 0:
        add("tb_soc (bien dich)", False, out.strip().splitlines()[-1][:100], t0)
        return res
    for prog, scn in progs:
        t0 = time.time()
        args = ["vvp", "-n", exe, "+rom=%s/%s.hex" % (sw_dir, prog), "+exp=%s/../%s.exp" % (sw_dir, prog), "+scn=%d" % scn, "+max=400000"]
        try:
            rc, out = sh(args, rtl_root, timeout=300)
        except subprocess.TimeoutExpired:
            rc, out = 1, "het gio (vvp)"
        line = [l for l in out.splitlines() if l.startswith("[SOC]")]
        ok = rc == 0 and any("PASS" in l for l in line) and not any("FAIL" in l or "LOI" in l for l in line)
        if not add(tag + prog, ok, (line[0] if ok and line else (line[-1] if line else out.strip()[-100:])), t0):
            return res
    if rtos:                                     # FreeRTOS: build bang soc/freertos/build.sh; trap/mark_wake lay tu ELF de do tre ngat
        t0 = time.time()
        fr = os.path.join(rtl_root, "soc", "freertos")
        bd = ("build_axi" if axi else "build") + ("_su" if su else "")
        elf = os.path.join(fr, bd, "rtos_demo.elf")
        sym = {}
        for l in sh(["riscv64-unknown-elf-nm", elf], rtl_root)[1].splitlines():
            f = l.split()
            if len(f) == 3:
                sym[f[2]] = f[0]
        args = ["vvp", "-n", exe, "+rom=%s/%s/rtos_demo.hex" % (fr, bd), "+exp=%s/rtos_demo.exp" % fr, "+scn=5", "+max=400000",
                "+trap=" + sym["freertos_risc_v_trap_handler"], "+wake=" + sym["mark_wake"]]
        try:
            rc, out = sh(args, rtl_root, timeout=600)
        except subprocess.TimeoutExpired:
            rc, out = 1, "het gio (vvp)"
        line = [l for l in out.splitlines() if l.startswith("[SOC]")]
        ok = rc == 0 and any("PASS" in l for l in line) and not any("FAIL" in l or "LOI" in l for l in line)
        add(tag + "rtos_demo (FreeRTOS)", ok, (line[0] if ok and line else (line[-1] if line else out.strip()[-100:])), t0)
        if ok and verbose:
            for l in line[1:]:
                print("      " + l)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true", help="bien dich lai phan mem truoc")
    ap.add_argument("--stop-first", action="store_true")
    ap.add_argument("--su", action="store_true", help="cau hinh Linux: SU = MMU = 1, CLINT bo cuc chuan, PLIC context S (phan mem trong soc/sw/build_su; ket hop duoc voi --axi)")
    ap.add_argument("--axi", action="store_true", help="chay bo kiem tren SoC AXI4 (soc/axi/axi_soc_top.v, phan mem trong soc/sw/build_axi)")
    a = ap.parse_args()
    if a.build:
        for envx in ([dict({"AXI": "1"} if a.axi else {}, **({"SU": "1"} if a.su else {}))]):
            rc, out = subprocess.run(["sh", os.path.join(HERE, "sw", "build.sh")], cwd=ROOT, env=dict(os.environ, **envx), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).returncode, ""
            if rc != 0:
                sys.exit(1)
    bd = ("build_axi" if a.axi else "build") + ("_su" if a.su else "")
    sw = os.path.join(HERE, "sw", bd)
    if not os.path.exists(os.path.join(sw, "hello.hex")):
        print("chua co soc/sw/build/*.hex: chay voi --build (can riscv64-unknown-elf-gcc)")
        sys.exit(1)
    with tempfile.TemporaryDirectory() as work:
        res = run_suite(ROOT, sw, work, a.stop_first, rtos=os.path.exists(os.path.join(HERE, "freertos", bd, "rtos_demo.hex")), axi=a.axi, su=a.su)
    bad = [r for r in res if not r[1]]
    print("[soc] %s: %d/%d buoc dat" % ("DAT" if not bad else "THAT BAI", len(res) - len(bad), len(res)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
