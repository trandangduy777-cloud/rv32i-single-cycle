#!/usr/bin/env python3
"""Kiem thu Debug Module qua JTAG that: Verilator (debug/rv32_dbg_top.v + tb_main.cpp, remote_bitbang) + OpenOCD (cong Tcl) + gdb.
  python3 debug/run_dbg_test.py [--build] [--only ten1,ten2] [--list]
Moi bai test dung mo phong moi (hart dung o lenh dau, --halt-at-start). Can: verilator, openocd, gdb-multiarch, riscv64-unknown-elf-gcc, spike."""
import argparse, os, random, re, shutil, subprocess, sys, tempfile, time, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import dbglib
from dbglib import Sim

GCC = ["riscv64-unknown-elf-gcc", "-march=rv32im_zicsr", "-mabi=ilp32", "-O0", "-g", "-nostdlib", "-nostartfiles", "-static",
       "-Wl,--no-warn-rwx-segments", "-T", os.path.join(HERE, "fw", "link.ld")]
BUILD = os.path.join(tempfile.gettempdir(), "dbgfw")
FILES = ["debug/rv32_dbg_top.v", "debug/rv32_dm.v", "debug/rv32_dtm.v", "debug/rv32_dbg_hart.v", "rv32im_pipeline.v", "rv32i_core.v",
         "rv32c_decompress.v", "rv32_mtimer.v", "rv32_mmu.v"]
GPR = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "fp", "s1", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4",
       "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"]
TESTS = {}
_port = [int(os.environ.get("DBG_PORT_BASE", "9900"))]


def test(f):
    TESTS[f.__name__[2:]] = f
    return f


def build_sim(rtl_dir=ROOT, out="/tmp/vdbg", extra=()):
    """Verilator build cua rv32_dbg_top; rtl_dir cho mutation test (ban sao RTL)"""
    shutil.rmtree(out, ignore_errors=True)
    r = subprocess.run(["verilator", "--cc", "--exe", "--build", "--no-timing", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-BLKLOOPINIT",
                        "-O2", "-j", "2", "-DDBG", "--top-module", "rv32_dbg_top", "-Mdir", out, "-o", "Vdbg"] + list(extra) +
                       [os.path.join(rtl_dir, f) for f in FILES] + [os.path.join(HERE, "tb_main.cpp")], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout[-3000:] + r.stderr[-3000:])
    return os.path.join(out, "Vdbg")


def fw(name, defs=()):
    """dich debug/fw/<name>.c|.S thanh hex, tra ve (hex, elf)"""
    os.makedirs(BUILD, exist_ok=True)
    elf, hexf = os.path.join(BUILD, name + ".elf"), os.path.join(BUILD, name + ".hex")
    src = os.path.join(HERE, "fw", name + (".S" if os.path.exists(os.path.join(HERE, "fw", name + ".S")) else ".c"))
    crt = [] if src.endswith(".S") else [os.path.join(HERE, "fw", "crt0.S")]
    r = subprocess.run(GCC + list(defs) + crt + [src, "-o", elf], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr)
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", elf, elf[:-4] + ".bin"], check=True)
    d = open(elf[:-4] + ".bin", "rb").read()
    d += b"\0" * (-len(d) % 4)
    open(hexf, "w").write("".join("%08x\n" % int.from_bytes(d[i:i + 4], "little") for i in range(0, len(d), 4)))
    return hexf, elf


def sym(elf, name):
    out = subprocess.run(["riscv64-unknown-elf-nm", elf], capture_output=True, text=True).stdout
    return int(re.search(r"^([0-9a-f]+) . " + re.escape(name) + r"$", out, re.M).group(1), 16)


def new_sim(prog, **kw):
    _port[0] += 2
    return Sim(prog, rbb=_port[0], tcl=_port[0] + 1, **kw)


def wait_tohost(s, timeout=30):
    t = time.time()
    while time.time() - t < timeout:
        m = re.search(r"TOHOST 0x([0-9a-f]+)", s.sim_text())
        if m:
            return int(m.group(1), 16)
        time.sleep(0.05)
    return None


def expect(cond, msg):
    if not cond:
        raise AssertionError(msg)


def run_until_halted(s, timeout=20):
    """cho den khi muc tieu dung (trigger / ebreak...)"""
    t = time.time()
    while time.time() - t < timeout:
        r = s.cmd("poll; riscv.cpu curstate") if False else s.cmd("riscv.cpu curstate")
        if "halted" in r:
            return True
        time.sleep(0.02)
    return False


