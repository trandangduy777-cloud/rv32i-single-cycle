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


def build():
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
    return a


if __name__ == "__main__":
    a = build()
    words = a.assemble()
    out = sys.argv[1] if len(sys.argv) > 1 else "prog.hex"
    with open(out, "w") as f:
        for w in words + [0x00000013] * (1024 - len(words)):   # dem NOP cho du 1024 tu
            f.write(f"{w:08x}\n")
    print(f"{len(words)} lenh -> {out}")
