#!/usr/bin/env python3
"""Coverage chuc nang cua chuong trinh ngau nhien, tinh tu vet Spike (--log-commits) cua cac chuong trinh da khop RTL.

Vi chuong trinh da khop RTL tung lenh, vet cua Spike cung la vet cua RTL, nen cac "bin" duoi day la nhung tinh huong kien
truc da thuc su chay qua RTL va cho ket qua dung. Nhom bin:
  op        tung lenh (RV32I, M, C, Zicsr, FENCE / FENCE.I, ECALL / EBREAK / MRET)
  alu       gia tri toan hang: dich bit (so bit dich 0 / 31 / khac), SLT / SLTU (cung dau / khac dau), cong tran so
  muldiv    MUL* theo dau hai toan hang (am / 0 / duong); DIV / REM theo (chia 0, tran so INT_MIN / -1, dau)
  branch    moi loai nhanh x (nhay / khong nhay) x (tien / lui)
  hazard    san xuat -> tieu thu o khoang cach 1 / 2 / 3 lenh x vai tro cua toan hang tieu thu
  mem       moi load / store x do lech dia chi (0..3) x vat qua dong 16 byte; load co dau am / duong; store -> load cung dia chi
  csr       moi CSR x kieu lenh (ghi / dat bit / xoa bit, dang thanh ghi / dang tuc thoi, doc thuan khong ghi)
  trap      moi nguyen nhan (0, 2, 3, 4, 6, 11) x loai lenh ngay truoc, do dai lenh gay trap, trap trong ham / vong lap, MRET
  cflow     JAL / JALR / goi / tra ve (RAS), vong lap dem ngan / dai, nhanh lien tiep
Cac bin khong the xay ra (vd. MULH voi toan hang khong the) khong duoc liet ke trong catalog().
"""
import re

REG_RE = re.compile(r"core\s+\d+: 3 (0x[0-9a-f]+) \((0x[0-9a-f]+)\)(.*)")
EXC_RE = re.compile(r"core\s+\d+: exception (\w+), epc 0x([0-9a-f]+)")
TVAL_RE = re.compile(r"core\s+\d+:\s+tval 0x([0-9a-f]+)")

CAUSE = {"trap_instruction_address_misaligned": 0, "trap_illegal_instruction": 2, "trap_breakpoint": 3,
         "trap_load_address_misaligned": 4, "trap_store_address_misaligned": 6, "trap_machine_ecall": 11}
CSRS = {0x300: "mstatus", 0x304: "mie", 0x305: "mtvec", 0x340: "mscratch", 0x341: "mepc", 0x342: "mcause",
        0x343: "mtval", 0xF14: "mhartid"}
BR = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
ALU_R = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
ALU_I = ["addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai"]
MD = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
LD = ["lb", "lh", "lw", "lbu", "lhu"]
ST = ["sb", "sh", "sw"]
CS = ["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci"]
C16 = ["c.addi4spn", "c.lw", "c.sw", "c.nop", "c.addi", "c.jal", "c.li", "c.addi16sp", "c.lui", "c.srli", "c.srai", "c.andi",
       "c.sub", "c.xor", "c.or", "c.and", "c.j", "c.beqz", "c.bnez", "c.slli", "c.lwsp", "c.jr", "c.mv", "c.ebreak",
       "c.jalr", "c.add", "c.swsp"]
ZB_RTAB = {(0x10, 2): "sh1add", (0x10, 4): "sh2add", (0x10, 6): "sh3add", (0x20, 7): "andn", (0x20, 6): "orn", (0x20, 4): "xnor",
           (5, 6): "max", (5, 7): "maxu", (5, 4): "min", (5, 5): "minu", (0x30, 1): "rol", (0x30, 5): "ror", (0x24, 1): "bclr",
           (0x24, 5): "bext", (0x34, 1): "binv", (0x14, 1): "bset", (5, 1): "clmul", (5, 2): "clmulr", (5, 3): "clmulh",
           (7, 5): "czero.eqz", (7, 7): "czero.nez"}
