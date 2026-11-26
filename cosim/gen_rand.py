#!/usr/bin/env python3
"""Sinh chuong trinh assembly RISC-V ngau nhien de so tung lenh voi Spike (cosim/run_random.py).

Khac verify/gen_prog.py (chay tren ISS Python, bo nho lenh va du lieu tach roi o dia chi 0), bo sinh nay dat chuong trinh
o 0x8000_0000 giong ban do bo nho cua Spike, ket thuc bang ghi 1 vao TOHOST (0x8010_0000) nhu cac chuong trinh cosim khac.
Chuong trinh la van ban assembly (GNU as), nen nhan lai tu trinh hop dich: nhan va tu dong nen lenh khi bat -march=..c.

Rang buoc de chuong trinh luon ket thuc va Spike / RTL cung xac dinh:
  - nhanh, JAL, JALR chi nhay toi (nhay qua nguyen "don vi" lenh); chi co vong lap dem nguoc co gioi han (counter x26 /
    x27 khong nam trong nhom thanh ghi du lieu) va ham la (goi bang jal, quay lai bang ret), toi da 3 tang long nhau
  - con tro bo nho x29 (dau vung dem) va x2 (giua vung dem) khong bao gio bi ghi de; moi truy cap bo nho di qua chung
    (hoac qua x24 = x29 + offset tinh san), nen khong co dia chi hoang
  - bo xu ly trap o mtvec bo qua lenh gay trap (tinh do dai 2 / 4 byte tu chinh lenh), doc mtval o moi cause: Spike va RTL cung de mtval = lenh (cause 2; 16 bit cho lenh nen), pc (cause 3), 0 (cause 11), dia chi (0 / 4 / 6)
  - khong bat ngat: mie chi ghi 0 (Spike co CLINT, mtimecmp khoi dau 0 nen MTIP luon bat), khong doc mip
Thanh ghi: x0, x1 (ra, chi duoc ghi trong than chinh va boi lenh goi), x2 (sp = dem + 2048), x3..x23 nhom du lieu,
x24 (dich nhay gian tiep), x25 / x28 (luu ra khi ham goi ham), x26 / x27 (dem vong lap), x29 (dem), x30 / x31 (bo xu ly trap).
"""
import random

TOHOST = 0x80100000
POOL = list(range(3, 24))
HOT = [3, 4, 5, 6, 7]
BUF_SIZE = 32768
ALU_R = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
ALU_I = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH_I = ["slli", "srli", "srai"]
MULDIV = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
BRANCH = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4}
STORES = {"sb": 1, "sh": 2, "sw": 4}
EDGE = [0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 2, 0xFFFFFFFE, 0x80000001, 0x0000FFFF, 0xFFFF0000, 0xFF, 0x100,
        0x80, 0xFFFFFF80, 0x7FFF, 0x8000, 0xFFFF8000, 31, 32, 0xFFFFFFE0]
# CSR doc/ghi duoc coi la hop le o ca RTL va Spike (chi che do M)
CSR_RW = ["mscratch", "mtval", "mepc"]
CSR_RO = ["mhartid", "mtvec", "mcause", "mvendorid", "mimpid"]  # marchid: Spike = 5, tuy trien khai, khong so


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


