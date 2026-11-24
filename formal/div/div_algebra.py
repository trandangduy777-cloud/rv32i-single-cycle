#!/usr/bin/env python3
"""Phan dai so cua chung minh bo chia rv32m (cung kieu mul/formal/algebra.py): z3 tren so nguyen khong gioi han.

Harness (formal/div/div.sby) chung minh tren RTL: khi lenh chia xong, voi |a|, |b| la gia tri tuyet doi toan hang,
  (H1) du R + g_p = |a|          (g_p cong don theo dung cac bit thuong da day vao: g_p <- 2 g_p + q * |b|, chi bo cong)
  (H2) |b| = 0  hoac  R < |b|
  (H3) |b| = 0  thi thuong Q = 2^32 - 1 va R = |a|
  (H4) ket qua tra ve DIV/DIVU/REM/REMU bang Q hoac R (dao dau theo dau toan hang va b != 0).
File nay chung minh hai viec con lai:
  (D1) g_p = Q * |b| sau 32 buoc: quy nap Horner, Q <- 2Q + q, g_p <- 2 g_p + q|b| => g_p = Q |b| (moi q thuoc {0,1});
  (D2) H1..H4 + D1 => ket qua dung dac ta RISC-V cho DIV, DIVU, REM, REMU voi MOI cap (a, b) 32 bit, ke ca chia 0 va tran
       (-2^31 / -1): thuong cat ve 0, du cung dau so bi chia, a = b * thuong + du, |du| < |b|.
Chay: python3 formal/div/div_algebra.py   (can z3-solver)
"""
import sys
from z3 import Int, Ints, Bool, If, And, Or, Not, Implies, Solver, unsat, sat, Sum, IntVal

M32 = 1 << 32


def prove(name, hyps, goal):
    s = Solver()
    s.set("timeout", 120000)
    for h in hyps:
        s.add(h)
    s.add(Not(goal))
    r = s.check()
    print(f"  {name}: {'DUNG' if r == unsat else ('SAI/khong ket luan: ' + str(r))}")
    return r == unsat


def horner():
    # D1: voi 32 bit q_0..q_31 (q_0 la bit cao nhat day vao truoc) va |b| = D tuy y
    D = Int("D")
    qs = [Int(f"q{i}") for i in range(32)]
    hyps = [And(q >= 0, q <= 1) for q in qs]
    Q, P = IntVal(0), IntVal(0)
    for q in qs:
        Q = 2 * Q + q
        P = 2 * P + q * D
    return prove("D1: g_p = Q * |b|", hyps, P == Q * D)


def sem(a, b):
    """dac ta RISC-V (so nguyen) cua DIV, DIVU, REM, REMU voi a, b la so 32 bit (dang so nguyen khong dau 0..2^32-1)."""
    sa = If(a >= 2**31, a - M32, a)    # gia tri co dau
    sb = If(b >= 2**31, b - M32, b)
    return sa, sb


def main_lemma(drop=None):
    a, b, Q, R, P = Ints("a b Q R P")
    base = [a >= 0, a < M32, b >= 0, b < M32, Q >= 0, Q < M32, R >= 0, R < M32]
    sa_a, sb_b = sem(a, b)
    ok = True
    for f, signed in (("DIV", 1), ("DIVU", 0), ("REM", 1), ("REMU", 0)):
        sa = (a >= 2**31) if signed else False
        sb = (b >= 2**31) if signed else False
        ua = If(sa, M32 - a, a) if signed else a
        ub = If(sb, M32 - b, b) if signed else b
        # ua = |a|, ub = |b| (a = 0 hoac 2^31: |a| = 2^31 van dung vi M32 - 2^31 = 2^31; a = 0: sa sai nen ua = a = 0)
        hyp = base + [P == Q * ub, R + P == ua, Or(ub == 0, R < ub), Implies(ub == 0, And(Q == M32 - 1, R == ua))]
        if drop is not None:                       # doi chung am: bo mot gia thiet thi phai khong chung minh duoc
            hyp = base + [h for i, h in enumerate(hyp[len(base):]) if i != drop]
        negq = And(sa != sb, b != 0)
        res_div = If(negq, If(Q == 0, 0, M32 - Q), Q)             # ~Q + 1 theo 32 bit
        res_rem = If(sa, If(R == 0, 0, M32 - R), R)
        # tri so co dau cua ket qua (de so voi dac ta)
        def sgn(x):
            return If(x >= 2**31, x - M32, x)
        if f == "DIVU":
            goal = If(b == 0, Q == M32 - 1, And(Q * b <= a, a < Q * b + b))           # thuong nguyen: floor(a / b)
            ok &= prove(f, hyp, goal)
        elif f == "REMU":
            goal = If(b == 0, R == a, And(R < b, a == Q * b + R))                      # du: a mod b
            ok &= prove(f, hyp, goal)
        elif f == "DIV":
            q = sgn(res_div)
            # b = 0: -1; tran -2^31 / -1: -2^31; con lai: a = b q + r, r cung dau a (hoac 0), |r| < |b|, r = sgn(du)
            r = If(sa, -R, R)
            normal = And(sa_a == sb_b * q + r, Or(r == 0, (r > 0) == (sa_a > 0)), If(r >= 0, r, -r) < If(sb_b >= 0, sb_b, -sb_b))
            goal = If(b == 0, q == -1, If(And(a == 2**31, b == M32 - 1), q == -(2**31), normal))
            ok &= prove(f, hyp, goal)
        else:  # REM
            rem = sgn(res_rem)
            q = If(negq, -Q, Q)
            normal = And(sa_a == sb_b * q + rem, Or(rem == 0, (rem > 0) == (sa_a > 0)), If(rem >= 0, rem, -rem) < If(sb_b >= 0, sb_b, -sb_b))
            goal = If(b == 0, rem == sa_a, If(And(a == 2**31, b == M32 - 1), rem == 0, normal))
            ok &= prove(f, hyp, goal)
    return ok


if __name__ == "__main__":
    ok = horner()
    ok &= main_lemma()
    print("Doi chung am (bo tung gia thiet cua harness, moi lan it nhat mot phep chia phai khong chung minh duoc):")
    for d, nm in enumerate(["P = Q|b|", "R + P = |a|", "R < |b|", "chia 0"]):
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            r = main_lemma(drop=d)
        print(f"  bo '{nm}':", "van chung minh duoc (SAI, gia thiet thua)" if r else "khong chung minh duoc (dung)")
        ok &= not r
    print("KET QUA:", "DAT" if ok else "KHONG DAT")
    sys.exit(0 if ok else 1)
