#!/usr/bin/env python3
"""Sinh chuong trinh RV32I ngau nhien (hop le) de so sanh RTL voi mo hinh tham chieu.

Rang buoc de chuong trinh luon ket thuc va khong co hanh vi khong xac dinh:
  - nhanh va JAL chi nhay toi (khong co vong lap), nhay qua nguyen "don vi" lenh
  - JALR dung nhom auipc + jalr co dinh nen dich den luon hop le
  - load/store luon can chinh (half: boi 2, word: boi 4), nen co so la x1 = 0x400 hoac x0
  - tat ca thanh ghi x1..x31 duoc khoi tao truoc, de RTL khong doc gia tri X
  - ket thuc bang sw vao tohost (0x1000)
"""
import random
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from asm import enc_r, enc_i, enc_s, enc_b, enc_u, enc_j, ALU_R, ALU_I, SH_I, LOADS, STORES, BR  # noqa: E402

TOHOST = 0x1000
BASE_REG = 1          # x1 = 0x400, khong bao gio bi ghi de
BASE_VAL = 0x400


def lui_addi(rd, val):
    val &= 0xFFFFFFFF
    lo = val & 0xFFF
    if lo & 0x800:
        lo -= 0x1000
    hi = ((val - lo) >> 12) & 0xFFFFF
    return [enc_u(hi, rd, 0b0110111), enc_i(lo, rd, 0, rd, 0b0010011)]


class Gen:
    def __init__(self, seed, n_body=300):
        self.r = random.Random(seed)
        self.n_body = n_body

    def reg(self, allow0=True):
        return self.r.randint(0 if allow0 else 1, 31)

    def dst(self):
        # khong ghi vao x1 (con tro co so); x0 van duoc dung de thu "ghi vao x0 bi bo qua"
        d = self.r.randint(0, 31)
        return 2 if d == BASE_REG else d

    # moi ham tra ve (kind, words | callable(pc, unit_pcs))
    def u_alu_r(self):
        name = self.r.choice(list(ALU_R))
        f7, f3 = ALU_R[name]
        rd, a, b = self.dst(), self.reg(), self.reg()
        return [enc_r(f7, b, a, f3, rd, 0b0110011)]

    def u_alu_i(self):
        name = self.r.choice(list(ALU_I))
        f3 = ALU_I[name]
        imm = self.r.choice([self.r.randint(-2048, 2047), 0, -1, 1, 2047, -2048])
        return [enc_i(imm, self.reg(), f3, self.dst(), 0b0010011)]

    def u_shift(self):
        name = self.r.choice(list(SH_I))
        f7, f3 = SH_I[name]
        sh = self.r.choice([self.r.randint(0, 31), 0, 31, 1])
        return [enc_i((f7 << 5) | sh, self.reg(), f3, self.dst(), 0b0010011)]

    def u_lui(self):
        return [enc_u(self.r.randint(0, 0xFFFFF), self.dst(), 0b0110111)]

    def u_auipc(self):
        return [enc_u(self.r.randint(0, 0xFFFFF), self.dst(), 0b0010111)]

    def mem_base(self):
        if self.r.random() < 0.7:
            return BASE_REG, self.r.randint(0, 0x3FF)       # 0x400..0x7FF
        return 0, self.r.randint(0x100, 0x3FF)             # x0 + offset: vung thap

    def u_load(self):
        name = self.r.choice(list(LOADS))
        f3 = LOADS[name]
        base, off = self.mem_base()
        if name in ("lh", "lhu"):
            off &= ~1
        elif name == "lw":
            off &= ~3
        return [enc_i(off, base, f3, self.dst(), 0b0000011)]

    def u_store(self):
        name = self.r.choice(list(STORES))
        f3 = STORES[name]
        base, off = self.mem_base()
        if name == "sh":
            off &= ~1
        elif name == "sw":
            off &= ~3
        return [enc_s(off, self.reg(), base, f3, 0b0100011)]

    def u_branch(self):
        name = self.r.choice(list(BR))
        f3 = BR[name]
        a, b = self.reg(), self.reg()
        skip = self.r.randint(0, 3)    # so don vi bi bo qua

        def build(pc, starts, idx, end_pc):
            tgt_idx = idx + 1 + skip
            tgt = starts[tgt_idx] if tgt_idx < len(starts) else end_pc
            return [enc_b(tgt - pc, b, a, f3, 0b1100011)]
        return build

    def u_jal(self):
        rd = self.dst()
        skip = self.r.randint(0, 3)

        def build(pc, starts, idx, end_pc):
            tgt_idx = idx + 1 + skip
            tgt = starts[tgt_idx] if tgt_idx < len(starts) else end_pc
            return [enc_j(tgt - pc, rd, 0b1101111)]
        return build

    def u_jalr(self):
        t = self.r.randint(2, 31)
        link = self.dst()
        imm = self.r.choice([12, 13])    # 13 de thu bit 0 bi xoa
        filler = self.u_alu_r()          # lenh se bi nhay qua
        return [enc_u(0, t, 0b0010111),
                enc_i(imm, t, 0, link, 0b1100111),
                filler[0]]
        # auipc t,0 (A) ; jalr link,t,imm (A+4) -> A+12 ; filler (A+8) bi bo qua

    def build(self):
        words = []
        # khoi tao: x1 = 0x400, x2..x31 ngau nhien
        words += lui_addi(BASE_REG, BASE_VAL)
        for r in range(2, 32):
            words += lui_addi(r, self.r.getrandbits(32))

        makers = [(self.u_alu_r, 25), (self.u_alu_i, 20), (self.u_shift, 6), (self.u_lui, 4),
                  (self.u_auipc, 4), (self.u_load, 12), (self.u_store, 10),
                  (self.u_branch, 10), (self.u_jal, 4), (self.u_jalr, 3)]
        fns = [m for m, w in makers]
        wts = [w for m, w in makers]
        units = []
        for _ in range(self.n_body):
            fn = self.r.choices(fns, wts)[0]
            units.append(fn())

        base_pc = len(words) * 4
        starts, pc = [], base_pc
        for u in units:
            starts.append(pc)
            pc += 4 * (1 if callable(u) else len(u))
        end_pc = pc

        for i, u in enumerate(units):
            if callable(u):
                words += u(starts[i], starts, i, end_pc)
            else:
                words += u

        # ket thuc: ghi vao tohost
        words += lui_addi(5, TOHOST)
        words.append(enc_s(0, 6, 5, 2, 0b0100011))      # sw x6, 0(x5)
        words.append(enc_j(0, 0, 0b1101111))            # vong lap an toan
        dmem = [self.r.getrandbits(32) for _ in range(1024)]
        return words, dmem


def write_hex(path, words):
    with open(path, "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")


if __name__ == "__main__":
    seed = int(sys.argv[1])
    out_prog = sys.argv[2]
    out_dmem = sys.argv[3]
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 300
    words, dmem = Gen(seed, n).build()
    write_hex(out_prog, words)
    write_hex(out_dmem, dmem)
    print(f"seed {seed}: {len(words)} lenh")