# ---------------------------------------------------------------------------------------------------------------- DMI thuan
@test
def t_dmi_regs():
    hexf, _ = fw("spin")
    with new_sim(hexf) as s:
        s.cmd("poll off")
        s.dmi_write(0x10, 0x00000001)
        s.dmi_write(0x10, 0x10000001)       # ackhavereset do OpenOCD / boot de lai
        s.dmi_write(0x10, 0x00000001)
        st = s.dmi_read(0x11)
        expect(st & 0xF == 2, f"dmstatus.version {st:#x}")
        expect(st >> 22 & 1, "impebreak")
        expect(st >> 7 & 1, "authenticated")
        expect(st & 0x300 == 0x300, f"hart phai dang dung (boot halt): {st:#x}")
        expect(st >> 10 & 3 == 0, "running khi dang dung")
        expect(s.dmi_read(0x12) == 0x00100000, "hartinfo")
        acs = s.dmi_read(0x16)
        expect(acs >> 24 & 0x1F == 8 and acs & 0xF == 2 and acs >> 8 & 7 == 0 and not acs >> 12 & 1, f"abstractcs {acs:#x}")
        expect(s.dmi_read(0x38) == 0 and s.dmi_read(0x50) == 0 and s.dmi_read(0x7F) == 0, "thanh ghi khong co phai doc 0")
        expect(s.dmi_read(0x40) == 1, "haltsum0")
        # data / progbuf
        for a, v in ((0x04, 0xA5A5A5A5), (0x05, 0x5A5A5A5A)) + tuple((0x20 + i, 0x11111111 * (i + 1)) for i in range(8)):
            s.dmi_write(a, v)
        for a, v in ((0x04, 0xA5A5A5A5), (0x05, 0x5A5A5A5A)) + tuple((0x20 + i, 0x11111111 * (i + 1)) for i in range(8)):
            expect(s.dmi_read(a) == v, f"doc lai {a:#x}")
        # lenh khong ho tro -> cmderr = 2, xoa bang ghi 1 vao cmderr
        for cmd in (0x00321000 | 0x00020000 | 0x00000000,        # aarsize = 3 (64 bit)
                    0x00221020,                                    # regno 0x1020 (FPR)
                    0x01221000,                                    # cmdtype 1 (quick access)
                    0x00281000 | 0x00020000):                      # aarpostincrement
            s.dmi_write(0x17, cmd)
            e = s.dmi_read(0x16) >> 8 & 7
            expect(e == 2, f"cmd {cmd:#x}: cmderr {e}")
            s.dmi_write(0x16, 0x700)
            expect(s.dmi_read(0x16) >> 8 & 7 == 0, "xoa cmderr")
        # cmderr dinh: lenh moi bi bo qua cho toi khi xoa
        s.dmi_write(0x17, 0x00321000)
        s.dmi_write(0x04, 0x12345678)
        s.dmi_write(0x17, 0x00221000 | 10)                          # lenh hop le nhung cmderr con -> khong chay
        expect(s.dmi_read(0x16) >> 8 & 7 == 2, "cmderr dinh")
        expect(s.dmi_read(0x04) == 0x12345678, "lenh bi bo qua khi cmderr != 0: data0 khong duoc doi")
        s.dmi_write(0x16, 0x700)
        # doc / ghi thanh ghi tru tuong hop le: ghi data0 -> a0 roi doc a1..a0
        s.dmi_write(0x04, 0xCAFEF00D)
        s.dmi_write(0x17, 0x00230000 | 0x1000 | 10)                 # write a0 = data0
        expect(s.dmi_read(0x16) >> 8 & 7 == 0 and not s.dmi_read(0x16) >> 12 & 1, "ghi a0")
        s.dmi_write(0x04, 0)
        s.dmi_write(0x17, 0x00220000 | 0x1000 | 10)                 # read a0 -> data0
        expect(s.dmi_read(0x04) == 0xCAFEF00D, "doc a0 qua data0")
        # hartsel = 1: khong ton tai
        s.dmi_write(0x10, 0x00010001)
        st = s.dmi_read(0x11)
        expect(st >> 14 & 3 == 3 and st >> 8 & 3 == 0 and st >> 10 & 3 == 0, f"hartsel 1: {st:#x}")
        s.dmi_write(0x10, 0x00000001)
        # lenh khi dang chay: cmderr = 4
        s.dmi_write(0x10, 0x40000001)                               # resumereq
        for _ in range(50):
            if s.dmi_read(0x11) >> 17 & 1:
                break
        st = s.dmi_read(0x11)
        expect(st >> 16 & 3 == 3 and st >> 10 & 3 == 3 and st >> 8 & 3 == 0, f"sau resume: {st:#x}")
        s.dmi_write(0x17, 0x00220000 | 0x1000 | 10)
        expect(s.dmi_read(0x16) >> 8 & 7 == 4, "lenh khi dang chay phai cmderr 4")
        s.dmi_write(0x16, 0x700)
        s.dmi_write(0x10, 0x00000000); s.dmi_write(0x10, 0x00000001)   # dmactive 0 -> 1: xoa resumeack, hart van chay
        expect(s.dmi_read(0x11) >> 16 & 3 == 0 and s.dmi_read(0x11) >> 10 & 3 == 3, "resumeack = 0, hart van chay")
        s.dmi_write(0x10, 0x40000001)                               # resumereq khi dang chay: bi bo qua
        s.dmi_write(0x10, 0x80000001)                               # roi halt: phai dung han, khong tu chay lai
        time.sleep(0.05)
        st = s.dmi_read(0x11)
        expect(st >> 8 & 3 == 3 and st >> 16 & 3 == 0, f"halt sau resumereq thua: phai giu halted, resumeack = 0: {st:#x}")
        time.sleep(0.05)
        expect(s.dmi_read(0x11) >> 8 & 3 == 3, "van halted")
        s.dmi_write(0x10, 0x00000001)
        # haltreq va resumereq cung luc: bo qua resumereq
        pc0 = s.reg("dpc")
        s.dmi_write(0x10, 0x00000000); s.dmi_write(0x10, 0x00000001)   # xoa resumeack (hart van halted)
        expect(s.dmi_read(0x11) >> 16 & 3 == 0 and s.dmi_read(0x11) >> 8 & 3 == 3, "resumeack = 0, hart van halted")
        s.dmi_write(0x10, 0xC0000001)
        expect(s.dmi_read(0x11) >> 8 & 3 == 3 and s.dmi_read(0x11) >> 16 & 3 == 0, "resumereq bi bo khi haltreq = 1 (khong resumeack)")
        expect(s.reg("dpc") == pc0, "resumereq cung haltreq khong duoc chay lenh nao")
        s.dmi_write(0x10, 0x00000001)
        # ackhavereset
        s.dmi_write(0x10, 0x80000003); s.dmi_write(0x10, 0x80000001); s.dmi_write(0x10, 0x00000001)
        expect(s.dmi_read(0x11) >> 18 & 3 == 3, "havereset sau ndmreset")
        s.dmi_write(0x10, 0x10000001)
        expect(s.dmi_read(0x11) >> 18 & 3 == 0, "ackhavereset")
        s.dmi_write(0x04, 0xCAFEF00D)
        # dmactive = 0 reset DM: cmderr xoa, thanh ghi data khong ghi duoc
        s.dmi_write(0x17, 0x00321000)
        expect(s.dmi_read(0x16) >> 8 & 7 == 2, "tao cmderr")
        s.dmi_write(0x10, 0x00000000)
        expect(s.dmi_read(0x10) & 1 == 0 and s.dmi_read(0x16) >> 8 & 7 == 0, "dmactive = 0 xoa cmderr")
        s.dmi_write(0x04, 0x77777777)
        expect(s.dmi_read(0x04) == 0xCAFEF00D, "khi dmactive = 0 ghi data0 bi bo")
        s.dmi_write(0x10, 0x00000001)
        return "dmstatus, hartinfo, abstractcs, data / progbuf, cmderr 2 / 4, hartsel, haltreq / resumereq, havereset, dmactive"


