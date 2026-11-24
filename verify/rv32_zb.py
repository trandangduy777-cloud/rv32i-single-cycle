#!/usr/bin/env python3
"""Ngu nghia cua Zba, Zbb, Zbs, Zbc, Zicond (RV32) cho ISS, viet theo dac ta bang so nguyen Python,
KHONG sao chep cach lam cua RTL (RTL dung bo quay chung, vong lap clz, ...).

decode(exts, op, f3, f7, rs2) -> ten lenh, hoac None neu khong phai lenh hop le cua cac phan mo rong dang bat.
  exts: tap con cua {"zba", "zbb", "zbs", "zbc", "zicond"}
  op  : opcode 7 bit (0x33 = OP, 0x13 = OP-IMM); f7 = ins[31:25]; rs2 = ins[24:20]
execute(name, a, b) -> gia tri 32 bit. Voi dang immediate, b = shamt 5 bit (= ins[24:20]).
"""
M32 = 0xFFFFFFFF
ALL_EXTS = ("zba", "zbb", "zbs", "zbc", "zicond")

# (opcode, funct7, funct3) -> (ten, phan mo rong, rs2 bat buoc hoac None)
_TABLE = {}


def _add(op, f7, f3, name, ext, rs2=None):
    _TABLE[(op, f7, f3)] = _TABLE.get((op, f7, f3), []) + [(name, ext, rs2)]


R, I = 0x33, 0x13
for f3, n in ((0b010, "sh1add"), (0b100, "sh2add"), (0b110, "sh3add")):
    _add(R, 0b0010000, f3, n, "zba")
for f3, n in ((0b111, "andn"), (0b110, "orn"), (0b100, "xnor")):
    _add(R, 0b0100000, f3, n, "zbb")
for f3, n in ((0b100, "min"), (0b101, "minu"), (0b110, "max"), (0b111, "maxu")):
    _add(R, 0b0000101, f3, n, "zbb")
_add(R, 0b0110000, 0b001, "rol", "zbb")
_add(R, 0b0110000, 0b101, "ror", "zbb")
_add(R, 0b0000100, 0b100, "zext.h", "zbb", 0)
_add(R, 0b0100100, 0b001, "bclr", "zbs")
_add(R, 0b0100100, 0b101, "bext", "zbs")
_add(R, 0b0110100, 0b001, "binv", "zbs")
_add(R, 0b0010100, 0b001, "bset", "zbs")
for f3, n in ((0b001, "clmul"), (0b010, "clmulr"), (0b011, "clmulh")):
    _add(R, 0b0000101, f3, n, "zbc")
_add(R, 0b0000111, 0b101, "czero.eqz", "zicond")
_add(R, 0b0000111, 0b111, "czero.nez", "zicond")
for r2, n in ((0, "clz"), (1, "ctz"), (2, "cpop"), (4, "sext.b"), (5, "sext.h")):
    _add(I, 0b0110000, 0b001, n, "zbb", r2)
_add(I, 0b0110000, 0b101, "rori", "zbb")
_add(I, 0b0010100, 0b101, "orc.b", "zbb", 0b00111)
_add(I, 0b0110100, 0b101, "rev8", "zbb", 0b11000)
_add(I, 0b0100100, 0b001, "bclri", "zbs")
_add(I, 0b0100100, 0b101, "bexti", "zbs")
_add(I, 0b0110100, 0b001, "binvi", "zbs")
_add(I, 0b0010100, 0b001, "bseti", "zbs")

ALL_NAMES = sorted({n for v in _TABLE.values() for (n, _, _) in v})
NAMES_OF = {e: sorted({n for v in _TABLE.values() for (n, x, _) in v if x == e}) for e in ALL_EXTS}


def decode(exts, op, f3, f7, rs2):
    for name, ext, need in _TABLE.get((op, f7, f3), ()):
        if ext in exts and (need is None or need == rs2):
            return name
    return None


def _s(v):
    return v - (1 << 32) if v >> 31 else v


def _rot(a, n):          # quay phai n bit (n 0..31)
    n &= 31
    return ((a >> n) | (a << (32 - n))) & M32


