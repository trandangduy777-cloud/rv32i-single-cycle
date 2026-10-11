#!/usr/bin/env python3
"""Mo hinh tham chieu RV32I (ISS) viet doc lap voi RTL.

Moi lenh sinh ra 1 dong vet cung dinh dang voi testbench tb_trace.v:
  pc=... ins=... rd=<so> val=... st=<0|1> addr=... data=... strb=...
Quy uoc giong RTL:
  - bo nho lenh va du lieu rieng, moi bo 1024 tu (4 KB), chi so = dia chi[11:2]
  - ghi vao dia chi 0x1000 (tohost) la dung chuong trinh
  - truy cap khong can chinh khong duoc ho tro (bo sinh khong tao ra)
"""
import sys

M32 = 0xFFFFFFFF
TOHOST = 0x1000
NOP = 0x00000013
MEM_WORDS = 1024


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v):
    return sx(v, 32)


class ISS:
    def __init__(self, prog, dmem=None):
        self.imem = list(prog) + [NOP] * (MEM_WORDS - len(prog))
        self.dmem = list(dmem) + [0] * (MEM_WORDS - len(dmem)) if dmem else [0] * MEM_WORDS
        self.x = [0] * 32
        self.pc = 0
        self.halted = False
        self.coverage = {}

    # ---- giai ma ----
    def step(self):
        pc = self.pc
        ins = self.imem[(pc >> 2) & (MEM_WORDS - 1)]
        op = ins & 0x7F
        rd = (ins >> 7) & 31
        f3 = (ins >> 12) & 7
        rs1 = (ins >> 15) & 31
        rs2 = (ins >> 20) & 31
        f7b5 = (ins >> 30) & 1
        a = self.x[rs1]
        b = self.x[rs2]
        imm_i = sx(ins >> 20, 12)
        imm_s = sx(((ins >> 25) << 5) | ((ins >> 7) & 31), 12)
        imm_b = sx((((ins >> 31) & 1) << 12) | (((ins >> 7) & 1) << 11) |
                   (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1), 13)
        imm_u = ins & 0xFFFFF000
        imm_j = sx((((ins >> 31) & 1) << 20) | (((ins >> 12) & 0xFF) << 12) |
                   (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1), 21)

        next_pc = (pc + 4) & M32
        wr = None        # (rd, value)
        store = None     # (addr, data_masked, strb)
        name = "?"

        if op == 0b0110111:
            name = "lui"; wr = (rd, imm_u)
        elif op == 0b0010111:
            name = "auipc"; wr = (rd, (pc + imm_u) & M32)
        elif op == 0b1101111:
            name = "jal"; wr = (rd, (pc + 4) & M32); next_pc = (pc + imm_j) & M32
        elif op == 0b1100111:
            name = "jalr"; wr = (rd, (pc + 4) & M32); next_pc = ((a + imm_i) & M32) & ~1 & M32
        elif op == 0b1100011:
            name = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}[f3]
            t = {0: a == b, 1: a != b, 4: s32(a) < s32(b), 5: s32(a) >= s32(b),
                 6: a < b, 7: a >= b}[f3]
            if t:
                next_pc = (pc + imm_b) & M32
        elif op == 0b0000011:
            name = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}[f3]
            addr = (a + imm_i) & M32
            word = self.dmem[(addr >> 2) & (MEM_WORDS - 1)]
            off = addr & 3
            byte = (word >> (8 * off)) & 0xFF
            half = (word >> 16) & 0xFFFF if (off & 2) else word & 0xFFFF
            val = {0: sx(byte, 8), 1: sx(half, 16), 2: word, 4: byte, 5: half}[f3] & M32
            wr = (rd, val)
        elif op == 0b0100011:
            name = {0: "sb", 1: "sh", 2: "sw"}[f3]
            addr = (a + imm_s) & M32
            off = addr & 3
            if f3 == 0:
                data = (b & 0xFF) * 0x01010101; strb = 1 << off
            elif f3 == 1:
                data = (b & 0xFFFF) * 0x00010001; strb = 0xC if (off & 2) else 0x3
            else:
                data = b; strb = 0xF
            mask = 0
            for i in range(4):
                if strb >> i & 1:
                    mask |= 0xFF << (8 * i)
            store = (addr, data & mask, strb)
        elif op == 0b0010011:
            if f3 == 1:
                name = "slli"; v = (a << (imm_i & 31)) & M32
            elif f3 == 5:
                if f7b5:
                    name = "srai"; v = (s32(a) >> (imm_i & 31)) & M32
                else:
                    name = "srli"; v = a >> (imm_i & 31)
            else:
                name = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}[f3]
                bi = imm_i & M32
                v = {0: (a + bi) & M32, 2: int(s32(a) < imm_i), 3: int(a < bi),
                     4: a ^ bi, 6: a | bi, 7: a & bi}[f3]
            wr = (rd, v)
        elif op == 0b0110011:
            if f3 == 0:
                name = "sub" if f7b5 else "add"
                v = (a - b) & M32 if f7b5 else (a + b) & M32
            elif f3 == 5:
                if f7b5:
                    name = "sra"; v = (s32(a) >> (b & 31)) & M32
                else:
                    name = "srl"; v = a >> (b & 31)
            else:
                name = {1: "sll", 2: "slt", 3: "sltu", 4: "xor", 6: "or", 7: "and"}[f3]
                v = {1: (a << (b & 31)) & M32, 2: int(s32(a) < s32(b)), 3: int(a < b),
                     4: a ^ b, 6: a | b, 7: a & b}[f3]
            wr = (rd, v)
        else:
            name = "nop-like"   # FENCE/ECALL/EBREAK/CSR: RTL hien coi nhu NOP

        self.coverage[name] = self.coverage.get(name, 0) + 1

        # ---- ghi nguoc va bo nho ----
        if wr and wr[0] != 0:
            wd, wv = wr
            line_rd, line_val = wd, wv
        else:
            line_rd, line_val = 0, 0
        if store:
            addr, data, strb = store
            line = (f"pc={pc:08x} ins={ins:08x} rd={line_rd} val={line_val:08x} "
                    f"st=1 addr={addr:08x} data={data:08x} strb={strb:x}")
            if addr == TOHOST:
                self.halted = True
            else:
                idx = (addr >> 2) & (MEM_WORDS - 1)
                w = self.dmem[idx]
                for i in range(4):
                    if strb >> i & 1:
                        w = (w & ~(0xFF << (8 * i))) | (data & (0xFF << (8 * i)))
                self.dmem[idx] = w & M32
        else:
            line = (f"pc={pc:08x} ins={ins:08x} rd={line_rd} val={line_val:08x} "
                    f"st=0 addr=00000000 data=00000000 strb=0")
        if line_rd:
            self.x[line_rd] = line_val
        self.pc = next_pc
        return line

    def run(self, max_steps=100000):
        trace = []
        for _ in range(max_steps):
            trace.append(self.step())
            if self.halted:
                return trace, True
        return trace, False


def load_hex(path):
    words = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if ln and not ln.startswith("//"):
                words.append(int(ln, 16))
    return words


if __name__ == "__main__":
    prog = load_hex(sys.argv[1])
    dmem = load_hex(sys.argv[2]) if len(sys.argv) > 2 else None
    tr, ok = ISS(prog, dmem).run()
    print("\n".join(tr))
    if not ok:
        print("TIMEOUT", file=sys.stderr)