@test
def t_dmi_busy_exc():
    hexf, _ = fw("spin")
    with new_sim(hexf) as s:
        s.cmd("poll off")
        s.dmi_write(0x20, 0xFFFFFFFF)                               # lenh bat hop le trong progbuf
        s.dmi_write(0x21, 0x00100073)
        s.dmi_write(0x17, 0x00240000)                               # postexec, khong transfer
        acs = s.dmi_read(0x16)
        expect(acs >> 8 & 7 == 3 and not acs >> 12 & 1, f"exception trong progbuf phai cmderr 3, busy 0: {acs:#x}")
        s.dmi_write(0x16, 0x700)
        # progbuf hop le tra lai binh thuong
        s.dmi_write(0x20, 0x00000013)                               # nop
        s.dmi_write(0x17, 0x00240000)
        expect(s.dmi_read(0x16) >> 8 & 7 == 0, "progbuf nop")
        # vong lap vo tan trong progbuf: busy = 1, truy cap data bi tu choi voi cmderr = 1
        s.dmi_write(0x20, 0x0000006F)                               # jal x0, 0
        s.dmi_write(0x17, 0x00240000)
        acs = s.dmi_read(0x16)
        expect(acs >> 12 & 1 and acs >> 8 & 7 == 0, f"busy: {acs:#x}")
        s.dmi_write(0x04, 1)
        acs = s.dmi_read(0x16)
        expect(acs >> 8 & 7 == 1 and acs >> 12 & 1, f"ghi data0 khi busy phai cmderr 1: {acs:#x}")
        s.dmi_write(0x16, 0x700)
        s.dmi_write(0x17, 0x00240000)                               # lenh moi khi busy: van cmderr 1
        expect(s.dmi_read(0x16) >> 8 & 7 == 1, "command khi busy")
        s.dmi_write(0x16, 0x700)
        def recover():
            s.dmi_write(0x10, 0x80000003)
            s.dmi_write(0x10, 0x80000001)
            for _ in range(100):
                if s.dmi_read(0x11) >> 9 & 1:
                    break
            s.dmi_write(0x10, 0x00000001)
            s.dmi_write(0x16, 0x700)
            expect(s.dmi_read(0x16) >> 8 & 7 == 0 and not s.dmi_read(0x16) >> 12 & 1, "khoi phuc sau ndmreset")
        # doc data0 / ghi progbuf khi busy: moi lan mot cmderr = 1 rieng
        recover()
        s.dmi_write(0x20, 0x0000006F); s.dmi_write(0x17, 0x00240000)
        s.dmi_read(0x04)
        acs = s.dmi_read(0x16)
        expect(acs >> 8 & 7 == 1 and acs >> 12 & 1, f"doc data0 khi busy phai cmderr 1: {acs:#x}")
        recover()
        s.dmi_write(0x20, 0x0000006F); s.dmi_write(0x17, 0x00240000)
        s.dmi_write(0x21, 0x00000013)
        acs = s.dmi_read(0x16)
        expect(acs >> 8 & 7 == 1 and acs >> 12 & 1, f"ghi progbuf khi busy phai cmderr 1: {acs:#x}")
        # ndmreset khoi phuc: hart khoi dong lai, dung o lenh dau (boot khong con, dung haltreq)
        s.dmi_write(0x10, 0x80000003)                               # haltreq + ndmreset
        s.dmi_write(0x10, 0x80000001)
        for _ in range(100):
            st = s.dmi_read(0x11)
            if st >> 9 & 1:
                break
        expect(st >> 8 & 3 == 3 and st >> 18 & 3 == 3, f"sau ndmreset: halted + havereset: {st:#x}")
        expect(not s.dmi_read(0x16) >> 12 & 1, "busy xoa sau reset")
        s.dmi_write(0x10, 0x00000001)
        s.dmi_write(0x16, 0x700)                                    # cmderr khong xoa khi busy: xoa sau reset
        s.dmi_write(0x17, 0x00220000 | 0x1000 | 8)                  # doc s0 -> data0
        acs = s.dmi_read(0x16); expect(acs >> 8 & 7 == 0, f"lenh sau reset: abstractcs {acs:#x} dmstatus {s.dmi_read(0x11):#x}")
        return "exception progbuf -> cmderr 3, busy + cmderr 1, ndmreset khoi phuc"


