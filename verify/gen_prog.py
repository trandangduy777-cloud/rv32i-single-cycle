#!/usr/bin/env python3
"""Sinh chuong trinh RV32I ngau nhien (hop le) de so sanh RTL voi mo hinh tham chieu.

Rang buoc de chuong trinh luon ket thuc va khong co hanh vi khong xac dinh:
  - nhanh va JAL chi nhay toi (khong co vong lap), nhay qua nguyen "don vi" lenh
  - JALR dung nhom auipc + jalr co dinh nen dich den luon hop le
  - load/store luon can chinh (half: boi 2, word: boi 4), nen co so la x1 = 0x400 hoac x0
  - tat ca thanh ghi x1..x31 duoc khoi tao truoc, de RTL khong doc gia tri X
  - ket thuc bang sw vao tohost (0x1000)
  - trap: mtvec tro toi bo xu ly o 0xC00 (cuoi bo nho lenh), bo xu ly tang mepc them 4 roi MRET,
    nen moi trap deu "bo qua lenh gay trap" va chuong trinh van ket thuc
  - mtvec va mepc khong bao gio bi ghi ngau nhien theo cach lam hong bo xu ly; MRET chi xuat hien
    trong nhom co dat mepc tro toi lenh ke tiep truoc
"""
import random
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rv32_zb                                        # noqa: E402  (Zba/Zbb/Zbs/Zbc/Zicond)
from asm import (enc_r, enc_i, enc_s, enc_b, enc_u, enc_j, ALU_R, ALU_I, SH_I, LOADS, STORES, BR,  # noqa: E402
                 OP_SYSTEM, ECALL, EBREAK, MRET, FENCE)

TOHOST = 0x1000
BASE_REG = 1          # x1 = 0x400, khong bao gio bi ghi de
BASE_VAL = 0x400
HANDLER = 0xC00       # dia chi bo xu ly trap (tu thu 768 cua bo nho lenh)
NOP = 0x13
CSR_LIST = [("mstatus", 0x300), ("misa", 0x301), ("mtvec", 0x305), ("mscratch", 0x340),
            ("mepc", 0x341), ("mcause", 0x342), ("mtval", 0x343), ("mhartid", 0xF14)]
VALID_OPCODES = {0x37, 0x17, 0x6F, 0x67, 0x63, 0x03, 0x23, 0x13, 0x33, 0x0F, 0x73}


def lui_addi(rd, val):
    val &= 0xFFFFFFFF
    lo = val & 0xFFF
    if lo & 0x800:
        lo -= 0x1000
    hi = ((val - lo) >> 12) & 0xFFFFF
    return [enc_u(hi, rd, 0b0110111), enc_i(lo, rd, 0, rd, 0b0010011)]