ZB_UNARY = {0: "clz", 1: "ctz", 2: "cpop", 4: "sext.b", 5: "sext.h"}
ZB_ITAB = {(0x30, 5): "rori", (0x24, 1): "bclri", (0x24, 5): "bexti", (0x34, 1): "binvi", (0x14, 1): "bseti"}
ZB = sorted(set(ZB_RTAB.values()) | set(ZB_UNARY.values()) | set(ZB_ITAB.values()) | {"zext.h", "orc.b", "rev8"})
OPS = ["lui", "auipc", "jal", "jalr"] + BR + LD + ST + ALU_I + ALU_R + MD + CS + ["fence", "fence.i", "ecall", "ebreak", "mret"] + C16
PROD = ["alu", "upper", "load", "mul", "div", "csr", "link"]
ROLES = ["alu_a", "alu_b", "load_base", "store_base", "store_data", "br_a", "br_b", "jalr_base", "csr_src", "md_a", "md_b"]
PRE = ["alu", "upper", "load", "store", "br_taken", "br_not", "jump", "mul", "div", "csr", "fence", "trap", "other"]


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def sgn(v):
    v &= 0xFFFFFFFF
    return "z" if v == 0 else ("n" if v & 0x80000000 else "p")


def zb_imm(ins):
    """OP-IMM cua Zbb/Zbs: ten lenh hoac None"""
    f3, f7, rs2 = (ins >> 12) & 7, ins >> 25, (ins >> 20) & 31
    if f3 == 1 and f7 == 0x30:
        return ZB_UNARY.get(rs2)
    if (ins >> 20) == 0x287 and f3 == 5:
        return "orc.b"
    if (ins >> 20) == 0x698 and f3 == 5:
        return "rev8"
    return ZB_ITAB.get((f7, f3)) if (f7, f3) in ZB_ITAB else None


def decode(ins):
    """-> dict(name, rd, uses=[(reg, role)], cls, imm) hoac None neu khong giai ma duoc (lenh bat hop le)"""
    if ins & 3 != 3:
        return decode16(ins)
    op, rd, f3, rs1, rs2, f7 = ins & 0x7F, (ins >> 7) & 31, (ins >> 12) & 7, (ins >> 15) & 31, (ins >> 20) & 31, ins >> 25
    d = dict(name=None, rd=0, uses=[], cls="alu", imm=0)
    if op == 0x37:
        d.update(name="lui", rd=rd, cls="upper")
    elif op == 0x17:
        d.update(name="auipc", rd=rd, cls="upper")
    elif op == 0x6F:
        d.update(name="jal", rd=rd, cls="link", imm=sx(((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1), 21))
    elif op == 0x67 and f3 == 0:
        d.update(name="jalr", rd=rd, cls="link", uses=[(rs1, "jalr_base")])
    elif op == 0x63 and f3 not in (2, 3):
        imm = sx(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1), 13)
        d.update(name=BR[[0, 1, 4, 5, 6, 7].index(f3)], uses=[(rs1, "br_a"), (rs2, "br_b")], cls="br", imm=imm)
    elif op == 0x03 and f3 in (0, 1, 2, 4, 5):
        d.update(name=["lb", "lh", "lw", None, "lbu", "lhu"][f3], rd=rd, uses=[(rs1, "load_base")], cls="load")
    elif op == 0x23 and f3 in (0, 1, 2):
        d.update(name=["sb", "sh", "sw"][f3], uses=[(rs1, "store_base"), (rs2, "store_data")], cls="store")
    elif op == 0x13 and (zi := zb_imm(ins)):
        d.update(name=zi, rd=rd, uses=[(rs1, "alu_a")], imm=(ins >> 20) & 31)
    elif op == 0x13:
        nm = ["addi", "slli", "slti", "sltiu", "xori", None, "ori", "andi"][f3] if f3 != 5 else ("srai" if f7 == 0x20 else "srli")
        d.update(name=nm, rd=rd, uses=[(rs1, "alu_a")], imm=sx(ins >> 20, 12))
    elif op == 0x33 and f7 != 1 and (zr := ZB_RTAB.get((f7, f3)) or ("zext.h" if (f7, f3, rs2) == (4, 4, 0) else None)):
        d.update(name=zr, rd=rd, uses=[(rs1, "alu_a"), (rs2, "alu_b")])
    elif op == 0x33:
        if f7 == 1:
            nm = MD[f3]
            d.update(name=nm, rd=rd, uses=[(rs1, "md_a"), (rs2, "md_b")], cls="div" if f3 >= 4 else "mul")
        else:
            nm = {(0, 0): "add", (0x20, 0): "sub", (0, 1): "sll", (0, 2): "slt", (0, 3): "sltu", (0, 4): "xor", (0, 5): "srl",
                  (0x20, 5): "sra", (0, 6): "or", (0, 7): "and"}.get((f7, f3))
            d.update(name=nm, rd=rd, uses=[(rs1, "alu_a"), (rs2, "alu_b")])
    elif op == 0x0F:
        d.update(name="fence.i" if f3 == 1 else "fence", cls="fence")
    elif op == 0x73:
        if f3 == 0:
            d.update(name={0x00000073: "ecall", 0x00100073: "ebreak", 0x30200073: "mret"}.get(ins), cls="sys")
        elif f3 != 4:
            d.update(name=CS[(f3 & 3) - 1 + (3 if f3 & 4 else 0)], rd=rd, cls="csr",
                     uses=[] if f3 & 4 else [(rs1, "csr_src")], imm=ins >> 20)
            d["csr_rs1"] = rs1
    return d if d["name"] else None