# ---------------------------------------------------------------------------------------------------------------- thanh ghi / bo nho
@test
def t_regs_csrs():
    hexf, _ = fw("spin")
    with new_sim(hexf) as s:
        rnd = random.Random(1)
        vals = {}
        for r in GPR[1:]:
            vals[r] = rnd.getrandbits(32)
            s.wreg(r, vals[r])
        for r in GPR[1:]:
            expect(s.reg(r) == vals[r], f"{r}: {s.reg(r):#x} != {vals[r]:#x}")
        s.wreg("zero", 0x1234)
        expect(s.reg("zero") == 0, "x0 phai 0")
        # tron thu tu: doc / ghi xen ke khong lam hong nhau (s0 va s1 bi OpenOCD dung lam tam)
        for _ in range(3):
            s.mem(0x80000000, 4)
            expect(s.reg("fp") == vals["fp"] and s.reg("s1") == vals["s1"], "s0 / s1 bi lam hong sau doc bo nho")
        s.wmem(0x80002000, [1, 2, 3])
        expect(s.reg("fp") == vals["fp"] and s.reg("s1") == vals["s1"], "s0 / s1 bi lam hong sau ghi bo nho")
        for name, mask in (("mscratch", 0xFFFFFFFF), ("mtvec", 0xFFFFFFFD), ("mepc", 0xFFFFFFFC), ("mcause", 0xFFFFFFFF),
                           ("mtval", 0xFFFFFFFF), ("mie", 0x888),
                           ("tdata2", 0xFFFFFFFF)):
            for v in (0xFFFFFFFF, 0xA5A5A5A5, 0):
                s.wreg(name, v)
                got = s.reg(name)
                expect(got == (v & mask), f"{name}: ghi {v:#x} doc {got:#x}, ky vong {v & mask:#x}")
        expect(s.reg("misa") == 0x40001100, f"misa {s.reg('misa'):#x}")
        expect(s.reg("mvendorid") == 0 and s.reg("mhartid") == 0, "mvendorid / mhartid")
        expect(s.reg("tselect") == 0, "tselect")
        expect(s.reg("tinfo") == 4, f"tinfo {s.reg('tinfo'):#x}")
        s.wreg("tselect", 1)
        expect(s.reg("tselect") == 1, "tselect = 1")
        s.wreg("tselect", 2)
        expect(s.reg("tselect") == 1, "tselect >= NT khong doi")
        s.wreg("tselect", 0)
        expect(s.reg("tdata1") >> 28 == 2, "tdata1.type = 2")
        s.wreg("dpc", 0x80000010)
        expect(s.reg("dpc") == 0x80000010 and s.reg("pc") == 0x80000010, "dpc / pc")
        d = s.reg("dcsr")
        expect(d >> 28 == 4 and d & 3 == 3 and (d >> 6 & 7) == 3, f"dcsr {d:#x}")
        # CSR khong ton tai: loi
        r = s.cmd("reg sscratch")
        expect("0x" not in r or "not" in r.lower() or "fail" in r.lower() or "error" in r.lower(), f"CSR S phai bao loi: {r}")
        return "31 GPR, x0, s0/s1 giu nguyen, mscratch/mtvec/mepc/mcause/mtval/mie, dscratch, tselect/tdata, dpc, dcsr, CSR khong co"


def _raw_jtag(port):
    """ket noi thang toi Vdbg bang giao thuc remote_bitbang (khong OpenOCD) de kiem tra TAP"""
    import socket
    c = socket.create_connection(("localhost", port), timeout=5)

    def clk(tms, tdi=0):
        c.sendall(bytes([ord("0") + (tms << 1) + tdi]))             # TCK = 0
        c.sendall(b"R")
        v = c.recv(1)
        c.sendall(bytes([ord("0") + 4 + (tms << 1) + tdi]))         # TCK = 1
        return 1 if v == b"1" else 0

    def shift(nbits, tdi=0, last=True):
        out = 0
        for i in range(nbits):
            out |= clk(1 if (last and i == nbits - 1) else 0, tdi >> i & 1) << i
        return out
    return c, clk, shift


@test
def t_idcode():
    hexf, _ = fw("spin")
    _port[0] += 2
    sim = subprocess.Popen([dbglib.VDBG, "--port", str(_port[0]), "--timeout", "30", "--halt-at-start", f"+prog={hexf}"], stdout=subprocess.DEVNULL)
    time.sleep(0.4)
    try:
        c, clk, shift = _raw_jtag(_port[0])
        for _ in range(6):
            clk(1)                                                   # Test-Logic-Reset
        for t in (0, 1, 0, 0):                                       # RTI, Select-DR, Capture-DR, Shift-DR
            clk(t)
        idc = shift(32)
        expect(idc == 0x10002001, f"DR sau reset TAP (IR = IDCODE mac dinh) phai la IDCODE: {idc:#x}")
        for t in (1, 0, 1, 1, 0, 0):                                 # Update-DR > RTI > Select-DR > Select-IR > Capture-IR > Shift-IR
            clk(t)
        shift(5, 0x10)                                               # IR = DTMCS
        for t in (1, 0, 1, 0, 0):                                    # Update-IR > RTI > Select-DR > Capture-DR > Shift-DR
            clk(t)
        d = shift(32)
        expect(d & 0xF == 1 and d >> 4 & 0x3F == 7 and d >> 12 & 7 == 1, f"dtmcs {d:#x}")
        c.close()
    finally:
        sim.kill(); sim.wait()
    return "IDCODE 0x10002001 sau reset TAP (JTAG thang, khong OpenOCD), dtmcs version 1 / abits 7 / idle 1"