class Gen:
    def __init__(self, seed, n_body=300, profile="full", ma=False, zb=(), zb_probe=False):
        """profile: "full" = RV32IM + CSR + trap; "irq" = "full" + CSR ngat mie/mip; "base" = chi RV32I thuan"""
        self.r = random.Random(seed)
        self.n_body = n_body
        self.ma = ma            # True: load/store lech chay bang phan cung (MISALIGNED = 1), sinh nhieu hon
        self.zb = tuple(zb)     # phan mo rong Zba/Zbb/Zbs/Zbc/Zicond dang bat: sinh lenh cua chung (xem u_zb)
        self.zb_probe = zb_probe   # True: sinh ca ma hop le cua phan mo rong DANG TAT va ma gan-hop-le (phai trap lenh bat hop le)
        self.base = (profile == "base")
        self.csrs = CSR_LIST + ([("mie", 0x304), ("mip", 0x344)] if profile == "irq" else [])
        self.bad_csrs = [0x000, 0x7C0, 0xB01, 0xC01, 0x100, 0x3A0]

    # Nhom thanh ghi "nong": chon thanh ghi nguon/dich tu nhom nho voi xac suat HOT_P de cac lenh sat nhau
    # hay phu thuoc du lieu (forwarding, load-use). x0 nam trong nhom de thu ghi/doc x0 giua chuoi phu thuoc.
    HOT = [0, 2, 3, 4, 5]
    HOT_P = 0.45

    def reg(self, allow0=True):
        if self.r.random() < self.HOT_P:
            return self.r.choice(self.HOT if allow0 else self.HOT[1:])
        return self.r.randint(0 if allow0 else 1, 31)

    def dst(self):
        # khong ghi vao x1 (con tro co so); x0 van duoc dung de thu "ghi vao x0 bi bo qua"
        if self.r.random() < self.HOT_P:
            return self.r.choice(self.HOT)
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

    # ---------- Zba / Zbb / Zbs / Zbc / Zicond ----------
    ZB_SPECIAL = [0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0x80, 0x8000, 0xFF, 0xFFFF, 0x00FF00FF, 0xFF00FF00,
                  0x01010101, 0x0F0F0F0F, 0x12345678, 0x00010000, 0x80000001, 0xFFFFFF80, 0xFFFF8000]

    def zb_word(self, name):
        r = self.r
        if name in rv32_zb.IMM_FORMS:
            sh = r.choice([r.randint(0, 31), 0, 31, 1, 16])
            return rv32_zb.encode(name, self.dst(), self.reg(), sh)
        return rv32_zb.encode(name, self.dst(), self.reg(), self.reg())

    def u_zb(self):
        names = [n for e in self.zb for n in rv32_zb.NAMES_OF[e]]
        return [self.zb_word(self.r.choice(names))]

    def u_zb_li(self):
        # gia tri dac biet cho clz/ctz/cpop/orc.b/rev8/min/max/clmul va cac tinh huong dich 0, 31
        return lui_addi(self.dst(), self.r.choice(self.ZB_SPECIAL))

    def u_zb_probe(self):
        """Ma lenh cua moi phan mo rong (ke ca dang tat) va ma 'gan hop le' (doi 1 truong): ISS quyet dinh hop le hay
        trap; RTL phai khop. Kiem tra phan mo rong tat that su la lenh bat hop le, va giai ma chat (bit 25 cua shamt,
        rs2 cua lenh mot ngoi, funct7/funct3 sai 1 bit)."""
        r = self.r
        w = self.zb_word(r.choice(rv32_zb.ALL_NAMES))
        k = r.randint(0, 4)
        if k == 1:
            w ^= 1 << 25                                      # shamt[5] / funct7 bit 0
        elif k == 2:
            w ^= 1 << r.randint(26, 31)                       # lech 1 bit funct7
        elif k == 3:
            w ^= 1 << r.randint(12, 14)                       # lech 1 bit funct3
        elif k == 4:
            w = (w & ~(31 << 20)) | (r.randint(0, 31) << 20)  # rs2 / shamt bat ky (sai rs2 co dinh cua lenh mot ngoi)
        return [w]

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

    def u_loop(self):
        """Vong lap dem nguoc co gioi han (2..6 lan) de nhanh quay lai duoc thuc thi nhieu lan: huan luyen bo du doan
        nhanh, tao tinh huong nhanh du doan 'nhay' di cung load-use / forwarding / nhanh tien long ben trong.
        Than vong chi gom lenh khong gay trap; khong ghi vao thanh ghi dem L; khong de len o nho chua dem."""
        L = self.r.randint(2, 31)
        N = self.r.randint(2, 6)
        scratch = 0x3F0                                   # 0x400 + 0x3F0 = 0x7F0: o nho luu dem (khi chon bien the nap lai)
        body = []
        for _ in range(self.r.randint(1, 5)):
            while True:
                pool = [self.u_alu_r, self.u_alu_i, self.u_shift, self.u_load, self.u_store]
                if self.zb:
                    pool += [self.u_zb, self.u_zb]
                if not self.base:
                    pool.append(self.u_muldiv)                # lenh M dung EX ngay truoc nhanh quay lai
                u = self.r.choice(pool)()
                w = u[0]
                if (w & 0x7F) == 0b0100011:               # store: khong de len o nho luu dem
                    imm = ((w >> 25) << 5) | ((w >> 7) & 0x1F)
                    if ((w >> 15) & 31) == BASE_REG and (imm & ~3) == scratch:
                        continue
                elif ((w >> 7) & 31) == L:                # ghi vao thanh ghi dem
                    continue
                break
            body.append(w)
            if self.r.random() < 0.3:                     # nhanh tien ngan trong than vong: bo qua 1 lenh
                a_, b_ = self.reg(), self.reg()
                f = self.u_alu_r()[0]
                if ((f >> 7) & 31) == L:
                    f = NOP
                body += [enc_b(8, b_, a_, BR[self.r.choice(list(BR))], 0b1100011), f]
        tail = [enc_i(-1, L, 0, L, 0b0010011)]            # addi L, L, -1
        if self.r.random() < 0.4:                         # nap lai tu bo nho: nhanh quay lai vuong load-use
            tail += [enc_s(scratch, L, BASE_REG, 2, 0b0100011), enc_i(scratch, BASE_REG, 2, L, 0b0000011)]
        back = -4 * (len(body) + len(tail))
        return [enc_i(N, 0, 0, L, 0b0010011)] + body + tail + [enc_b(back, 0, L, BR["bne"], 0b1100011)]

    def u_jal(self):
        rd = self.dst()
        skip = self.r.randint(0, 3)

        def build(pc, starts, idx, end_pc):
            tgt_idx = idx + 1 + skip
            tgt = starts[tgt_idx] if tgt_idx < len(starts) else end_pc
            return [enc_j(tgt - pc, rd, 0b1101111)]
        return build

    def u_call_loop(self):
        """Goi ham trong vong lap (cho BTB / RAS / bang dem hoc va doan): link = x5 (t0, cung la thanh ghi link theo
        dac ta nen RAS day / lay), vi x1 la con tro vung nho.
            addi L,x0,N ; LOOP: jal x5,F ; jal x0,CONT ; F: k lenh ; jalr x0,0(x5) ; CONT: addi L,L,-1 ; bne L,x0,LOOP
        Than ham chi gom addi/xor ghi vao thanh ghi khac x0, x1, x5 va L."""
        r = self.r
        L = r.choice([x for x in range(6, 32)])
        N = r.randint(2, 5)
        k = r.randint(1, 4)
        regs = [x for x in range(6, 32) if x != L]
        body = []
        for _ in range(k):
            if r.random() < 0.5:
                body.append(enc_i(r.randint(-2048, 2047) & 0xFFF, r.choice(regs), 0, r.choice(regs), 0b0010011))   # addi
            else:
                body.append(enc_r(0, r.choice(regs), r.choice(regs), 4, r.choice(regs), 0b0110011))               # xor
        return ([enc_i(N, 0, 0, L, 0b0010011),               # addi L, x0, N
                 enc_j(8, 5, 0b1101111),                       # jal x5, F
                 enc_j((k + 2) * 4, 0, 0b1101111)] +           # jal x0, CONT
                body +
                [enc_i(0, 5, 0, 0, 0b1100111),                 # jalr x0, 0(x5)
                 enc_i(0xFFF, L, 0, L, 0b0010011),             # addi L, L, -1
                 enc_b(-(4 + k) * 4, 0, L, 1, 0b1100011)])     # bne L, x0, LOOP

    def u_jalr(self):
        t = self.r.randint(2, 31)
        link = self.dst()
        imm = self.r.choice([12, 13] if self.base else [12, 13, 12, 13, 14, 15, 10, 11])    # 13: bit0 bi xoa; 10,11,14,15: dich khong chia het 4 -> trap
        filler = self.u_alu_r()          # lenh se bi nhay qua
        return [enc_u(0, t, 0b0010111),
                enc_i(imm, t, 0, link, 0b1100111),
                filler[0]]
        # auipc t,0 (A) ; jalr link,t,imm (A+4) -> A+12 ; filler (A+8) bi bo qua


    # ---------- CSR / trap ----------
    def u_csr(self):
        name, addr = self.r.choice(self.csrs)
        f3 = self.r.choice([1, 2, 3, 5, 6, 7])
        if name == "mtvec" and (f3 & 3) == 1:       # khong ghi de len mtvec (se lam hong bo xu ly)
            f3 += 1
        rs1 = self.reg()
        if name == "mtvec":
            rs1 = 0                                  # rs1=x0 / uimm=0: chi doc
        elif f3 & 4:
            rs1 = self.r.choice([self.r.randint(0, 31), 0, 1, 31])
        return [enc_i(addr, rs1, f3, self.dst(), OP_SYSTEM)]

    # ---------- M ----------
    def u_muldiv(self):
        f3 = self.r.randint(0, 7)
        rs2 = 0 if self.r.random() < 0.08 else self.reg()      # hay chia cho x0 de thu chia cho 0
        return [enc_r(1, rs2, self.reg(), f3, self.dst(), 0b0110011)]

    def u_special_li(self):
        # nap gia tri dac biet vao thanh ghi de phep nhan/chia hay gap truong hop bien
        v = self.r.choice([0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 2, 0xFFFFFFFE, 0x80000001, 0x0000FFFF, 0xFFFF0000])
        return lui_addi(self.dst(), v)

    def u_divovf(self):
        # INT_MIN chia -1 (tran so), dung hai thanh ghi tam roi chia/lay du
        a, b = self.r.randint(2, 30), self.r.randint(2, 30)
        if a == b:
            b = a + 1
        return (lui_addi(a, 0x80000000) + lui_addi(b, 0xFFFFFFFF) +
                [enc_r(1, b, a, self.r.choice([4, 6]), self.dst(), 0b0110011)])

    def u_mie(self):
        # bat/tat MIE de trang thai mstatus trong trap khong phai luc nao cung 0
        return [enc_i(0x300, 8, self.r.choice([6, 6, 7]), 0, OP_SYSTEM)]

    def u_ecall(self):
        return [ECALL if self.r.random() < 0.5 else EBREAK]

    def u_fence(self):
        return [self.r.choice([FENCE, 0x0000100F, 0x0330000F])]

    def u_mret(self):
        # auipc t,0 ; addi t,t,20 ; csrrw x0,mepc,t ; lw t,off(x0) ; mret   -> nhay toi lenh ngay sau mret
        # lw ngay truoc mret: khi chay qua cache (run_verify --cache), load truot lam pipeline dong bang dung luc
        # MRET dang o EX
        t = self.r.randint(2, 31)
        return [enc_u(0, t, 0b0010111),
                enc_i(20, t, 0, t, 0b0010011),
                enc_i(0x341, t, 1, 0, OP_SYSTEM),
                enc_i(self.r.randrange(0, 0x800, 4), 0, 0b010, t, 0b0000011),
                MRET]

    def u_illegal(self):
        r = self.r
        k = r.randint(0, 8)
        if k == 0:                                   # bit thap khac 11 (khong phai lenh 32 bit)
            return [(r.getrandbits(32) & ~3) | r.choice([0, 1, 2])]
        if k == 1:                                   # OP_REG voi funct7 sai
            while True:
                f7, f3 = r.randint(0, 127), r.randint(0, 7)
                if f7 in (0, 1) or (f7 == 0x20 and f3 in (0, 5)):
                    continue
                break
            return [enc_r(f7, self.reg(), self.reg(), f3, self.dst(), 0b0110011)]
        if k == 2:                                   # dich bit voi funct7 sai
            f3 = r.choice([1, 5])
            bad = [x for x in range(128) if x != 0 and not (f3 == 5 and x == 0x20)]
            f7 = r.choice(bad)
            return [enc_i((f7 << 5) | r.randint(0, 31), self.reg(), f3, self.dst(), 0b0010011)]
        if k == 3:                                   # load/store/branch/jalr voi funct3 sai
            which = r.randint(0, 3)
            if which == 0:
                return [enc_i(r.randint(-2048, 2047), self.reg(), r.choice([3, 6, 7]), self.dst(), 0b0000011)]
            if which == 1:
                return [enc_s(r.randint(-2048, 2047), self.reg(), self.reg(), r.randint(3, 7), 0b0100011)]
            if which == 2:
                return [enc_b(r.randrange(-64, 64, 4), self.reg(), self.reg(), r.choice([2, 3]), 0b1100011)]
            return [enc_i(r.randint(-2048, 2047), self.reg(), r.randint(1, 7), self.dst(), 0b1100111)]
        if k == 4:                                   # SYSTEM funct3=4
            return [enc_i(r.randint(0, 4095), self.reg(), 4, self.dst(), OP_SYSTEM)]
        if k == 5:                                   # ecall/ebreak/mret sai truong rd hoac rs1
            base = r.choice([ECALL, EBREAK, MRET])
            extra = (r.randint(1, 31) << 7) if r.random() < 0.5 else (r.randint(1, 31) << 15)
            return [base | extra]
        if k == 6:                                   # opcode khong ton tai
            while True:
                op5 = r.randint(0, 31)
                if ((op5 << 2) | 3) not in VALID_OPCODES:
                    break
            return [(r.getrandbits(25) << 7) | (op5 << 2) | 3]
        if k == 7:                                   # FENCE voi funct3 khac 0/1
            return [enc_i(r.randint(0, 4095), self.reg(), r.randint(2, 7), self.dst(), 0b0001111)]
        # CSR khong ton tai, hoac ghi vao CSR chi doc
        if r.random() < 0.5:
            addr = r.choice(self.bad_csrs)
            return [enc_i(addr, self.reg(), r.choice([1, 2, 3, 5, 6, 7]), self.dst(), OP_SYSTEM)]
        f3 = r.choice([1, 5])
        return [enc_i(0xF14, self.reg(), f3, self.dst(), OP_SYSTEM)]

    def u_misaligned(self):
        r = self.r
        k = r.randint(0, 1)
        if k == 0:                                   # JAL toi dia chi khong chia het 4 -> luon trap
            imm = ((r.randint(-(1 << 18), (1 << 18) - 1)) & ~3) | 2
            return [enc_j(imm, self.dst(), 0b1101111)]
        imm = (r.randint(-1024, 1023) << 2) | 2      # nhanh: trap neu nhay, binh thuong neu khong nhay
        name = r.choice(list(BR))
        return [enc_b(imm, self.reg(), self.reg(), BR[name], 0b1100011)]

    def u_misal_mem(self):
        # load/store lech dia chi: trap (cause 4 / 6, mtval = dia chi), hoac chay binh thuong khi ma = True
        r = self.r
        base, off = self.mem_base()
        name = r.choice(["lh", "lhu", "lw", "sh", "sw"])
        if name in ("lh", "lhu", "sh"):
            off |= 1
        else:
            off = (off & ~3) | r.choice([1, 2, 3])
        if name in LOADS:
            return [enc_i(off, base, LOADS[name], self.dst(), 0b0000011)]
        return [enc_s(off, self.reg(), base, STORES[name], 0b0100011)]

    def build(self):
        words = []
        if not self.base:
            # mtvec -> bo xu ly trap (dung x2 lam trung gian, x2 se duoc ghi lai ngay sau)
            words += lui_addi(2, HANDLER)
            words.append(enc_i(0x305, 2, 1, 0, OP_SYSTEM))
        # khoi tao: x1 = 0x400, x2..x31 ngau nhien
        words += lui_addi(BASE_REG, BASE_VAL)
        for r in range(2, 32):
            words += lui_addi(r, self.r.getrandbits(32))

        makers = [(self.u_alu_r, 25), (self.u_alu_i, 20), (self.u_shift, 6), (self.u_lui, 4),
                  (self.u_auipc, 4), (self.u_load, 12), (self.u_store, 10),
                  (self.u_branch, 10), (self.u_loop, 5), (self.u_jal, 4), (self.u_jalr, 4), (self.u_fence, 1),
                  (self.u_call_loop, 3),
                  (self.u_special_li, 3)]
        if not self.base:
            makers += [(self.u_muldiv, 8), (self.u_divovf, 1),
                       (self.u_csr, 7), (self.u_mie, 2), (self.u_ecall, 1), (self.u_mret, 1),
                       (self.u_illegal, 4), (self.u_misaligned, 2), (self.u_misal_mem, 12 if self.ma else 3)]
        if self.zb:
            makers += [(self.u_zb, 30), (self.u_zb_li, 6)]
        if self.zb_probe:
            makers += [(self.u_zb_probe, 8)]
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
        if not self.base:
            assert len(words) * 4 <= HANDLER, "chuong trinh qua dai, dung de len bo xu ly trap"
            words += [NOP] * (HANDLER // 4 - len(words))
            words += [enc_i(0x300, 0, 2, 31, OP_SYSTEM),    # csrrs x31, mstatus, x0  (de trace thay trang thai trong trap)
                      enc_i(0x342, 0, 2, 31, OP_SYSTEM),    # csrrs x31, mcause, x0
                      enc_i(0x343, 0, 2, 31, OP_SYSTEM),    # csrrs x31, mtval, x0
                      enc_i(0x341, 0, 2, 31, OP_SYSTEM),    # csrrs x31, mepc, x0
                      enc_i(4, 31, 0, 31, 0b0010011),       # addi  x31, x31, 4
                      enc_i(0x341, 31, 1, 0, OP_SYSTEM),    # csrrw x0, mepc, x31
                      MRET]
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