def decode16(ins):
    q, f3 = ins & 3, (ins >> 13) & 7
    rd5, rs2_5 = (ins >> 7) & 31, (ins >> 2) & 31
    rp, rq = ((ins >> 7) & 7) + 8, ((ins >> 2) & 7) + 8
    b12 = (ins >> 12) & 1
    d = dict(name=None, rd=0, uses=[], cls="alu", imm=0)
    if q == 0:
        if f3 == 0 and ins != 0:
            d.update(name="c.addi4spn", rd=rq, uses=[(2, "alu_a")])
        elif f3 == 2:
            d.update(name="c.lw", rd=rq, uses=[(rp, "load_base")], cls="load")
        elif f3 == 6:
            d.update(name="c.sw", uses=[(rp, "store_base"), (rq, "store_data")], cls="store")
    elif q == 1:
        imm6 = sx((b12 << 5) | rs2_5, 6)
        if f3 == 0:
            d.update(name="c.nop" if rd5 == 0 else "c.addi", rd=rd5, uses=[(rd5, "alu_a")], imm=imm6)
        elif f3 == 1:
            d.update(name="c.jal", rd=1, cls="link", imm=sx((b12 << 11) | (((ins >> 11) & 1) << 4) | (((ins >> 9) & 3) << 8) | (((ins >> 8) & 1) << 10) | (((ins >> 7) & 1) << 6) | (((ins >> 6) & 1) << 7) | (((ins >> 3) & 7) << 1) | (((ins >> 2) & 1) << 5), 12))
        elif f3 == 2:
            d.update(name="c.li", rd=rd5)
        elif f3 == 3:
            if rd5 == 2:
                d.update(name="c.addi16sp", rd=2, uses=[(2, "alu_a")])
            elif rd5 != 0:
                d.update(name="c.lui", rd=rd5, cls="upper")
        elif f3 == 4:
            s = (ins >> 10) & 3
            if s == 0:
                d.update(name="c.srli", rd=rp, uses=[(rp, "alu_a")])
            elif s == 1:
                d.update(name="c.srai", rd=rp, uses=[(rp, "alu_a")])
            elif s == 2:
                d.update(name="c.andi", rd=rp, uses=[(rp, "alu_a")])
            elif b12 == 0:
                d.update(name=["c.sub", "c.xor", "c.or", "c.and"][(ins >> 5) & 3], rd=rp, uses=[(rp, "alu_a"), (rq, "alu_b")])
        elif f3 == 5:
            d.update(name="c.j", cls="jump", imm=sx((b12 << 11) | (((ins >> 11) & 1) << 4) | (((ins >> 9) & 3) << 8) | (((ins >> 8) & 1) << 10) | (((ins >> 7) & 1) << 6) | (((ins >> 6) & 1) << 7) | (((ins >> 3) & 7) << 1) | (((ins >> 2) & 1) << 5), 12))
        else:
            imm = sx((b12 << 8) | (((ins >> 10) & 3) << 3) | (((ins >> 5) & 3) << 6) | (((ins >> 3) & 3) << 1) | (((ins >> 2) & 1) << 5), 9)
            d.update(name="c.beqz" if f3 == 6 else "c.bnez", uses=[(rp, "br_a")], cls="br", imm=imm)
    else:
        if f3 == 0 and rd5:
            d.update(name="c.slli", rd=rd5, uses=[(rd5, "alu_a")])
        elif f3 == 2 and rd5:
            d.update(name="c.lwsp", rd=rd5, uses=[(2, "load_base")], cls="load")
        elif f3 == 4:
            if b12 == 0:
                if rs2_5 == 0 and rd5:
                    d.update(name="c.jr", uses=[(rd5, "jalr_base")], cls="jump")
                elif rs2_5 and rd5:
                    d.update(name="c.mv", rd=rd5, uses=[(rs2_5, "alu_b")])
            else:
                if rs2_5 == 0 and rd5 == 0:
                    d.update(name="c.ebreak", cls="sys")
                elif rs2_5 == 0:
                    d.update(name="c.jalr", rd=1, cls="link", uses=[(rd5, "jalr_base")])
                elif rd5:
                    d.update(name="c.add", rd=rd5, uses=[(rd5, "alu_a"), (rs2_5, "alu_b")])
        elif f3 == 6:
            d.update(name="c.swsp", uses=[(2, "store_base"), (rs2_5, "store_data")], cls="store")
    return d if d["name"] else None