@test
def t_mem():
    hexf, _ = fw("spin")
    with new_sim(hexf) as s:
        rnd = random.Random(2)
        base = 0x80010000
        blk = [rnd.getrandbits(32) for _ in range(64)]
        s.wmem(base, blk)
        expect(s.mem(base, 64) == blk, "khoi 64 tu")
        # byte / halfword
        s.wmem(base, [0], 32)
        s.cmd(f"write_memory 0x{base + 1:x} 8 {{0xAB}}")
        expect(s.mem(base)[0] == 0x0000AB00, "ghi 1 byte o +1")
        s.cmd(f"write_memory 0x{base + 2:x} 16 {{0xBEEF}}")
        expect(s.mem(base)[0] == 0xBEEFAB00, "ghi halfword o +2")
        expect(s.mem(base + 3, 1, 8) == [0xBE], "doc byte")
        expect(s.mem(base + 2, 1, 16) == [0xBEEF], "doc halfword")
        # chuong trinh nap: dung nhu hex
        words = [int(x, 16) for x in open(hexf).read().split()]
        expect(s.mem(0x80000000, len(words)) == words, "noi dung chuong trinh nap")
        return "khoi 64 tu, byte / halfword, doc lai chuong trinh nap"


# ---------------------------------------------------------------------------------------------------------------- step, resume
def spike_pcs(elf, n):
    spike = os.environ.get("SPIKE", shutil.which("spike") or "/opt/spike/bin/spike")
    r = subprocess.run([spike, "--isa=rv32im_zicsr", "-m0x80000000:0x200000", f"--instructions={n}", "-l", elf], capture_output=True, text=True)
    pcs = [int(m.group(1), 16) for m in re.finditer(r"core\s+0: 0x([0-9a-f]{8}) \(", r.stderr + r.stdout)]
    return [p for p in pcs if p >= 0x80000000]


@test
def t_step_spike():
    hexf, elf = fw("target")
    n = int(os.environ.get("DBG_STEPS", "1200"))
    golden = spike_pcs(elf, n + 20)
    expect(len(golden) > n, f"spike chi cho {len(golden)} lenh")
    with new_sim(hexf) as s:
        expect(s.reg("pc") == golden[0], "pc ban dau")
        for k in range(1, n):
            s.cmd("step")
            pc = s.reg("pc")
            expect(pc == golden[k], f"buoc {k}: pc {pc:#x}, spike {golden[k]:#x}")
        return f"{n} lenh single-step khop Spike"


@test
def t_halt_resume_stress():
    hexf, elf = fw("stress")
    rnd = random.Random(3)
    prog = sym(elf, "progress")
    with new_sim(hexf, timeout=240) as s:
        halts, last = 0, 0
        s.cmd("resume")
        t0 = time.time()
        while wait_tohost(s, 0.0) is None and time.time() - t0 < 90:
            time.sleep(rnd.uniform(0.005, 0.05))
            s.cmd("halt")
            halts += 1
            pc, dpc = s.reg("pc"), s.reg("dpc")
            expect(pc == dpc and 0x80000000 <= pc < 0x80000800, f"pc {pc:#x} dpc {dpc:#x}")
            p = s.mem(prog)[0]
            expect(p >= last, f"progress lui: {p} < {last}")
            last = p
            for _ in range(rnd.choice((0, 0, 1, 2, 5))):
                s.cmd("step")
            s.cmd("resume")
        v = wait_tohost(s, 20)
        expect(v == 1, f"checksum sai sau {halts} lan halt / resume (TOHOST {v})")
        return f"{halts} lan halt / step / resume ngau nhien, checksum dung"


@test
def t_ebreak():
    hexf, elf = fw("ebrk")
    eb = sym(elf, "ebreak_here")
    with new_sim(hexf) as s:                     # ebreakm = 0: trap
        s.cmd("riscv set_ebreakm off")
        s.cmd("resume")
        expect(wait_tohost(s) == 1, "ebreakm = 0: ebreak phai trap vao handler")
    with new_sim(hexf) as s:                     # ebreakm = 1: halt
        s.cmd("riscv set_ebreakm on")
        s.cmd("resume")
        expect(run_until_halted(s), "ebreakm = 1: phai dung")
        d = s.reg("dcsr")
        expect(d >> 6 & 7 == 1, f"cause phai = 1 (ebreak): {d:#x}")
        expect(s.reg("dpc") == eb, f"dpc {s.reg('dpc'):#x} != {eb:#x}")
        expect(s.reg("mcause") == 0 and s.reg("mepc") == 0, "ebreak vao D-mode khong ghi mepc / mcause")
        s.wreg("dpc", eb + 4)
        s.cmd("resume")
        expect(wait_tohost(s) == 3, "sau khi bo qua ebreak chuong trinh chay tiep")
    with new_sim(hexf) as s:                     # trigger va EBREAK cung mot lenh: trigger uu tien (cause 2)
        s.cmd("riscv set_ebreakm on")
        s.cmd(f"bp 0x{eb:x} 4 hw")
        s.cmd("resume")
        expect(run_until_halted(s), "bp o ebreak: phai dung")
        expect(s.reg("dcsr") >> 6 & 7 == 2 and s.reg("dpc") == eb, f"trigger uu tien hon ebreak: dcsr {s.reg('dcsr'):#x}")
    return "ebreakm 0 -> trap, ebreakm 1 -> halt cause 1, dpc, khong ghi mepc, trigger + ebreak cung lenh -> cause 2"


