#!/usr/bin/env python3
"""Assembler mini cho RV32I (chi du de dung chuong trinh test), xuat prog.hex (1 tu 32-bit moi dong)."""
import sys

R = {f"x{i}": i for i in range(32)}

def enc_r(f7, rs2, rs1, f3, rd, op): return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def enc_i(imm, rs1, f3, rd, op):     return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def enc_s(imm, rs2, rs1, f3, op):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op
def enc_b(imm, rs2, rs1, f3, op):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
        | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | op
def enc_u(imm20, rd, op):            return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op
def enc_j(imm, rd, op):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) \
        | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | op

CSR_ADDR = {"mstatus": 0x300, "misa": 0x301, "mtvec": 0x305, "mscratch": 0x340,
            "mepc": 0x341, "mcause": 0x342, "mtval": 0x343, "mhartid": 0xF14}
CSR_OPS = {"csrrw": 1, "csrrs": 2, "csrrc": 3, "csrrwi": 5, "csrrsi": 6, "csrrci": 7}
OP_SYSTEM = 0b1110011
ECALL, EBREAK, MRET, FENCE = 0x00000073, 0x00100073, 0x30200073, 0x0FF0000F

M_OPS = {"mul": 0, "mulh": 1, "mulhsu": 2, "mulhu": 3, "div": 4, "divu": 5, "rem": 6, "remu": 7}

ALU_R = {"add": (0, 0), "sub": (0x20, 0), "sll": (0, 1), "slt": (0, 2), "sltu": (0, 3),
         "xor": (0, 4), "srl": (0, 5), "sra": (0x20, 5), "or": (0, 6), "and": (0, 7)}