class Gen:
    def __init__(self, seed, n_units=300, c=False, m=True, csr=True, ma=False, fencei=True, loops=True, core_c=None, zb=False):
        """c: lenh nen; m: M; csr: CSR + trap + lenh bat hop le (RV32I thuan khong co); ma: load/store lech chay bang phan
        cung (Spike --isa=..._zicclsm), neu khong thi lech => trap; fencei: FENCE.I voi ma tu sua"""
        self.r = random.Random(seed)
        self.zb = zb                                       # Zba / Zbb / Zbs / Zbc / Zicond (lenh moi cua lõi co tham so ZB*)
        self.core_c = c if core_c is None else core_c     # loi co ENABLE_C (nhay toi dich chia 2 khong con trap)
        self.n_units = n_units
        self.c, self.m, self.csr, self.ma, self.fencei, self.loops = c, m, csr, ma, fencei, loops
        self.lines = []
        self.nlab = 0
        self.recent = []
        self.pending = []              # [(con_lai, nhan)]: nhan se dat sau khi het so don vi
        self.nfuncs = 0
        self.depth = 0                 # do sau vong lap
        self.in_func = False
        self.cur_func = 0
        self.nfuncs_planned = 0
        self.stats = {}

    # ---------- chon thanh ghi ----------
    def lab(self, p="L"):
        self.nlab += 1
        return f".{p}{self.nlab}"

    def note(self, r):
        if r:
            self.recent.append(r)
            del self.recent[:-4]

    def rs(self, allow0=True):
        x = self.r.random()
        if self.recent and x < 0.40:
            return self.r.choice(self.recent[-3:])
        if x < 0.62:
            return self.r.choice(HOT + ([0] if allow0 else []))
        return self.r.choice(POOL + ([0] if allow0 else []))

    def rd(self, zero_ok=True):
        x = self.r.random()
        if zero_ok and x < 0.03:
            return 0
        if x < 0.45:
            return self.r.choice(HOT)
        if not self.in_func and x < 0.48:
            return 1
        return self.r.choice(POOL)

    def rd_n(self):
        d = self.rd()
        self.note(d)
        return d

    # ---------- don vi co ban ----------
    def u_alu_r(self):
        d = self.rd()
        l = [f"{self.r.choice(ALU_R)} x{d}, x{self.rs()}, x{self.rs()}"]
        self.note(d)
        return l

    def u_alu_i(self):
        d = self.rd()
        imm = self.r.choice([self.r.randint(-2048, 2047), 0, -1, 1, 2047, -2048])
        l = [f"{self.r.choice(ALU_I)} x{d}, x{self.rs()}, {imm}"]
        self.note(d)
        return l

    def u_shift(self):
        d = self.rd()
        sh = self.r.choice([self.r.randint(0, 31), 0, 31, 1])
        l = [f"{self.r.choice(SH_I)} x{d}, x{self.rs()}, {sh}"]
        self.note(d)
        return l

    def u_lui(self):
        d = self.rd()
        self.note(d)
        if self.r.random() < 0.5:
            return [f"lui x{d}, {self.r.randint(0, 0xFFFFF)}"]
        return [f"auipc x{d}, {self.r.randint(0, 0xFFFFF)}"]

    def u_li(self):
        d = self.rd(False)
        self.note(d)
        v = self.r.choice(EDGE) if self.r.random() < 0.7 else self.r.getrandbits(32)
        return [f"li x{d}, {s32(v)}"]

    def u_muldiv(self):
        d = self.rd()
        b = 0 if self.r.random() < 0.06 else self.rs()
        self.note(d)
        return [f"{self.r.choice(MULDIV)} x{d}, x{self.rs()}, x{b}"]

    def u_divovf(self):
        a, b = self.r.sample(POOL, 2)
        d = self.rd()
        self.note(d)
        return [f"li x{a}, -2147483648", f"li x{b}, -1", f"{self.r.choice(['div', 'rem'])} x{d}, x{a}, x{b}"]

    # ---------- bo nho ----------
    def mem_ref(self, size, force_mis=False):
        """tra ve (base, offset). Mac dinh can chinh; lech chi khi ma hoac force_mis."""
        r = self.r
        if r.random() < 0.55:
            base, off = 2, r.randint(-2048, 2047)
        else:
            base, off = 29, r.randint(0, 2047)
        if not force_mis:
            off &= ~(size - 1)
        elif size > 1:
            off = (off & ~(size - 1)) | r.randint(1, size - 1)
        return base, off

    def u_load(self):
        name = self.r.choice(list(LOADS))
        size = LOADS[name]
        mis = size > 1 and self.csr and ((self.ma and self.r.random() < 0.5) or (not self.ma and self.r.random() < 0.03))
        b, off = self.mem_ref(size, mis)
        d = self.rd()
        self.note(d)
        return [f"{name} x{d}, {off}(x{b})"]

    def u_store(self):
        name = self.r.choice(list(STORES))
        size = STORES[name]
        mis = size > 1 and self.csr and ((self.ma and self.r.random() < 0.5) or (not self.ma and self.r.random() < 0.03))
        b, off = self.mem_ref(size, mis)
        return [f"{name} x{self.rs()}, {off}(x{b})"]

    def u_far_mem(self):
        """truy cap ca vung dem 32 KB qua x24 = x29 + offset (co the doi cache nhieu chi so / tap)"""
        r = self.r
        name = r.choice(list(LOADS) + list(STORES))
        size = (LOADS | STORES)[name]
        off = r.randrange(0, BUF_SIZE - 8, size)
        l = [f"li x24, {off}", "add x24, x24, x29"]
        if name in LOADS:
            d = self.rd()
            self.note(d)
            l.append(f"{name} x{d}, 0(x24)")
        else:
            l.append(f"{name} x{self.rs()}, 0(x24)")
        return l

    def u_walk(self):
        """quet mang theo buoc co dinh trong vong lap: nhieu lan truot / trung cache, bo dem ghi, xung dot dong"""
        r = self.r
        if self.depth >= 2:
            return self.u_load()
        L = f"x{26 + self.depth}"
        stride = r.choice([4, 8, 16, 32, 64, 128, 256, 512, 1024])
        n = r.randint(4, 16)
        op = r.choice(["lw", "sw", "lw", "lbu", "lhu", "sb", "sh"])
        d = self.rd(False)
        self.note(d)
        lab = self.lab()
        body = f"{op} x{d if op[0] == 'l' else self.rs(False)}, 0(x24)"
        extra = [f"add x{d}, x{d}, x24"] if op[0] == "l" and r.random() < 0.5 else []
        return [f"li {L}, {n}", f"li x24, {r.randrange(0, 2048, 4)}", "add x24, x24, x29", f"{lab}:", body] + extra + \
               [f"addi x24, x24, {stride}", f"addi {L}, {L}, -1", f"bnez {L}, {lab}"]

    # ---------- luong dieu khien ----------
    def u_branch(self):
        name = self.r.choice(BRANCH)
        k = self.r.random()
        a, b = self.rs(), self.rs()
        pre = []
        if k < 0.12:                    # a == b: dieu kien co dinh (beq/bge/bgeu luon nhay, bne/blt/bltu khong bao gio)
            b = a
        elif k < 0.25:                  # lam hai thanh ghi bang nhau ngay truoc nhanh (hazard + nhanh nhay)
            a, b = self.r.choice(POOL), self.r.choice(POOL)
            pre = [f"mv x{a}, x{b}"]
        tgt = self.lab()
        self.pending.append([self.r.randint(0, 3), tgt])
        return pre + [f"{name} x{a}, x{b}, {tgt}"]

    def u_jal_fwd(self):
        tgt = self.lab()
        self.pending.append([self.r.randint(0, 3), tgt])
        d = self.rd()
        self.note(d)
        return [f"jal x{d}, {tgt}"]

    def u_jalr_ind(self):
        """nhay gian tiep toi nhan phia truoc: la x24 ; jalr rd, imm(x24). imm = 1 xoa bit 0; imm = 2 (khong co C) => trap"""
        tgt = self.lab()
        self.pending.append([self.r.randint(0, 2), tgt])
        d = self.rd(True)
        self.note(d)
        imm = self.r.choice([0, 0, 0, 1])
        if not self.core_c and self.csr and self.r.random() < 0.08:
            imm = self.r.choice([2, 2, 6])         # dich khong chia het 4: trap cause 0
        return [f"la x24, {tgt}", f"jalr x{d}, {imm}(x24)"]

    def u_misal_jump(self):
        """chi cho loi khong co C: nhanh / JAL toi dich chia 2 du 4: trap cause 0 neu nhay"""
        tgt = self.lab()
        self.pending.append([self.r.randint(0, 2), tgt])
        if self.r.random() < 0.5:
            return [f"jal x{self.rd()}, {tgt}+2"]
        return [f"{self.r.choice(BRANCH)} x{self.rs()}, x{self.rs()}, {tgt}+2"]

    def u_call(self):
        return [f"jal x1, F{self.r.randint(0, self.nfuncs_planned - 1)}"]

    def u_call_ind(self):
        return [f"la x24, F{self.r.randint(0, self.nfuncs_planned - 1)}", "jalr x1, 0(x24)"]

    def sub_units(self, n, kinds):
        """n don vi con (than vong lap / ham): thu gom dong, nhan nhay ben trong duoc dat truoc khi het than"""
        saved = self.pending
        self.pending = []
        out = []
        for _ in range(n):
            out += self.pick(kinds)()
            out += self.tick()
        out += self.flush()
        self.pending = saved
        return out

    def u_loop(self):
        if self.depth >= 2:
            return self.u_alu_r()
        r = self.r
        cnt = f"x{26 + self.depth}"
        lab, ex = self.lab("LP"), self.lab("LX")
        n = r.choice([1, 2, 3, 3, 4, 5, 6, 8, 9])
        self.depth += 1
        body = self.sub_units(r.randint(1, 6), "loop")
        self.depth -= 1
        kind = r.randint(0, 3) if r.random() < 0.55 else r.randint(4, 9)
        if kind >= 4:        # nhanh quay lai du 6 loai (beq / bne / blt / bge / bltu / bgeu), va c.beqz / c.bnez khi co C
            t = "x23"                                   # = 1 de so sanh (x23 la thanh ghi du lieu, ghi de duoc)
            dec = [f"addi {cnt}, {cnt}, -1"]
            if kind == 4:
                back = dec + ["sltiu x23, " + cnt + ", 1", f"beq x23, x0, {lab}"]            # tiep tuc khi co = 0
            elif kind == 5:
                back = dec + [f"bne x0, {cnt}, {lab}"]
            elif kind == 6:
                back = dec + ["li x23, 1", f"bge {cnt}, x23, {lab}"]                         # cnt >= 1
            elif kind == 7:
                back = dec + ["li x23, 1", f"bgeu {cnt}, x23, {lab}"]
            elif kind == 8:
                back = dec + [f"bltu x0, {cnt}, {lab}"]
            else:
                if self.c:
                    back = dec + [f"mv x10, {cnt}", f"c.bnez x10, {lab}"] if r.random() < 0.5 else \
                        dec + [f"sltiu x10, {cnt}, 1", f"c.beqz x10, {lab}"]
                else:
                    back = dec + [f"blt x0, {cnt}, {lab}"]
            return [f"li {cnt}, {n}", f"{lab}:"] + body + back
        if kind == 0:        # dem nguoc, nhanh quay lai o cuoi
            return [f"li {cnt}, {n}", f"{lab}:"] + body + [f"addi {cnt}, {cnt}, -1", f"bnez {cnt}, {lab}"]
        if kind == 1:        # dem nguoc, nhanh quay lai la bgtz (blt x0, cnt)
            return [f"li {cnt}, {n}", f"{lab}:"] + body + [f"addi {cnt}, {cnt}, -1", f"bgtz {cnt}, {lab}"]
        if kind == 2:        # kiem tra o dau (beq thoat), nhay nguoc bang jal / c.j
            return [f"li {cnt}, {n}", f"{lab}:", f"beqz {cnt}, {ex}"] + body + [f"addi {cnt}, {cnt}, -1", f"j {lab}", f"{ex}:"]
        # thoat som theo dieu kien du lieu
        a, b = self.rs(False), self.rs(False)
        return [f"li {cnt}, {n}", f"{lab}:"] + body + [f"{r.choice(BRANCH)} x{a}, x{b}, {ex}", f"addi {cnt}, {cnt}, -1",
                                                        f"bnez {cnt}, {lab}", f"{ex}:"]

    def u_hazard(self):
        """cap san xuat -> tieu thu o khoang cach 0..3 lenh doc lap; moi loai san xuat / tieu thu"""
        r = self.r
        p = r.choice(["alu", "load", "mul", "div", "li", "csr"] if self.m and self.csr else
                     ["alu", "load", "li", "mul"] if self.m else ["alu", "load", "li"])
        d = r.choice(HOT)
        out = []
        if p == "alu":
            out.append(f"{r.choice(ALU_R)} x{d}, x{self.rs()}, x{self.rs()}")
        elif p == "load":
            b, off = self.mem_ref(4)
            out.append(f"lw x{d}, {off}(x{b})")
        elif p == "mul":
            out.append(f"{r.choice(MULDIV[:4])} x{d}, x{self.rs()}, x{self.rs()}")
        elif p == "div":
            out.append(f"{r.choice(MULDIV[4:])} x{d}, x{self.rs()}, x{self.rs()}")
        elif p == "csr":
            out.append(f"csrrw x{d}, mscratch, x{self.rs()}")
        else:
            out.append(f"li x{d}, {s32(r.choice(EDGE))}")
        for _ in range(r.choice([0, 0, 1, 1, 2, 3])):
            out.append(f"{r.choice(['addi', 'xori'])} x{r.choice(POOL[5:])}, x{r.choice(POOL[5:])}, {r.randint(-9, 9)}")
        q = r.choice(["alu_a", "alu_b", "store_d", "store_a", "branch_a", "branch_b", "jalr", "load_a", "ret"])
        o = r.choice(HOT)
        if q == "alu_a":
            out.append(f"{r.choice(ALU_R)} x{o}, x{d}, x{self.rs()}")
        elif q == "alu_b":
            out.append(f"{r.choice(ALU_R)} x{o}, x{self.rs()}, x{d}")
        elif q == "store_d":
            b, off = self.mem_ref(4)
            out.append(f"sw x{d}, {off}(x{b})")
        elif q == "store_a":              # d lam con tro: x24 = x29 + (d & 0x7fc)
            out += [f"andi x{d}, x{d}, 2044", f"add x24, x29, x{d}", f"sw x{self.rs()}, 0(x24)"]
        elif q in ("branch_a", "branch_b"):
            tgt = self.lab()
            self.pending.append([r.randint(0, 2), tgt])
            a, b = (d, self.rs()) if q == "branch_a" else (self.rs(), d)
            out.append(f"{r.choice(BRANCH)} x{a}, x{b}, {tgt}")
        elif q == "jalr":                 # nhay toi dia chi vua tinh: la x24 ; add x24, x24, d(0) ; jalr
            tgt = self.lab()
            self.pending.append([r.randint(0, 2), tgt])
            out += [f"andi x{d}, x{d}, 0", f"la x24, {tgt}", f"add x24, x24, x{d}", f"jalr x{o}, 0(x24)"]
        elif q == "load_a":               # d lam dia chi: x24 = x29 + (d & 0x7fc)
            out += [f"andi x{d}, x{d}, 2044", f"add x24, x29, x{d}", f"lw x{o}, 0(x24)"]
        else:                             # tieu thu la lenh CSR (rs1 = d)
            if self.csr:
                out.append(f"csrrw x{o}, mscratch, x{d}")
            else:
                out.append(f"add x{o}, x{d}, x{d}")
        self.note(o)
        return out

    def u_jalr_alt(self):
        """cung mot lenh JALR nhay luan phien toi hai dich ke nhau (cach 2 byte khi co C, 4 byte khi khong): bo du doan dich (BTB / RAS)
        phai nhan ra dich thay doi chi o bit thap"""
        r = self.r
        t, lp = self.lab("JA"), self.lab("JL")
        n = r.choice([2, 4, 6, 7])
        if self.core_c:
            return [".option push", ".option rvc", f"li x23, {n}", f"{lp}:", "andi x22, x23, 1", "slli x22, x22, 1", f"la x24, {t}",
                    "add x24, x24, x22", "jalr x0, 0(x24)", ".balign 4", f"{t}:", "c.nop", "c.nop", "addi x23, x23, -1",
                    f"bnez x23, {lp}", ".option pop"]
        return [".option push", ".option norvc", f"li x23, {n}", f"{lp}:", "andi x22, x23, 1", "slli x22, x22, 2", f"la x24, {t}",
                "add x24, x24, x22", "jalr x0, 0(x24)", f"{t}:", "nop", "nop", "addi x23, x23, -1", f"bnez x23, {lp}", ".option pop"]

    ZB_R = ["sh1add", "sh2add", "sh3add", "andn", "orn", "xnor", "max", "maxu", "min", "minu", "rol", "ror", "bclr", "bext",
            "binv", "bset", "clmul", "clmulh", "clmulr", "czero.eqz", "czero.nez"]
    ZB_U = ["clz", "ctz", "cpop", "sext.b", "sext.h", "zext.h", "orc.b", "rev8"]
    ZB_I = ["rori", "bclri", "bexti", "binvi", "bseti"]

    def u_zb(self):
        """lenh Zba / Zbb / Zbs / Zbc / Zicond voi toan hang ngau nhien (gom gia tri bien) va hazard voi lenh ke truoc"""
        r = self.r
        d = self.rd()
        self.note(d)
        k = r.random()
        if k < 0.6:
            return [f"{r.choice(self.ZB_R)} x{d}, x{self.rs()}, x{self.rs()}"]
        if k < 0.8:
            return [f"{r.choice(self.ZB_U)} x{d}, x{self.rs()}"]
        return [f"{r.choice(self.ZB_I)} x{d}, x{self.rs()}, {r.choice([0, 1, 31, r.randint(0, 31)])}"]

    def u_ptr_hazard(self):
        """san xuat con tro (alu / lenh tren / load / mul / div / csr / dia chi tra ve cua JAL) roi dung NGAY lam thanh ghi co so cua
        load / store / jalr, sau 0..3 lenh doc lap: phu cac cap hazard 'x_dN_load_base / store_base / jalr_base'"""
        r = self.r
        prods = ["alu", "upper", "load", "link"] + (["mul", "div"] if self.m else []) + (["csr"] if self.csr else [])
        p = r.choice(prods)
        cons = r.choice(["load", "store", "jalr"])
        if cons == "store" and p == "link":
            cons = "load"                        # khong ghi vao vung ma (con tro tu JAL tro vao ma)
        d, o = r.choice(HOT), r.choice(HOT)
        gap = r.choice([0, 0, 1, 1, 2, 3])
        t = self.lab("PT")
        out = [".option push", ".option norvc"]        # do dai lenh co dinh: offset jalr tinh duoc
        off = r.randint(0, 127) * 8
        if cons == "jalr":
            if p == "alu":
                out += [f"la x{d}, {t}"]             # auipc + addi: addi la ben san xuat
            elif p == "upper":
                out += [f"auipc x{d}, 0"]
            elif p == "link":
                out += [f"jal x{d}, {t}", f"{t}:"]          # d = dia chi lenh ke tiep (T): jalr nhay toi T + 4 * (gap + 1)
            elif p == "load":
                out += [f"la x24, {t}", f"sw x24, {off + 1024}(x29)", f"lw x{d}, {off + 1024}(x29)"]
            elif p == "csr":
                out += [f"la x24, {t}", "csrw mscratch, x24", f"csrrw x{d}, mscratch, x0"]
            else:                                  # mul / div: x24 * 1, x24 / 1
                out += [f"la x24, {t}", "li x23, 1", f"{'mul' if p == 'mul' else 'div'} x{d}, x24, x23"]
        else:
            if p == "alu":
                out += [f"addi x{d}, x29, {off}"]
            elif p == "upper":
                out += [f"lui x{d}, %hi(buf + {off})"] if cons == "store" else [f"auipc x{d}, 0"]
            elif p == "link":
                out += [f"jal x{d}, {t}", f"{t}:"]
            elif p == "load":
                out += [f"sw x29, {off + 1024}(x29)", f"lw x{d}, {off + 1024}(x29)"]
            elif p == "csr":
                out += ["csrw mscratch, x29", f"csrrw x{d}, mscratch, x0"]
            else:
                out += ["li x23, 1", f"{'mul' if p == 'mul' else 'div'} x{d}, x29, x23"]
        for _ in range(gap):
            out.append(f"{r.choice(['addi', 'xori'])} x{r.choice(POOL[5:-1])}, x{r.choice(POOL[5:-1])}, {r.randint(-9, 9)}")
        if cons == "jalr":
            out.append(f"jalr x{o}, {(8 + 4 * gap) if p == 'upper' else (4 + 4 * gap) if p == 'link' else 0}(x{d})")
            if p not in ("upper", "link"):
                out.append(f"{t}:")
            self.note(o)
        elif cons == "load":
            if p in ("upper", "link"):             # tro vao vung ma: chi doc byte (khong lech), gia tri giong nhau o hai mo hinh
                out.append(f"{r.choice(['lb', 'lbu'])} x{o}, {r.randint(-64, 64)}(x{d})")
            else:
                name = r.choice(list(LOADS))
                out.append(f"{name} x{o}, {r.randrange(0, 2040, LOADS[name])}(x{d})")
            self.note(o)
        else:
            name = r.choice(list(STORES))
            if p == "upper":                       # d = lui(%hi(buf + off)): dia chi = d + %lo(buf + off) + them 0..7 can chinh theo kich thuoc
                out.append(f"{name} x{self.rs()}, %lo(buf + {off})(x{d})")
            else:
                out.append(f"{name} x{self.rs()}, {r.randrange(0, 2040, STORES[name])}(x{d})")
        out.append(".option pop")
        return out

    # ---------- CSR / trap ----------
    def u_csr(self):
        r = self.r
        k = r.random()
        d = self.rd()
        self.note(d)
        forms = ["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci"]
        if k < 0.25:                                   # mscratch: ghi duoc ca 32 bit, du 6 dang lenh
            form = r.choice(forms)
            if form.endswith("i"):
                return [f"{form} x{d}, mscratch, {r.choice([0, 1, 31, r.randint(0, 31)])}"]
            return [f"{form} x{d}, mscratch, x{self.rs()}"]
        if k < 0.38:                                   # mtval: du 6 dang (gia tri sau trap la tuy trien khai, nhung handler chi doc khi biet)
            form = r.choice(forms)
            cs = r.choice(["mtval", "mtval", "mcause"])      # mcause ghi duoc (cac trap sau se ghi de), handler chi doc ngay sau trap
            if form.endswith("i"):
                return [f"{form} x{d}, {cs}, {r.randint(0, 31)}", f"csrr x{d}, {cs}"]
            return [f"{form} x{d}, {cs}, x{self.rs()}", f"csrr x{d}, {cs}"]
        if k < 0.50:                                   # mepc (bit thap bi xoa): du 6 dang
            form = r.choice(forms)
            if form.endswith("i"):
                return [f"{form} x{d}, mepc, {r.randint(0, 31)}"]
            return [f"{form} x{d}, mepc, x{self.rs()}"]
        if k < 0.66:                                   # mstatus: chi bit MIE (3) va MPIE (7); du 6 dang voi gia tri an toan
            form = r.choice(forms)
            if form.endswith("i"):
                return [f"{form} x{d}, mstatus, {r.choice([0, 8])}"]
            return [f"li x{d}, {r.choice([0x88, 0x08, 0x80, 0])}", f"{form} x{d}, mstatus, x{d}", f"csrr x{d}, mstatus"]
        if k < 0.74:                                   # mie: chi doc / ghi 0 (khong de ngat xay ra trong Spike)
            return [r.choice([f"csrr x{d}, mie", f"csrrw x{d}, mie, x0", f"csrrci x{d}, mie, 0", f"csrrc x{d}, mie, x0",
                              f"csrrsi x{d}, mie, 0", f"csrrs x{d}, mie, x0"])]
        # doc thuan (csrrs / csrrc voi rs1 = x0, csrrsi / csrrci voi imm 0): khong ghi, ke ca CSR chi doc (mhartid)
        csr = r.choice(CSR_RO + ["mhartid", "mepc", "mstatus", "mscratch", "mtval", "mie"])
        return [r.choice([f"csrrs x{d}, {csr}, x0", f"csrrc x{d}, {csr}, x0", f"csrrsi x{d}, {csr}, 0", f"csrrci x{d}, {csr}, 0",
                          f"csrr x{d}, {csr}"])]

    def u_mret(self):
        t = self.lab()
        return ["la x24, " + t, "csrw mepc, x24", "mret", f"{t}:"]

    def u_ecall(self):
        if self.c and self.r.random() < 0.4:
            return ["c.ebreak"]
        return [self.r.choice(["ecall", "ebreak"])]

    def u_fence(self):
        # FENCE voi cac truong "danh cho tuong lai" (rd, rs1, fm) khac 0: dac ta bat co so trien khai phai bo qua
        r = self.r
        if r.random() < 0.1:                              # trap ngay sau FENCE
            return ["fence", r.choice(["ebreak", "ecall"] + (["c.ebreak"] if self.c else []))]
        if r.random() < 0.5:
            return [r.choice(["fence", "fence rw, rw", "fence r, w", "fence w, r", "fence.tso"])]
        w = (r.getrandbits(4) << 28) | (r.getrandbits(8) << 20) | (r.getrandbits(5) << 15) | (r.getrandbits(5) << 7) | 0x0F
        return [f".word 0x{w:08x}"]

    def u_fencei(self):
        """ghi de mot lenh o phia truoc roi FENCE.I: loi phai nap lai lenh moi (xoa cache lenh / dong ong)"""
        r = self.r
        t = self.lab("P")
        d = r.choice(POOL[6:])
        imm = r.randint(-2048, 2047)
        enc32 = (imm & 0xFFF) << 20 | (d << 15) | (0 << 12) | (d << 7) | 0x13          # addi d, d, imm
        if self.c and r.random() < 0.5:
            sh = r.randint(1, 31)
            enc16 = 0x0001 | ((sh & 0x1F) << 2) | (d << 7) | (0 << 13)            # c.addi d, d, sh
            if d == 0:
                return self.u_alu_r()
            return ["la x24, " + t, f"li x25, {enc16}", "sh x25, 0(x24)", "fence.i", ".option push", ".option rvc",
                    f"{t}:", "c.nop", ".option pop"]
        return ["la x24, " + t, f"li x25, {s32(enc32)}", "sw x25, 0(x24)", "fence.i", ".option push", ".option norvc",
                f"{t}:", "nop", ".option pop"]

    ILL32 = ["opcode", "rfunct7", "shift", "memf3", "sysf3", "sysfmt", "csr_bad", "csr_ro_write"]

    def u_illegal(self):
        r = self.r
        k = r.choice(self.ILL32 + (["c16"] * 3 if self.c else []))
        if k == "opcode":                          # opcode khong ton tai (custom / FP / AMO / vector / RV64 ...)
            op = r.choice([0x0B, 0x2B, 0x5B, 0x7B, 0x07, 0x27, 0x2F, 0x43, 0x47, 0x4B, 0x4F, 0x53, 0x57, 0x6B, 0x77, 0x3B, 0x1B])
            return [f".word 0x{(r.getrandbits(25) << 7) | op:08x}"]
        if k == "rfunct7":                         # OP voi funct7 khong hop le
            while True:
                f7, f3 = r.randint(0, 127), r.randint(0, 7)
                if f7 in (0, 1) or (f7 == 0x20 and f3 in (0, 5)):
                    continue
                break
            return [f".word 0x{(f7 << 25) | (self.rs() << 20) | (self.rs() << 15) | (f3 << 12) | (self.rd() << 7) | 0x33:08x}"]
        if k == "shift":                           # dich bit voi funct7 sai
            f3 = r.choice([1, 5])
            bad = [x for x in range(128) if x != 0 and not (f3 == 5 and x == 0x20)]
            return [f".word 0x{(r.choice(bad) << 25) | (r.randint(0, 31) << 20) | (self.rs() << 15) | (f3 << 12) | (self.rd() << 7) | 0x13:08x}"]
        if k == "memf3":                           # load funct3 3/6/7, store funct3 3..7 (rv32), nhanh funct3 2/3, jalr funct3 != 0
            w = r.randint(0, 3)
            if w == 0:
                return [f".word 0x{(r.getrandbits(12) << 20) | (self.rs() << 15) | (r.choice([3, 6, 7]) << 12) | (self.rd() << 7) | 0x03:08x}"]
            if w == 1:
                return [f".word 0x{(r.getrandbits(7) << 25) | (self.rs() << 20) | (self.rs() << 15) | (r.randint(3, 7) << 12) | (r.getrandbits(5) << 7) | 0x23:08x}"]
            if w == 2:
                return [f".word 0x{(r.getrandbits(7) << 25) | (self.rs() << 20) | (self.rs() << 15) | (r.choice([2, 3]) << 12) | (r.getrandbits(5) << 7) | 0x63:08x}"]
            return [f".word 0x{(r.getrandbits(12) << 20) | (self.rs() << 15) | (r.randint(1, 7) << 12) | (self.rd() << 7) | 0x67:08x}"]
        if k == "sysf3":                           # SYSTEM funct3 = 4
            return [f".word 0x{(r.getrandbits(12) << 20) | (self.rs() << 15) | (4 << 12) | (self.rd() << 7) | 0x73:08x}"]
        if k == "sysfmt":                          # ECALL / EBREAK / MRET voi rd hoac rs1 khac 0
            base = r.choice([0x00000073, 0x00100073, 0x30200073])
            extra = (r.randint(1, 31) << 7) if r.random() < 0.5 else (r.randint(1, 31) << 15)
            return [f".word 0x{base | extra:08x}"]
        if k == "csr_bad":                         # CSR khong ton tai o ca hai ben (che do M, khong S / U / dem)
            addr = r.choice([0x000, 0x005, 0x7C0, 0x7FF, 0x5C0, 0x8FF, 0x9C0, 0xDFF, 0xFC0])
            f3 = r.choice([1, 2, 3, 5, 6, 7])
            return [f".word 0x{(addr << 20) | (self.rs() << 15) | (f3 << 12) | (self.rd() << 7) | 0x73:08x}"]
        if k == "csr_ro_write":                    # ghi vao CSR chi doc (mhartid) bang csrrw / co rs1 != 0
            f3 = r.choice([1, 2, 3, 5, 6, 7])
            rs1 = r.randint(1, 31)
            return [f".word 0x{(0xF14 << 20) | (rs1 << 15) | (f3 << 12) | (self.rd() << 7) | 0x73:08x}"]
        # c16: lenh nen bat hop le (0x0000, c.lwsp rd=0, c.jr rs1=0, c.addi16sp 0, c.lui imm=0)
        return [f".2byte 0x{r.choice([0x0000, 0x4002, 0x8002, 0x6101, 0x6081]):04x}"]

    # ---------- lenh nen (chi khi self.c) ----------
    def u_c(self):
        r = self.r
        k = r.randint(0, 17)
        p8 = list(range(8, 16))
        d = r.choice(POOL)
        if k == 0:
            self.note(d)
            return [f"c.addi x{d}, {r.choice([x for x in range(-32, 32) if x])}"]
        if k == 1:
            self.note(d)
            return [f"c.li x{d}, {r.randint(-32, 31)}"]
        if k == 2:
            self.note(d)
            return [f"c.lui x{d}, {r.choice(list(range(1, 32)) + list(range(0xFFFE0, 0x100000)))}"]
        if k == 3:
            n = r.choice([x for x in range(-31, 32) if x]) * 16
            mid = [f"lw x{r.choice(POOL)}, {r.randrange(-64, 64, 4)}(x2)"] if r.random() < 0.5 else []
            return [f"c.addi16sp sp, {n}"] + mid + [f"c.addi16sp sp, {-n}"]
        if k == 4:
            d = r.choice(p8)
            self.note(d)
            return [f"c.addi4spn x{d}, sp, {r.randrange(4, 1024, 4)}"]
        if k == 5:
            self.note(d)
            return [f"c.lwsp x{d}, {r.randrange(0, 256, 4)}(sp)"]
        if k == 6:
            return [f"c.swsp x{self.rs()}, {r.randrange(0, 256, 4)}(sp)"]
        if k == 7:
            b = r.choice(p8)
            d = r.choice([x for x in p8 if x != b])
            self.note(d)
            op = r.choice(["c.lw", "c.sw"])
            return [f"addi x{b}, x29, {r.randrange(0, 1800, 4)}", f"{op} x{d}, {r.randrange(0, 128, 4)}(x{b})"]
        if k == 8:                                     # c.j qua 1-2 lenh don gian (trong tam voi +-2 KB)
            t = self.lab()
            return [f"c.j {t}", f"addi x{r.choice(POOL)}, x{r.choice(POOL)}, 1", f"{t}:"]
        if k == 9:                                     # c.beqz / c.bnez rs1' qua 1 lenh (trong tam voi +-256 B)
            t = self.lab()
            return [f"c.{r.choice(['beqz', 'bnez'])} x{r.choice(p8)}, {t}", f"xor x{r.choice(POOL)}, x{r.choice(POOL)}, x{r.choice(POOL)}", f"{t}:"]
        if k == 10:
            if self.in_func:
                return ["c.nop"]
            t = self.lab()
            self.pending.append([r.randint(0, 2), t])
            return ["la x24, " + t, f"c.{r.choice(['jr', 'jalr'])} x24"]
        if k == 11:
            self.note(d)
            return [f"c.{r.choice(['mv', 'add'])} x{d}, x{r.choice(POOL)}"]
        if k == 12:
            d, s_ = r.choice(p8), r.choice(p8)
            self.note(d)
            return [f"c.{r.choice(['and', 'or', 'xor', 'sub'])} x{d}, x{s_}"]
        if k == 13:
            d = r.choice(p8)
            self.note(d)
            return [f"c.andi x{d}, {r.randint(-32, 31)}"]
        if k == 14:
            d = r.choice(p8)
            self.note(d)
            return [f"c.{r.choice(['srli', 'srai'])} x{d}, {r.randint(1, 31)}"]
        if k == 15:
            self.note(d)
            return [f"c.slli x{d}, {r.randint(1, 31)}"]
        if k == 16:
            return ["c.nop"]
        if self.nfuncs_planned and not self.in_func:   # c.jal toi mot chan gan: c.jal 1f ; j 2f ; 1: j F ; 2:
            t1, t2 = self.lab(), self.lab()
            return [f"c.jal {t1}", f"j {t2}", f"{t1}:", f"j F{r.randint(0, self.nfuncs_planned - 1)}", f"{t2}:"]
        return ["c.nop"]

    # ---------- khung chuong trinh ----------
    def pick(self, kind="main"):
        base = [(self.u_alu_r, 22), (self.u_alu_i, 15), (self.u_shift, 5), (self.u_lui, 3), (self.u_li, 3),
                (self.u_load, 11), (self.u_store, 8), (self.u_branch, 8), (self.u_hazard, 7), (self.u_far_mem, 2), (self.u_ptr_hazard, 3)]
        if self.m:
            base += [(self.u_muldiv, 8), (self.u_divovf, 1)]
        if kind == "main":
            if self.loops:
                base += [(self.u_loop, 4), (self.u_walk, 2)]
            base += [(self.u_jal_fwd, 2), (self.u_jalr_ind, 2), (self.u_jalr_alt, 1.5)]
            if self.nfuncs_planned:
                base += [(self.u_call, 3), (self.u_call_ind, 1)]
        if kind == "loop":
            base += [(self.u_jal_fwd, 1), (self.u_loop, 1), (self.u_call, 1)] if self.nfuncs_planned else [(self.u_jal_fwd, 1), (self.u_loop, 1)]
        if kind == "func":
            base += [(self.u_call_nested, 2)]
        if self.csr:
            base += [(self.u_csr, 5), (self.u_fence, 1), (self.u_ecall, 0.6), (self.u_illegal, 2.5),
                     (self.u_misal_mem, 4 if not self.ma else 2)]
            if kind == "main":
                base += [(self.u_mret, 0.6)]
                if not self.core_c:
                    base += [(self.u_misal_jump, 1.5)]
                if self.fencei:
                    base += [(self.u_fencei, 0.8)]
        else:
            base += [(self.u_fence_nop, 1)]
        if self.zb:
            base += [(self.u_zb, 12)]
        if self.c:
            base += [(self.u_c, 9)]
        fns = [f for f, w in base]
        ws = [w for f, w in base]
        return self.r.choices(fns, ws)[0]

    def u_fence_nop(self):
        return ["fence"]

    def u_misal_mem(self):
        r = self.r
        name = r.choice(["lh", "lhu", "lw", "sh", "sw"])
        size = 4 if name[1] == "w" else 2
        b, off = self.mem_ref(size, True)
        if name[0] == "l":
            d = self.rd()
            self.note(d)
            return [f"{name} x{d}, {off}(x{b})"]
        return [f"{name} x{self.rs()}, {off}(x{b})"]

    @staticmethod
    def level(i):
        return 0 if i < 2 else (1 if i < 4 else 2)

    def u_call_nested(self):
        """ham tang L goi ham tang L + 1 (luu ra vao x28 / x25), nen khong de quy va ngan xep toi da 3 tang"""
        lvl = self.level(self.cur_func)
        cand = [j for j in range(self.nfuncs_planned) if self.level(j) == lvl + 1]
        if lvl >= 2 or not cand:
            return self.u_alu_i()
        save = "x28" if lvl == 0 else "x25"
        return [f"mv {save}, x1", f"jal x1, F{self.r.choice(cand)}", f"mv x1, {save}"]

    def tick(self):
        """sau moi don vi: giam bo dem cac nhan nhay phia truoc, dat nhan khi het"""
        out = []
        keep = []
        for ent in self.pending:
            if ent[0] <= 0:
                out.append(f"{ent[1]}:")
            else:
                ent[0] -= 1
                keep.append(ent)
        self.pending = keep
        return out

    def flush(self):
        out = [f"{e[1]}:" for e in self.pending]
        self.pending = []
        return out

    def handler(self):
        # can le 4 trong che do rvc: o che do norvc gas khong the them dem 2 byte khi lenh truoc nam o dia chi 2 mod 4
        h = ["    .option push", "    .option rvc", "    .balign 4", "    .option pop", "trap_handler:",
             "    csrr x31, mcause",
             "    csrr x30, mtval",
             "1:  csrr x30, mstatus",
             "    csrr x31, mepc",
             "    lhu  x30, 0(x31)",
             "    andi x30, x30, 3",
             "    addi x30, x30, -3",
             "    seqz x30, x30",
             "    slli x30, x30, 1",
             "    addi x30, x30, 2",
             "    add  x31, x31, x30",
             "    csrw mepc, x31",
             "    mret"]
        return h

    def build(self):
        r = self.r
        self.nfuncs_planned = r.randint(2, 5) if self.loops else 0
        L = [f"    .option {'rvc' if self.c else 'norvc'}", "    .section .text.init", "    .globl _start", "_start:"]
        if self.csr:
            L += ["    la x30, trap_handler", "    csrw mtvec, x30"]
        L += ["    la x29, buf", "    li x30, 2048", "    add x2, x29, x30"]
        for x in POOL + [1]:
            L.append(f"    li x{x}, {s32(r.choice(EDGE) if r.random() < 0.15 else r.getrandbits(32))}")
        body = []
        for _ in range(self.n_units):
            body += self.pick("main")()
            body += self.tick()
        body += self.flush()
        L += ["    " + l if not l.endswith(":") and not l.startswith(".") else l for l in body]
        L += [f"    li x30, 0x{TOHOST:x}", "    li x31, 1", "    sw x31, 0(x30)", "1:  j 1b"]
        # ham la (cung dung trong vong lap / lenh nen)
        for i in range(self.nfuncs_planned):
            self.cur_func = i
            self.in_func = True
            self.pending = []
            fb = []
            for _ in range(r.randint(1, 6)):
                fb += self.pick("func")()
                fb += self.tick()
            fb += self.flush()
            self.in_func = False
            L += [f"F{i}:"] + ["    " + l if not l.endswith(":") and not l.startswith(".") else l for l in fb]
            L.append("    " + r.choice(["ret", "jr ra", "jalr x0, 0(x1)"]))
        if self.csr:
            L += self.handler()
        L += ["    .section .data", "    .balign 16", "buf:"]
        for _ in range(512):
            L.append(f"    .word 0x{r.getrandbits(32):08x}")
        L.append(f"    .space {BUF_SIZE - 2048}")
        return "\n".join(L) + "\n"


# Ham la co the goi ham khac: u_call_nested dung F(j) voi j > cap hien tai, nen khong de quy.
if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("seed", type=int)
    ap.add_argument("--units", type=int, default=300)
    ap.add_argument("--c", action="store_true")
    ap.add_argument("--no-m", action="store_true")
    ap.add_argument("--no-csr", action="store_true")
    ap.add_argument("--ma", action="store_true")
    a = ap.parse_args()
    print(Gen(a.seed, a.units, c=a.c, m=not a.no_m, csr=not a.no_csr, ma=a.ma).build())