@test
def t_step_trap():
    hexf, elf = fw("trapstep")
    ec, h = sym(elf, "ecall_here"), sym(elf, "handler")
    with new_sim(hexf) as s:
        for _ in range(20):
            if s.reg("pc") == ec:
                break
            s.cmd("step")
        expect(s.reg("pc") == ec, "toi ecall")
        s.cmd("step")
        expect(s.reg("dcsr") >> 6 & 7 == 4, f"cause sau step phai = 4: {s.reg('dcsr'):#x}")
        expect(s.reg("pc") == h, f"step qua ecall phai den dau handler: {s.reg('pc'):#x}")
        expect(s.reg("mcause") == 11 and s.reg("mepc") == ec, "mcause / mepc")
        for _ in range(5):
            s.cmd("step")
        expect(s.reg("pc") == ec + 4, f"sau mret: {s.reg('pc'):#x}")
        s.cmd("resume")
        expect(wait_tohost(s) == 1, "chay tiep")
    return "step qua ECALL vao handler, mcause 11, mret ve ecall + 4"


@test
def t_step_irq():
    hexf, elf = fw("irqstep")
    loop = sym(elf, "loop")
    with new_sim(hexf) as s:
        for _ in range(12):
            s.cmd("step")                          # toi vong lap (da bat MIE / MEIE)
        s.wmem(0x80100008, [1])                    # tao ngat ngoai
        pcs = []
        for _ in range(30):
            s.cmd("step")
            pcs.append(s.reg("pc"))
        expect(all(loop <= p <= loop + 4 for p in pcs), f"khi step ngat bi che, pc phai o trong vong lap: {[hex(p) for p in pcs[:6]]}")
        expect(s.mem(0x80100008)[0] in (0, 1), "ok")
        s.cmd("resume")
        time.sleep(0.3)
        s.cmd("halt")
        expect(s.reg("s2") >= 1, "ngat phai duoc nhan sau resume")
        return "ngat bi che khi step, duoc nhan sau resume"


def _bubble_expect():
    M = 0xFFFFFFFF
    x, acc = 0x2545F491, 0
    for _ in range(30000):
        x ^= (x << 13) & M; x ^= x >> 17; x ^= (x << 5) & M
        acc = (acc + x) & M if x & 1 else acc ^ x
    return acc


@test
def t_halt_bubbles():
    """halt / step / resume ngau nhien khi pipeline lien tuc co bong bay (nhanh doan sai): dpc phai dung o moi chu ky"""
    hexf, elf = fw("bubble", [f"-DEXPECT={_bubble_expect()}"])
    rnd = random.Random(7)
    with new_sim(hexf, timeout=240) as s:
        s.cmd("resume")
        halts, t0 = 0, time.time()
        while wait_tohost(s, 0.0) is None and time.time() - t0 < 100:
            time.sleep(rnd.uniform(0.0, 0.02))
            s.cmd("halt")
            halts += 1
            for _ in range(rnd.choice((0, 0, 1, 3))):
                s.cmd("step")
            s.cmd("resume")
        expect(wait_tohost(s, 60) == 1, f"acc cuoi sai sau {halts} lan halt: dpc sai o chu ky bong bay")
        return f"{halts} lan halt / step / resume ngau nhien tren nhanh khong doan truoc duoc, ket qua dung"


@test
def t_halt_in_stall():
    """halt khi lenh M (nhan / chia) dang chay: chia / nhan phai cho xong, ket qua dung"""
    hexf, elf = fw("stress")
    with new_sim(hexf, timeout=120) as s:
        rnd = random.Random(5)
        s.cmd("resume")
        for k in range(300):
            s.cmd("halt")
            s.cmd("resume")
        expect(wait_tohost(s, 60) == 1, "checksum dung sau 300 lan halt lien tiep")
        return "300 lan halt / resume lien tiep, checksum dung"


@test
def t_reset():
    hexf, elf = fw("target")
    with new_sim(hexf) as s:
        s.cmd("resume")
        expect(wait_tohost(s) == 1, "chay den het")
        s.cmd("reset halt")
        expect(s.reg("pc") == 0x80000000, f"sau reset halt pc = {s.reg('pc'):#x}")
        d = s.reg("dcsr")
        expect(d >> 6 & 7 == 3, f"cause {d >> 6 & 7}")
        s.wmem(0x80003FF0, [0])
        s.cmd("resume")
        t = time.time()
        while time.time() - t < 20 and s.sim_text().count("TOHOST") < 2:
            time.sleep(0.05)
        expect(s.sim_text().count("TOHOST") >= 2, "sau reset phai chay lai tu dau va ket thuc")
        return "reset halt (ndmreset + haltreq), chay lai tu dau"