def parse_log(path):
    """-> danh sach su kien: ('i', pc, ins, rd, val, memaddr | None, store?) va ('x', ten_nguyen_nhan, epc, tval)"""
    ev = []
    pend = None
    with open(path) as f:
        for l in f:
            m = REG_RE.match(l)
            if m:
                pc, ins = int(m.group(1), 16), int(m.group(2), 16)
                if pc < 0x80000000:
                    continue
                tok = m.group(3).split()
                rd, val, mem, st = 0, 0, None, False
                i = 0
                while i < len(tok):
                    t = tok[i]
                    if re.fullmatch(r"x\d+", t):
                        rd, val = int(t[1:]), int(tok[i + 1], 16) & 0xFFFFFFFF
                        i += 2
                    elif t == "mem":
                        mem = int(tok[i + 1], 16) & 0xFFFFFFFF
                        if i + 2 < len(tok) and tok[i + 2].startswith("0x"):
                            st = True
                            i += 3
                        else:
                            i += 2
                    else:
                        i += 1
                ev.append(("i", pc, ins, rd, val, mem, st))
                continue
            m = EXC_RE.match(l)
            if m:
                pend = ["x", m.group(1), int(m.group(2), 16), 0]
                ev.append(pend)
                continue
            m = TVAL_RE.match(l)
            if m and pend is not None:
                pend[3] = int(m.group(1), 16)
                pend = None
    return ev