def _clmul(a, b):
    r = 0
    for i in range(32):
        if (b >> i) & 1:
            r ^= a << i
    return r             # tich day du (63 bit)


def execute(name, a, b):
    a &= M32
    b &= M32
    sh = b & 31
    if name == "sh1add": return ((a << 1) + b) & M32
    if name == "sh2add": return ((a << 2) + b) & M32
    if name == "sh3add": return ((a << 3) + b) & M32
    if name == "andn": return a & ~b & M32
    if name == "orn": return (a | ~b) & M32
    if name == "xnor": return ~(a ^ b) & M32
    if name == "clz": return 32 - a.bit_length()
    if name == "ctz": return 32 if a == 0 else (a & -a).bit_length() - 1
    if name == "cpop": return bin(a).count("1")
    if name == "sext.b": return (a & 0xFF) | (M32 ^ 0xFF if a & 0x80 else 0)
    if name == "sext.h": return (a & 0xFFFF) | (M32 ^ 0xFFFF if a & 0x8000 else 0)
    if name == "zext.h": return a & 0xFFFF
    if name == "max": return a if _s(a) >= _s(b) else b
    if name == "maxu": return a if a >= b else b
    if name == "min": return a if _s(a) <= _s(b) else b
    if name == "minu": return a if a <= b else b
    if name == "rol": return _rot(a, 32 - sh)
    if name in ("ror", "rori"): return _rot(a, sh)
    if name == "orc.b": return sum(0xFF << (8 * i) for i in range(4) if (a >> (8 * i)) & 0xFF)
    if name == "rev8": return int.from_bytes(a.to_bytes(4, "little"), "big")
    if name in ("bclr", "bclri"): return a & ~(1 << sh) & M32
    if name in ("bext", "bexti"): return (a >> sh) & 1
    if name in ("binv", "binvi"): return a ^ (1 << sh)
    if name in ("bset", "bseti"): return a | (1 << sh)
    if name == "clmul": return _clmul(a, b) & M32
    if name == "clmulh": return (_clmul(a, b) >> 32) & M32
    if name == "clmulr": return (_clmul(a, b) >> 31) & M32
    if name == "czero.eqz": return 0 if b == 0 else a
    if name == "czero.nez": return a if b == 0 else 0
    raise ValueError(name)


# ---- ma hoa (cho bo sinh chuong trinh va test): tra ve ma lenh 32 bit ----
def encode(name, rd, rs1, rs2_or_shamt):
    for (op, f7, f3), v in _TABLE.items():
        for n, _, need in v:
            if n == name:
                r2 = need if need is not None else rs2_or_shamt
                return (f7 << 25) | ((r2 & 31) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
    raise ValueError(name)


IMM_FORMS = {"rori", "bclri", "bexti", "binvi", "bseti"}                    # co shamt thay vi rs2
UNARY = {"clz", "ctz", "cpop", "sext.b", "sext.h", "orc.b", "rev8", "zext.h"}  # chi dung rs1


if __name__ == "__main__":
    # tu kiem tra nhanh mot so gia tri da biet theo dac ta
    assert execute("clz", 0, 0) == 32 and execute("ctz", 0, 0) == 32 and execute("clz", 1, 0) == 31
    assert execute("rev8", 0x01020304, 0) == 0x04030201 and execute("orc.b", 0x00010002, 0) == 0x00FF00FF
    assert execute("rol", 0x80000001, 1) == 0x00000003 and execute("ror", 0x80000001, 1) == 0xC0000000
    assert execute("clmul", 3, 3) == 5 and execute("clmulh", 0x80000000, 0x80000000) == 0x40000000
    assert execute("max", 0xFFFFFFFF, 1) == 1 and execute("maxu", 0xFFFFFFFF, 1) == 0xFFFFFFFF
    assert execute("sext.b", 0x80, 0) == 0xFFFFFF80 and execute("sh3add", 1, 5) == 13
    assert execute("czero.eqz", 7, 0) == 0 and execute("czero.nez", 7, 0) == 7
    print("rv32_zb.py: tu kiem tra dat,", len(ALL_NAMES), "lenh")