# ---------------------------------------------------------------------------------------------------------------- trigger
@test
def t_triggers():
    hexf, elf = fw("target")
    fib, ctr = sym(elf, "fib"), sym(elf, "counter")
    with new_sim(hexf) as s:
        s.cmd(f"wp 0x{ctr:x} 4 w")                  # trigger store: dung ngay sau lenh ghi counter dau tien
        s.cmd("resume")
        expect(run_until_halted(s), "wp: phai dung")
        expect(s.reg("dcsr") >> 6 & 7 == 2, "wp: cause = 2")
        expect(s.reg("tdata1") >> 20 & 1, "wp: hit = 1")
        n0 = s.mem(ctr)[0]
        s.cmd(f"rwp 0x{ctr:x}")
        s.cmd(f"bp 0x{fib:x} 4 hw")
        s.cmd("resume")
        expect(run_until_halted(s), "bp: phai dung")
        expect(s.reg("pc") == fib, f"bp pc {s.reg('pc'):#x}")
        expect(s.reg("dcsr") >> 6 & 7 == 2, "bp: cause = 2 (trigger)")
        expect(s.mem(ctr)[0] == 10, "counter = 10 khi toi fib")
        s.cmd(f"rbp 0x{fib:x}")
        s.cmd("resume")
        expect(wait_tohost(s) == 1, "chay tiep den het")
    with new_sim(hexf) as s:                         # 2 trigger cung luc + NAPOT (watch 16 byte)
        s.cmd(f"bp 0x{fib:x} 4 hw")
        s.cmd(f"wp 0x{ctr & ~0xF:x} 16 w")
        s.cmd("resume")
        expect(run_until_halted(s), "dung lan 1")
        first = s.reg("pc")
        expect(first != fib, f"lan 1 phai la watchpoint (trong main), pc {first:#x}")
        stores = 1
        while True:                                  # 5 lenh ghi counter trong main, roi breakpoint o fib
            s.cmd("resume")
            expect(run_until_halted(s), "dung tiep")
            if s.reg("pc") == fib:
                break
            stores += 1
            expect(stores <= 6, "qua nhieu lan dung")
        expect(stores == 5, f"phai co dung 5 lan watchpoint (NAPOT 16 byte) truoc fib: {stores}")
    with new_sim(hexf) as s:                         # NAPOT ghi truc tiep tdata1 / tdata2 (OpenOCD chi dung khop chinh xac)
        res = sym(elf, "result")
        base = ctr & ~0xF
        expect(base <= res < base + 16, "result phai nam trong cua so 16 byte")
        s.wreg("tselect", 0)
        s.wreg("tdata2", base | 7)                   # NAPOT 16 byte
        s.wreg("tdata1", 0x280010C2)                 # type 2, dmode, action 1, match = 1 (NAPOT), m = 1, store
        expect(s.reg("tdata1") & 0x280017C7 == 0x280010C2, f"tdata1 doc lai {s.reg('tdata1'):#x}")
        n = 0
        for _ in range(8):
            s.cmd("resume")
            if not run_until_halted(s, 3):
                break
            n += 1
            expect(s.reg("tdata1") >> 20 & 1, "hit")
        expect(n == 6, f"NAPOT 16 byte: 5 lan ghi counter + 1 lan ghi result = 6 lan dung, duoc {n}")
        expect(wait_tohost(s) == 1, "chay den het")
    with new_sim(hexf) as s:                         # trigger khong kich trong D-mode: wp vao vung data debug, doc thanh ghi van duoc
        s.cmd("wp 0xfffffb00 4 a")
        s.cmd("wp 0xfffff300 4 a")
        for r in ("a0", "a1", "mscratch", "fp"):
            s.reg(r)
        s.wmem(0x80002000, [1, 2, 3])
        expect(s.mem(0x80002000, 3) == [1, 2, 3], "mem qua progbuf voi trigger vung debug")
        s.cmd("rwp 0xfffffb00"); s.cmd("rwp 0xfffff300")
    with new_sim(hexf) as s:                         # trigger action 0 (khong dmode) khong kich trong D-mode
        s.wreg("tselect", 0)
        s.wreg("tdata2", 0xFFFFFB00)                 # dia chi cua chuong trinh truu tuong (lw / sw trong D-mode)
        s.wreg("tdata1", 0x20000043)                 # type 2, dmode = 0, action 0, m = 1, store + load
        for r in ("a0", "a1", "mscratch"):
            s.reg(r)
        s.wreg("a0", 0x1234)
        expect(s.reg("a0") == 0x1234, "lenh truu tuong dung duoc voi trigger exception tren vung debug")
        s.wreg("tdata1", 0)
    with new_sim(hexf) as s:                         # trigger m = 0: khong kich o M-mode
        s.wreg("tselect", 0)
        s.wreg("tdata2", fib)
        s.wreg("tdata1", 0x28001004)                 # type 2, dmode, action 1, m = 0, execute
        s.cmd("resume")
        expect(wait_tohost(s) == 1, "trigger voi m = 0 khong duoc dung chuong trinh M-mode")
    with new_sim(hexf) as s:                         # tdata1 doc lai dung
        s.wreg("tselect", 0)
        s.wreg("tdata2", fib)
        s.wreg("tdata1", 0x28001044)
        expect(s.reg("tdata1") & 0x28001047 == 0x28001044, f"tdata1 doc lai {s.reg('tdata1'):#x}")
        s.cmd("resume")
        expect(run_until_halted(s) and s.reg("pc") == fib and s.reg("dcsr") >> 6 & 7 == 2, "trigger m = 1 execute dung o fib")
    return "bp hw, cause 2, wp store, 2 trigger, NAPOT, khong kich trong D-mode, m = 0 / 1"


@test
def t_illegal_dcsr():
    hexf, _ = fw("dillcsr")
    with new_sim(hexf) as s:
        s.cmd("resume")
        expect(wait_tohost(s) == 1, "dcsr / dpc / DRET ngoai D-mode phai bat hop le, tselect hop le")
        return "CSR debug va DRET ngoai D-mode -> illegal instruction, tselect truy cap duoc o M-mode"


@test
def t_illegal_region():
    hexf, _ = fw("dregion")
    with new_sim(hexf) as s:
        s.cmd("resume")
        expect(wait_tohost(s) == 1, "vung debug ngoai D-mode: lay lenh -> illegal, load / store khong tac dong")
    hexf, _ = fw("trigexc")
    with new_sim(hexf) as s:
        s.cmd("resume")
        expect(wait_tohost(s) == 1, "trigger action 0 tu M-mode: mcause 3, mtval = dia chi / pc")
    return "vung debug cam ngoai D-mode; trigger action 0: mcause 3, mtval dia chi (store / load) / pc (exec)"


@test
def t_halt_wfi():
    hexf, elf = fw("wfispin")
    w = sym(elf, "wfi_here")
    with new_sim(hexf) as s:
        s.cmd("resume")
        time.sleep(0.3)
        for _ in range(3):
            s.cmd("halt")
            expect(s.reg("pc") in (w, w + 4) and s.reg("dcsr") >> 6 & 7 == 3, f"halt trong WFI: pc {s.reg('pc'):#x}")
            s.cmd("resume")
            time.sleep(0.1)
        return "halt khi hart dang ngu trong WFI (3 lan)"