def collect(log, ref, base=0x80000000, fetch=None):
    cov = {}

    def hit(b):
        cov[b] = cov.get(b, 0) + 1

    regs = [0] * 32
    hist = []                           # (class san xuat, rd) cua toi da 3 lenh gan nhat
    last_store = {}
    prev_pre = "other"
    in_handler = False
    ev = parse_log(log)
    prev_pc, prev_len, prev_taken_back = None, 0, 0
    loop_run = {}
    for e in ev:
        if e[0] == "x":
            cause = CAUSE.get(e[1])
            if cause is None:
                hit(f"trap:cause_other_{e[1]}")
                continue
            hit(f"trap:cause{cause}_after_{prev_pre}")
            hit(f"trap:cause{cause}")
            if cause == 11:                      # ECALL / EBREAK / C.EBREAK khong co trong vet commit cua Spike: dem tu dong exception
                hit("op:ecall")
            elif cause == 3 and fetch is not None:
                hit("op:c.ebreak" if (fetch(e[2]) & 0xFFFF) == 0x9002 and (fetch(e[2]) & 3) != 3 else "op:ebreak")
            if cause == 2 and e[3]:
                hit(f"trap:illegal_len{'16' if e[3] & 3 != 3 else '32'}")
            hist.append(("trap", 0))
            del hist[:-3]
            prev_pre = "trap"
            continue
        _, pc, ins, rd, val, mem, st = e
        d = decode(ins)
        if d is None:
            hit("op:undecoded")
            prev_pre = "other"
            continue
        nm = d["name"]
        hit(f"op:{nm}")
        # hazard
        for r_, role in d["uses"]:
            if r_ == 0:
                for k in range(min(2, len(hist))):
                    if hist[-1 - k][1] == 0 and hist[-1 - k][0] not in ("trap",) and hist[-1 - k][2]:
                        hit(f"hazard:x0_written_then_read_d{k + 1}")
                continue
            for k in range(min(3, len(hist))):
                if hist[-1 - k][1] == r_ and hist[-1 - k][0] != "trap":
                    hit(f"hazard:{hist[-1 - k][0]}_d{k + 1}_{role}")
                    break
        a = regs[d["uses"][0][0]] if d["uses"] else 0
        b = regs[d["uses"][1][0]] if len(d["uses"]) > 1 else 0
        # gia tri toan hang
        if nm in ("sll", "srl", "sra"):
            hit(f"alu:{nm}_sh{'0' if b & 31 == 0 else '31' if b & 31 == 31 else 'x'}")
        elif nm in ("slli", "srli", "srai", "c.slli", "c.srli", "c.srai"):
            pass
        elif nm in ZB:
            if nm in ("clz", "ctz", "cpop"):
                hit(f"zb:{nm}_{'zero' if a == 0 else 'ones' if a == 0xFFFFFFFF else 'other'}")
            elif nm in ("czero.eqz", "czero.nez"):
                hit(f"zb:{nm}_cond{'0' if b == 0 else 'nz'}")
            elif nm in ("rol", "ror", "bclr", "bext", "binv", "bset"):
                hit(f"zb:{nm}_sh{'0' if b & 31 == 0 else '31' if b & 31 == 31 else 'x'}")
            elif nm in ("rori", "bclri", "bexti", "binvi", "bseti"):
                hit(f"zb:{nm}_sh{'0' if d['imm'] == 0 else '31' if d['imm'] == 31 else 'x'}")
            elif nm in ("max", "min"):
                hit(f"zb:{nm}_{sgn(a).replace('z', 'p')}{sgn(b).replace('z', 'p')}")
        elif nm in ("slt", "sltu"):
            hit(f"alu:{nm}_{sgn(a)[0]}{sgn(b)[0]}".replace("z", "p"))
        elif nm in ("add", "sub", "addi"):
            bb = b if nm != "addi" else d["imm"] & 0xFFFFFFFF
            r_ = (a + bb) & 0xFFFFFFFF if nm != "sub" else (a - bb) & 0xFFFFFFFF
            sa, sb = (a >> 31), (bb >> 31) ^ (1 if nm == "sub" else 0)
            if sa == sb and (r_ >> 31) != sa:
                hit(f"alu:{nm}_overflow")
            if nm == "sub" and a == bb:
                hit("alu:sub_equal")
        elif nm in MD[:4]:
            hit(f"muldiv:{nm}_{sgn(a)}{sgn(b)}")
        elif nm in MD[4:]:
            if b == 0:
                hit(f"muldiv:{nm}_by0")
            elif nm in ("div", "rem") and a == 0x80000000 and b == 0xFFFFFFFF:
                hit(f"muldiv:{nm}_overflow")
            else:
                hit(f"muldiv:{nm}_{sgn(a)}{sgn(b)}".replace("z", "p"))
        # nhanh
        if d["cls"] == "br":
            c = {"beq": a == b, "bne": a != b, "blt": sx(a, 32) < sx(b, 32), "bge": sx(a, 32) >= sx(b, 32),
                 "bltu": a < b, "bgeu": a >= b, "c.beqz": a == 0, "c.bnez": a != 0}[nm]
            hit(f"branch:{nm}_{'taken' if c else 'not'}_{'back' if d['imm'] < 0 else 'fwd'}")
            if d["imm"] < 0 and c:
                loop_run[pc] = loop_run.get(pc, 0) + 1
            elif d["imm"] < 0:
                n_ = loop_run.pop(pc, 0)
                hit(f"cflow:loop_exit_after_{'1' if n_ == 0 else '2_3' if n_ < 4 else '4_plus'}")
            prev_pre = "br_taken" if c else "br_not"
        elif d["cls"] in ("link", "jump"):
            prev_pre = "jump"
            link = d["rd"] == 1
            if nm in ("jal", "c.jal"):
                hit("cflow:call" if link else "cflow:jump_jal")
            if nm in ("jalr", "c.jalr", "c.jr"):
                if (nm == "jalr" and d["rd"] == 0 and d["uses"][0][0] == 1) or (nm == "c.jr" and d["uses"][0][0] == 1):
                    hit("cflow:ret")
                elif link:
                    hit("cflow:call_indirect")
                else:
                    hit("cflow:jump_indirect")
        elif d["cls"] == "csr":
            prev_pre = "csr"
        else:
            prev_pre = {"alu": "alu", "upper": "upper", "load": "load", "store": "store", "mul": "mul", "div": "div",
                        "fence": "fence"}.get(d["cls"], "other")
        # bo nho
        if mem is not None:
            sz = {"lb": 1, "lbu": 1, "sb": 1, "lh": 2, "lhu": 2, "sh": 2, "c.lw": 4, "c.lwsp": 4, "c.sw": 4, "c.swsp": 4}.get(nm, 4)
            off = mem & 3
            hit(f"mem:{nm}_off{off}" if sz > 1 else f"mem:{nm}_off{off}")
            if (mem & 15) + sz > 16:
                hit(f"mem:{nm}_cross16")
            if d["cls"] == "load":
                if nm in ("lb", "lh") and rd:
                    hit(f"mem:{nm}_{'neg' if val & (0x80 if nm == 'lb' else 0x8000) else 'pos'}")
                if (mem & ~3) in last_store:
                    hit("mem:load_after_store_same_word")
            else:
                last_store[mem & ~3] = pc
                if len(last_store) > 8:
                    last_store.pop(next(iter(last_store)))
        # CSR
        if d["cls"] == "csr":
            nmc = CSRS.get(d["imm"] & 0xFFF, f"0x{d['imm'] & 0xFFF:x}")
            ro = (d["name"] in ("csrrs", "csrrc", "csrrsi", "csrrci")) and d["csr_rs1"] == 0
            hit(f"csr:{nmc}_{d['name']}" + ("_readonly" if ro else ""))
        if nm == "mret":
            hit("trap:mret")
        if nm in ("ecall", "ebreak", "c.ebreak"):
            pass
        # trap cung do dai
        if rd:
            regs[rd] = val
        elif d["rd"] and d["cls"] != "csr":
            pass
        hist.append((d["cls"] if d["cls"] in PROD else ("alu" if d["cls"] in ("br", "store", "fence", "sys", "jump") else d["cls"]), d["rd"] if rd else 0, d["rd"] == 0 and d["cls"] in PROD))
        # ghi chu: phan tu thu 3 danh dau "viet vao x0"
        del hist[:-3]
        if d["rd"] == 0 and d["cls"] in ("alu", "upper", "load", "mul", "div", "csr", "link") and rd == 0:
            hist[-1] = (hist[-1][0], 0, True)
    # trap: do dai lenh bi bo qua = khoang cach giua epc va lenh dau tien sau mret
    return cov