ALU_I = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SH_I = {"slli": (0, 1), "srli": (0, 5), "srai": (0x20, 5)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BR = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


class Asm:
    def __init__(self):
        self.items = []      # (kind, args)
        self.labels = {}

    def label(self, name):
        self.labels[name] = len(self.items) * 4

    def emit(self, fn):
        self.items.append(fn)

    # ---- chi tiet lenh ----
    def r(self, name, rd, rs1, rs2):
        f7, f3 = ALU_R[name]
        self.emit(lambda pc, L: enc_r(f7, R[rs2], R[rs1], f3, R[rd], 0b0110011))

    def i(self, name, rd, rs1, imm):
        f3 = ALU_I[name]
        self.emit(lambda pc, L: enc_i(imm, R[rs1], f3, R[rd], 0b0010011))

    def sh(self, name, rd, rs1, shamt):
        f7, f3 = SH_I[name]
        self.emit(lambda pc, L: enc_i((f7 << 5) | shamt, R[rs1], f3, R[rd], 0b0010011))

    def load(self, name, rd, imm, rs1):
        f3 = LOADS[name]
        self.emit(lambda pc, L: enc_i(imm, R[rs1], f3, R[rd], 0b0000011))

    def store(self, name, rs2, imm, rs1):
        f3 = STORES[name]
        self.emit(lambda pc, L: enc_s(imm, R[rs2], R[rs1], f3, 0b0100011))

    def br(self, name, rs1, rs2, target):
        f3 = BR[name]
        self.emit(lambda pc, L: enc_b(L[target] - pc, R[rs2], R[rs1], f3, 0b1100011))

    def lui(self, rd, imm20):
        self.emit(lambda pc, L: enc_u(imm20, R[rd], 0b0110111))

    def auipc(self, rd, imm20):
        self.emit(lambda pc, L: enc_u(imm20, R[rd], 0b0010111))

    def jal(self, rd, target):
        self.emit(lambda pc, L: enc_j(L[target] - pc, R[rd], 0b1101111))

    def jalr(self, rd, rs1, imm):
        self.emit(lambda pc, L: enc_i(imm, R[rs1], 0, R[rd], 0b1100111))

    def csr(self, name, rd, csr, src):
        """src: ten thanh ghi (csrrw/s/c) hoac so 0..31 (csrrwi/si/ci). csr: ten hoac so."""
        f3 = CSR_OPS[name]
        addr = CSR_ADDR[csr] if isinstance(csr, str) else csr
        if f3 & 4:
            self.emit(lambda pc, L: enc_i(addr, src, f3, R[rd], OP_SYSTEM))
        else:
            self.emit(lambda pc, L: enc_i(addr, R[src], f3, R[rd], OP_SYSTEM))

    def m(self, name, rd, rs1, rs2):
        f3 = M_OPS[name]
        self.emit(lambda pc, L: enc_r(1, R[rs2], R[rs1], f3, R[rd], 0b0110011))

    def word(self, w):
        self.emit(lambda pc, L: w)

    def la(self, rd, target):
        """nap dia chi nhan: lui + addi (2 lenh)"""
        def hi(pc, L):
            v = L[target]
            lo = v & 0xFFF
            if lo & 0x800:
                lo -= 0x1000
            return enc_u(((v - lo) >> 12) & 0xFFFFF, R[rd], 0b0110111)
        def lo(pc, L):
            v = L[target] & 0xFFF
            if v & 0x800:
                v -= 0x1000
            return enc_i(v, R[rd], 0, R[rd], 0b0010011)
        self.emit(hi)
        self.emit(lo)

    # ---- pseudo ----
    def li(self, rd, val):
        val &= 0xFFFFFFFF
        sval = val - (1 << 32) if val & 0x80000000 else val
        if -2048 <= sval < 2048:
            self.i("addi", rd, "x0", sval)
        else:
            lo = val & 0xFFF
            if lo & 0x800:
                lo -= 0x1000
            hi = ((val - lo) >> 12) & 0xFFFFF
            self.lui(rd, hi)
            if lo:
                self.i("addi", rd, rd, lo)

    def assemble(self):
        return [fn(i * 4, self.labels) & 0xFFFFFFFF for i, fn in enumerate(self.items)]


def build(base=False):
    """base=True: chi lenh RV32I thuan (khong CSR, trap, M) - dung cho pipeline."""
    a = Asm()
    TOHOST = 0x1000

    # tag so test, check(reg, expected): neu sai thi nhay fail voi x30 = tag
    tag = [0]

    def check(reg, expected):
        tag[0] += 1
        a.i("addi", "x30", "x0", tag[0])
        a.li("x31", expected)
        a.br("bne", reg, "x31", "fail")

    # ---------- 1. ALU thanh ghi ----------
    a.li("x1", 100)
    a.li("x2", 7)
    a.r("add", "x3", "x1", "x2");  check("x3", 107)
    a.r("sub", "x3", "x1", "x2");  check("x3", 93)
    a.r("and", "x3", "x1", "x2");  check("x3", 100 & 7)
    a.r("or", "x3", "x1", "x2");   check("x3", 100 | 7)
    a.r("xor", "x3", "x1", "x2");  check("x3", 100 ^ 7)
    a.r("sll", "x3", "x1", "x2");  check("x3", 100 << 7)
    a.r("srl", "x3", "x1", "x2");  check("x3", 100 >> 7)
    a.li("x4", -64)
    a.li("x5", 3)
    a.r("sra", "x3", "x4", "x5");  check("x3", -8)
    a.r("srl", "x3", "x4", "x5");  check("x3", (0xFFFFFFC0 >> 3))
    a.r("slt", "x3", "x4", "x1");  check("x3", 1)      # -64 < 100 (co dau)
    a.r("sltu", "x3", "x4", "x1"); check("x3", 0)      # 0xFFFFFFC0 > 100 (khong dau)
    a.r("sub", "x3", "x2", "x1");  check("x3", (7 - 100) & 0xFFFFFFFF)

    # ---------- 2. ALU immediate ----------
    a.i("addi", "x6", "x1", -1);   check("x6", 99)
    a.i("andi", "x6", "x1", 0x0F); check("x6", 100 & 0x0F)
    a.i("ori", "x6", "x1", 0x0F);  check("x6", 100 | 0x0F)
    a.i("xori", "x6", "x1", -1);   check("x6", (~100) & 0xFFFFFFFF)
    a.i("slti", "x6", "x4", 0);    check("x6", 1)
    a.i("sltiu", "x6", "x4", 0);   check("x6", 0)
    a.i("sltiu", "x6", "x2", -1);  check("x6", 1)      # 7 < 0xFFFFFFFF
    a.sh("slli", "x6", "x2", 4);   check("x6", 7 << 4)
    a.sh("srli", "x6", "x4", 28);  check("x6", 0xF)
    a.sh("srai", "x6", "x4", 4);   check("x6", -4)

    # ---------- 3. LUI / AUIPC ----------
    a.lui("x7", 0x12345);          check("x7", 0x12345000)
    a.auipc("x8", 1)               # x8 = pc + 0x1000
    pc_auipc = (len(a.items) - 1) * 4
    check("x8", pc_auipc + 0x1000)

    # ---------- 4. Load / Store ----------
    a.li("x10", 0x200)
    a.li("x11", 0x8081F2F3)
    a.store("sw", "x11", 0, "x10")
    a.load("lw", "x12", 0, "x10");   check("x12", 0x8081F2F3)
    a.load("lb", "x12", 0, "x10");   check("x12", 0xFFFFFFF3)
    a.load("lbu", "x12", 0, "x10");  check("x12", 0xF3)
    a.load("lb", "x12", 3, "x10");   check("x12", 0xFFFFFF80)
    a.load("lbu", "x12", 1, "x10");  check("x12", 0xF2)
    a.load("lh", "x12", 2, "x10");   check("x12", 0xFFFF8081)
    a.load("lhu", "x12", 2, "x10");  check("x12", 0x8081)
    a.load("lh", "x12", 0, "x10");   check("x12", 0xFFFFF2F3)
    a.li("x13", 0x55)
    a.store("sb", "x13", 1, "x10")
    a.load("lw", "x12", 0, "x10");   check("x12", 0x808155F3)
    a.li("x13", 0x1234)
    a.store("sh", "x13", 2, "x10")
    a.load("lw", "x12", 0, "x10");   check("x12", 0x123455F3)

    # ---------- 5. Nhanh ----------
    a.li("x14", 5)
    a.li("x15", -5)
    # moi cap: neu nhanh dung thi bo qua lenh nhay fail
    def taken(name, rs1, rs2):
        tag[0] += 1
        a.i("addi", "x30", "x0", tag[0])
        lab = f"t{tag[0]}"
        a.br(name, rs1, rs2, lab)
        a.jal("x0", "fail")
        a.label(lab)

    def not_taken(name, rs1, rs2):
        tag[0] += 1
        a.i("addi", "x30", "x0", tag[0])
        a.br(name, rs1, rs2, "fail")

    taken("beq", "x14", "x14");  not_taken("beq", "x14", "x15")
    taken("bne", "x14", "x15");  not_taken("bne", "x14", "x14")
    taken("blt", "x15", "x14");  not_taken("blt", "x14", "x15")
    taken("bge", "x14", "x15");  not_taken("bge", "x15", "x14")
    taken("bge", "x14", "x14")
    taken("bltu", "x14", "x15"); not_taken("bltu", "x15", "x14")   # -5 la so rat lon khi khong dau
    taken("bgeu", "x15", "x14"); not_taken("bgeu", "x14", "x15")

    # ---------- 6. JAL / JALR ----------
    a.li("x20", 0)
    a.jal("x1", "func")
    a.label("after_call")
    check("x20", 77)
    pc_after = a.labels["after_call"]
    check("x1", pc_after)               # x1 = dia chi tra ve
    a.jal("x0", "fib_start")
    a.label("func")
    a.li("x20", 77)
    a.jalr("x0", "x1", 0)

    # ---------- 7. Vong lap: fibonacci(10) = 55 ----------
    a.label("fib_start")
    a.li("x21", 0)          # a
    a.li("x22", 1)          # b
    a.li("x23", 10)         # dem
    a.label("fib_loop")
    a.r("add", "x24", "x21", "x22")
    a.i("addi", "x21", "x22", 0)
    a.i("addi", "x22", "x24", 0)
    a.i("addi", "x23", "x23", -1)
    a.br("bne", "x23", "x0", "fib_loop")
    check("x21", 55)
    a.li("x25", 0x300)
    a.store("sw", "x21", 0, "x25")
    a.load("lw", "x26", 0, "x25"); check("x26", 55)

    if not base:
        # ---------- 8. CSR, trap, MRET, FENCE ----------
        # bo xu ly trap nam cuoi chuong trinh: ghi mcause/mtval/mstatus/mepc vao x24/x23/x26/x22,
        # tang bo dem x25, roi tro ve lenh ke tiep (mepc + 4)
        a.la("x10", "trap_handler")
        a.csr("csrrw", "x0", "mtvec", "x10")
        M = 0xFFFFFFFF

        # --- CSR thuan ---
        a.li("x11", 0xABCD1234)
        a.csr("csrrw", "x12", "mscratch", "x11");  check("x12", 0)
        a.csr("csrrs", "x13", "mscratch", "x0");   check("x13", 0xABCD1234)
        a.li("x14", 0x0F0F0000)
        a.csr("csrrs", "x15", "mscratch", "x14");  check("x15", 0xABCD1234)
        a.csr("csrrs", "x16", "mscratch", "x0");   check("x16", 0xABCD1234 | 0x0F0F0000)
        a.csr("csrrc", "x17", "mscratch", "x14");  check("x17", 0xABCD1234 | 0x0F0F0000)
        a.csr("csrrs", "x16", "mscratch", "x0");   check("x16", (0xABCD1234 | 0x0F0F0000) & ~0x0F0F0000 & M)
        a.csr("csrrwi", "x17", "mscratch", 21);    check("x17", (0xABCD1234 | 0x0F0F0000) & ~0x0F0F0000 & M)
        a.csr("csrrsi", "x17", "mscratch", 10);    check("x17", 21)
        a.csr("csrrs", "x16", "mscratch", "x0");   check("x16", 21 | 10)
        a.csr("csrrci", "x17", "mscratch", 5);     check("x17", 31)
        a.csr("csrrs", "x16", "mscratch", "x0");   check("x16", 31 & ~5)
        a.csr("csrrs", "x16", "misa", "x0");       check("x16", 0x40000100)
        a.csr("csrrw", "x0", "misa", "x14")        # ghi vao misa bi bo qua, khong trap
        a.csr("csrrs", "x16", "misa", "x0");       check("x16", 0x40000100)
        a.csr("csrrs", "x16", "mhartid", "x0");    check("x16", 0)     # doc mhartid voi rs1=x0: hop le
        a.csr("csrrsi", "x0", "mstatus", 8)
        a.csr("csrrs", "x16", "mstatus", "x0");    check("x16", 0x1808)
        a.csr("csrrci", "x0", "mstatus", 8)
        a.csr("csrrs", "x16", "mstatus", "x0");    check("x16", 0x1800)

        # --- trap ---
        ntrap = [0]

        def expect_trap(cause, tval=None, mepc=None):
            ntrap[0] += 1
            check("x25", ntrap[0])
            check("x24", cause)
            if tval is not None:
                check("x23", tval)
            if mepc is not None:
                check("x22", mepc)

        def here():
            return len(a.items) * 4

        a.li("x25", 0)
        a.li("x1", 555)
        a.li("x7", 7777)
        p = here(); a.word(ECALL);                       expect_trap(11, 0, p)
        p = here(); a.word(EBREAK);                      expect_trap(3, p, p)
        p = here(); a.word(0x00000000);                  expect_trap(2, 0, p)
        a.word(0xFFFFFFFF);                              expect_trap(2, 0xFFFFFFFF)
        w = enc_r(0x10, 3, 2, 0, 5, 0b0110011);          a.word(w); expect_trap(2, w)      # funct7 sai
        w = enc_r(0x20, 3, 2, 1, 5, 0b0110011);          a.word(w); expect_trap(2, w)      # SUB-kieu voi funct3 khac
        w = enc_i(0, 0, 3, 5, 0b0000011);                a.word(w); expect_trap(2, w)      # load funct3 sai
        w = enc_s(0, 5, 0, 3, 0b0100011);                a.word(w); expect_trap(2, w)      # store funct3 sai
        w = enc_i((0x20 << 5) | 3, 2, 1, 5, 0b0010011);  a.word(w); expect_trap(2, w)      # slli funct7 sai
        w = enc_i(0, 2, 1, 5, 0b1100111);                a.word(w); expect_trap(2, w)      # jalr funct3 sai
        w = enc_b(8, 0, 0, 2, 0b1100011);                a.word(w); expect_trap(2, w)      # branch funct3 sai
        w = ECALL | (5 << 7);                            a.word(w); expect_trap(2, w)      # ecall co rd khac 0
        w = enc_i(0x7C0, 0, 2, 5, OP_SYSTEM);            a.word(w); expect_trap(2, w)      # CSR khong ton tai
        w = enc_i(0xF14, 5, 1, 0, OP_SYSTEM);            a.word(w); expect_trap(2, w)      # ghi vao CSR chi doc
        w = enc_i(0xF14, 5, 2, 0, OP_SYSTEM);            a.word(w); expect_trap(2, w)      # csrrs ghi (rs1!=0) vao CSR chi doc
        w = enc_i(0, 0, 4, 0, OP_SYSTEM);                a.word(w); expect_trap(2, w)      # SYSTEM funct3=4
        # nhay toi dia chi khong chia het 4: khong ghi rd, tro ve lenh ke tiep
        p = here(); a.word(enc_j(6, 1, 0b1101111));      expect_trap(0, p + 6, p); check("x1", 555)
        p = here(); a.word(enc_b(6, 0, 0, 0, 0b1100011)); expect_trap(0, p + 6, p)           # beq x0,x0 luon nhay
        a.word(enc_b(6, 0, 0, 1, 0b1100011));            check("x25", ntrap[0])              # bne x0,x0 khong nhay -> khong trap
        a.auipc("x6", 0)
        p = here(); a.word(enc_i(14, 6, 0, 7, 0b1100111)); expect_trap(0, p - 4 + 14, p); check("x7", 7777)
        # lenh hop le khong gay trap
        a.csr("csrrs", "x16", "mhartid", "x0")
        a.word(FENCE)
        a.word(0x0000100F)                               # FENCE.I
        check("x25", ntrap[0])

        # --- MRET, mstatus ---
        a.csr("csrrsi", "x0", "mstatus", 8)              # MIE = 1
        a.word(ECALL);                                   expect_trap(11)
        check("x26", 0x1880)                             # trong handler: MPIE=1, MIE=0
        a.csr("csrrs", "x16", "mstatus", "x0");          check("x16", 0x1888)   # sau MRET: MIE=1, MPIE=1
        a.csr("csrrci", "x0", "mstatus", 8)
        a.li("x19", 0)
        a.la("x6", "mret_target")
        a.csr("csrrw", "x0", "mepc", "x6")
        a.word(MRET)
        a.li("x19", 111)                                 # bi nhay qua
        a.label("mret_target")
        check("x19", 0)

        # ---------- 9. Phan mo rong M (dap an tinh tay hoac tinh bang so nguyen lon cua Python) ----------
        def mcheck(name, av, bv, expected):
            a.li("x10", av)
            a.li("x11", bv)
            a.m(name, "x12", "x10", "x11")
            check("x12", expected)

        MASK = 0xFFFFFFFF
        mcheck("mul", 7, 6, 42)
        mcheck("mul", -7, 6, -42)
        mcheck("mulh", -7, 6, 0xFFFFFFFF)
        mcheck("mulhsu", -7, 6, 0xFFFFFFFF)
        mcheck("mulhu", -7, 6, 5)                       # 0xFFFFFFF9 * 6 = 0x5_FFFFFFD6
        mcheck("mulh", 0x80000000, 0x80000000, 0x40000000)
        mcheck("mul", 0x80000000, 0x80000000, 0)
        mcheck("mulh", 0x7FFFFFFF, 0x7FFFFFFF, 0x3FFFFFFF)
        mcheck("mul", 0x7FFFFFFF, 0x7FFFFFFF, 1)
        mcheck("mulhu", 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFE)
        mcheck("mulhsu", 0x80000000, 0xFFFFFFFF, 0x80000000)   # -2^31 * (2^32-1) = -2^63 + 2^31
        mcheck("mul", 0xDEADBEEF, 0x12345678, (0xDEADBEEF * 0x12345678) & MASK)
        mcheck("mulhu", 0xDEADBEEF, 0x12345678, (0xDEADBEEF * 0x12345678) >> 32)
        mcheck("div", -7, 2, -3)                        # lam tron ve 0
        mcheck("rem", -7, 2, -1)                        # du cung dau voi so bi chia
        mcheck("div", 7, -2, -3)
        mcheck("rem", 7, -2, 1)
        mcheck("div", -7, -2, 3)
        mcheck("rem", -7, -2, -1)
        mcheck("divu", -7, 2, 0x7FFFFFFC)               # 0xFFFFFFF9 / 2
        mcheck("remu", -7, 2, 1)
        mcheck("div", 100, 7, 14)
        mcheck("rem", 100, 7, 2)
        mcheck("div", 5, 0, 0xFFFFFFFF)                 # chia cho 0
        mcheck("divu", 5, 0, 0xFFFFFFFF)
        mcheck("rem", 5, 0, 5)
        mcheck("remu", 5, 0, 5)
        mcheck("rem", -5, 0, -5)
        mcheck("div", 0x80000000, -1, 0x80000000)       # tran so
        mcheck("rem", 0x80000000, -1, 0)
        mcheck("divu", 0x80000000, -1, 0)
        mcheck("remu", 0x80000000, -1, 0x80000000)
        mcheck("div", 0, 5, 0)
        # lenh M lien tiep, dung ket qua lenh truoc lam toan hang
        a.li("x10", 12)
        a.li("x11", 5)
        a.m("mul", "x12", "x10", "x11")                 # 60
        a.m("div", "x13", "x12", "x11")                 # 12
        a.m("rem", "x14", "x12", "x10")                 # 0
        a.m("mulhu", "x15", "x12", "x12")
        check("x12", 60); check("x13", 12); check("x14", 0); check("x15", 0)
        # ghi vao x0 bi bo qua, nhung lenh van phai chay xong
        a.m("mul", "x0", "x10", "x11")
        a.i("addi", "x16", "x0", 9); check("x16", 9)

    # ---------- ket thuc ----------
    a.li("x27", TOHOST)
    a.li("x28", 1)
    a.store("sw", "x28", 0, "x27")
    a.label("done_ok")
    a.jal("x0", "done_ok")

    a.label("fail")
    a.li("x27", TOHOST)
    a.i("ori", "x28", "x30", 0x400)     # 0x400 | so test hong
    a.store("sw", "x28", 0, "x27")
    a.label("done_bad")
    a.jal("x0", "done_bad")

    if not base:
        a.label("trap_handler")
        a.csr("csrrs", "x24", "mcause", "x0")
        a.csr("csrrs", "x23", "mtval", "x0")
        a.csr("csrrs", "x26", "mstatus", "x0")
        a.csr("csrrs", "x22", "mepc", "x0")
        a.i("addi", "x25", "x25", 1)
        a.i("addi", "x9", "x22", 4)
        a.csr("csrrw", "x0", "mepc", "x9")
        a.word(MRET)
    return a


if __name__ == "__main__":
    base = "--base" in sys.argv
    args = [x for x in sys.argv[1:] if x != "--base"]
    a = build(base)
    words = a.assemble()
    out = args[0] if args else "prog.hex"
    with open(out, "w") as f:
        for w in words + [0x00000013] * (1024 - len(words)):   # dem NOP cho du 1024 tu
            f.write(f"{w:08x}\n")
    print(f"{len(words)} lenh -> {out}")