@test
def t_gdb():
    hexf, elf = fw("target")
    with new_sim(hexf) as s:
        s.cmd("gdb_port 3333") if False else None
    # gdb can OpenOCD voi cong gdb: chay rieng
    _port[0] += 2
    rbb = _port[0]
    gdbp = rbb + 1
    log = tempfile.NamedTemporaryFile("w+", suffix=".log", delete=False)
    sim = subprocess.Popen([dbglib.VDBG, "--port", str(rbb), "--timeout", "120", "--halt-at-start", f"+prog={hexf}"], stdout=log, stderr=subprocess.STDOUT)
    time.sleep(0.4)
    oocd = subprocess.Popen(["openocd", "-c", f"gdb_port {gdbp}", "-c", "telnet_port disabled", "-c", "tcl_port disabled", "-f", os.path.join(HERE, "openocd.cfg")],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=dict(os.environ, RBB_PORT=str(rbb)))
    time.sleep(2.5)
    script = f"""set pagination off
set confirm off
file {elf}
target extended-remote :{gdbp}
monitor reset halt
load
break fib
continue
print n
bt
delete
watch result
continue
print result
delete
print counter
set var counter = 77
print counter
detach
"""
    sp = os.path.join(BUILD, "g.gdb")
    open(sp, "w").write(script)
    try:
        r = subprocess.run(["gdb-multiarch", "-batch", "-x", sp], capture_output=True, text=True, timeout=100)
    finally:
        oocd.kill(); sim.kill(); oocd.wait(); sim.wait(); os.unlink(log.name)
    o = r.stdout + r.stderr
    expect("Breakpoint 1, fib (n=10)" in o, "gdb: dung o fib(10)\n" + o[-1500:])
    expect("$1 = 10" in o, "gdb: print n")
    expect("#1  0x" in o and "in main ()" in o, "gdb: backtrace")
    expect("$3 = 77" in o or "= 77" in o, "gdb: set var / print")
    expect("Old value = 0" in o and "New value = 55" in o, "gdb: hardware watchpoint\n" + o[-1500:])
    return "gdb: load, break, continue, print, bt, set var, watch"


@test
def t_riscv_tests():
    """riscv-tests rv32ui / rv32mi chay tren lõi co DBG (khong debugger): lõi van dung khi bat debug"""
    rt = os.environ.get("RISCV_TESTS", "/tmp/riscv-tests")
    sys.path.insert(0, os.path.join(ROOT, "cosim", "irq"))
    import run_irq_cosim as ic
    tmp = tempfile.mkdtemp()
    names = []
    for suite, t in ic.RT_SU:
        if suite == "rv32mi":
            names.append((suite, t))
    names += [("rv32mi", "breakpoint")]
    ui = sorted(f[:-2] for f in os.listdir(os.path.join(rt, "isa", "rv32ui")) if f.endswith(".S") and f not in ("fence_i.S",))
    names += [("rv32ui", t) for t in ui]
    npass, bad = 0, []
    for suite, t in names:
        try:
            nm, elf = ic.build_rt_su(rt, suite, t, "rv32im", tmp)
        except SystemExit as e:
            bad.append((suite, t, "build")); continue
        binf, hexf = ic.to_bin_hex(elf)
        L = open(hexf).read().split("\n")
        if len(L) > 262145:
            open(hexf, "w").write("\n".join(L[:262144]) + "\n")
        _port[0] += 2
        r = subprocess.run([dbglib.VDBG, "--port", str(_port[0]), "--timeout", "60", "--exit-on-done", f"+prog={hexf}"], capture_output=True, text=True)
        m = re.search(r"TOHOST 0x([0-9a-f]+)", r.stdout)
        if r.returncode == 0 and m and int(m.group(1), 16) == 1:
            npass += 1
        else:
            bad.append((suite, t, m.group(1) if m else "khong xong"))
    # tests rv32mi khong the chay: scall can S/U? (che do M: ok), ma_fetch cua rv32mi dung C -> bo
    skip = {("rv32mi", "ma_fetch"), ("rv32ui", "ma_data")}   # loi trap khi truy cap lech, khong mo phong bang phan cung
    bad = [b for b in bad if (b[0], b[1]) not in skip]
    expect(not bad, f"{len(bad)} test hong: {bad[:8]}")
    return f"{npass} riscv-tests (rv32ui + rv32mi, gom breakpoint) chay dung tren loi co DBG"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--failfast", action="store_true")
    a = ap.parse_args()
    if a.list:
        print("\n".join(TESTS)); return
    if a.build or not os.path.exists(dbglib.VDBG):
        build_sim()
    sel = [t for t in TESTS if not a.only or t in a.only.split(",")]
    if not os.environ.get("DBG_NO_PKILL"):
        subprocess.run(["pkill", "-f", "Vdbg"], capture_output=True)
        subprocess.run(["pkill", "openocd"], capture_output=True)
    fails = []
    for name in sel:
        t0 = time.time()
        try:
            msg = TESTS[name]()
            print(f"PASS {name} ({time.time() - t0:.0f} s): {msg}", flush=True)
        except Exception as e:
            fails.append(name)
            print(f"FAIL {name} ({time.time() - t0:.0f} s): {e}", flush=True)
            if os.environ.get("DBG_TRACE"):
                traceback.print_exc()
            if a.failfast:
                break
    print(f"{len(sel) - len(fails)}/{len(sel)} test dat" + (f"; hong: {', '.join(fails)}" if fails else ""))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