def catalog():
    """moi bin co the xay ra, theo nhom (de bao cao phan tram va liet ke bin chua phu)"""
    c = {}
    c["op"] = [f"op:{n}" for n in OPS]
    c["zb"] = [f"op:{n}" for n in ZB] + [f"zb:{n}_{k}" for n in ("clz", "ctz", "cpop") for k in ("zero", "ones", "other")] + \
        [f"zb:{n}_cond{k}" for n in ("czero.eqz", "czero.nez") for k in ("0", "nz")] + \
        [f"zb:{n}_sh{k}" for n in ("rol", "ror", "bclr", "bext", "binv", "bset", "rori", "bclri", "bexti", "binvi", "bseti") for k in ("0", "31", "x")] + \
        [f"zb:{n}_{x}{y}" for n in ("max", "min") for x in "np" for y in "np"]
    c["alu"] = [f"alu:{n}_sh{s}" for n in ("sll", "srl", "sra") for s in ("0", "31", "x")] + \
        [f"alu:{n}_{x}{y}" for n in ("slt", "sltu") for x in "np" for y in "np"] + \
        [f"alu:{n}_overflow" for n in ("add", "sub", "addi")] + ["alu:sub_equal"]
    c["muldiv"] = [f"muldiv:{n}_{x}{y}" for n in MD[:4] for x in "npz" for y in "npz"] + \
        [f"muldiv:{n}_{x}{y}" for n in MD[4:] for x in "np" for y in "np"] + \
        [f"muldiv:{n}_by0" for n in MD[4:]] + [f"muldiv:{n}_overflow" for n in ("div", "rem")]
    c["branch"] = [f"branch:{n}_{t}_{d}" for n in BR + ["c.beqz", "c.bnez"] for t in ("taken", "not") for d in ("fwd", "back")]
    prods = {"alu": ["alu_a", "alu_b", "load_base", "store_base", "store_data", "br_a", "br_b", "jalr_base", "csr_src", "md_a", "md_b"],
             "upper": ["alu_a", "alu_b", "load_base", "store_base", "store_data", "br_a", "br_b", "jalr_base", "md_a", "md_b"],
             "load": ROLES, "mul": ROLES, "div": ROLES, "csr": ROLES, "link": ["alu_a", "alu_b", "load_base", "store_data", "br_a", "jalr_base"]}
    c["hazard"] = [f"hazard:{p}_d{k}_{r}" for p, rs in prods.items() for k in (1, 2, 3) for r in rs] + \
        ["hazard:x0_written_then_read_d1", "hazard:x0_written_then_read_d2"]
    c["mem"] = [f"mem:{n}_off{o}" for n in LD + ST for o in range(4) if o % ({"lb": 1, "lbu": 1, "sb": 1, "lh": 2, "lhu": 2, "sh": 2}.get(n, 4)) == 0] + \
        ["mem:lb_neg", "mem:lb_pos", "mem:lh_neg", "mem:lh_pos", "mem:load_after_store_same_word"]
    c["mem_ma"] = [f"mem:{n}_off{o}" for n in ("lh", "lhu", "sh") for o in (1, 3)] + [f"mem:{n}_off{o}" for n in ("lw", "sw") for o in (1, 2, 3)] + \
        [f"mem:{n}_cross16" for n in ("lh", "lhu", "lw", "sh", "sw")]
    c["csr"] = [f"csr:{n}_{f}" for n in ("mscratch", "mtval", "mepc", "mstatus") for f in CS] + \
        [f"csr:{n}_{f}_readonly" for n in ("mscratch", "mepc", "mstatus", "mtvec", "mcause", "mhartid", "mie") for f in ("csrrs", "csrrc", "csrrsi", "csrrci")] + \
        ["csr:mie_csrrw", "csr:mtvec_csrrs_readonly"]
    c["trap"] = [f"trap:cause{k}" for k in (0, 2, 3, 4, 6, 11)] + ["trap:mret", "trap:illegal_len16", "trap:illegal_len32"] + \
        [f"trap:cause{k}_after_{p}" for k in (2, 3, 11) for p in PRE if p != "trap"] + \
        [f"trap:cause{k}_after_{p}" for k in (4, 6) for p in ("alu", "load", "store", "br_taken", "br_not")]
    c["cflow"] = ["cflow:call", "cflow:ret", "cflow:call_indirect", "cflow:jump_indirect", "cflow:jump_jal",
                  "cflow:loop_exit_after_1", "cflow:loop_exit_after_2_3", "cflow:loop_exit_after_4_plus"]
    return c


def summarize(cov, caps=None):
    """-> {nhom: (phu, tong, [bin chua phu])}; caps: tap mo rong cua loi ('c', 'm', 'zicclsm') de bo bin khong ap dung"""
    out = {}
    for g, bins in catalog().items():
        miss = [b for b in bins if cov.get(b, 0) == 0]
        out[g] = (len(bins) - len(miss), len(bins), miss)
    return out


if __name__ == "__main__":
    import sys, json
    cov = json.load(open(sys.argv[1]))["cov"]
    for g, (n, t, miss) in summarize(cov).items():
        print(f"{g:<8} {n:>4}/{t:<4}  chua phu: {', '.join(miss[:12])}{' ...' if len(miss) > 12 else ''}")
