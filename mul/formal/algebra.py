#!/usr/bin/env python3
"""Cac buoc dai so noi 3 bo de RTL (l1_csa32, l2_tree, l3_booth) thanh dinh ly: sum + carry = a * b (co dau) cho W = 33.
Kiem bang z3. Khong co buoc nao can SAT tren phep nhan bit-vector.

(A) Bit-vector P = 2W bit, cac bien tu do: r_i (hang i), c_i (bit 2i cua hang hieu chinh), e_i (d_i * A * 4^i).
    Gia thiet r_i + c_i = e_i (bo de 3) va corr = sum c_i (bo de 3, CORR)  =>  sum r_i + corr = sum e_i.
    Tuc tong moi hang vao cay = sum_i d_i * A * 4^i (mod 2^P); cay giu tong (bo de 1 + 2) nen sum + carry cung vay.
(B) So nguyen (khong mod): voi bit b_k thuoc {0, 1}, B = -b_{W-1} 2^{W-1} + sum_{k<W-1} b_k 2^k (gia tri co dau cua b),
    d_i = -2 b_{2i+1} + b_{2i} + b_{2i-1} (b_{-1} = 0, b_k = b_{W-1} khi k >= W):  sum_i d_i 4^i = B  (dang thuc Booth),
    nen sum_i d_i * A * 4^i = A * B voi moi so nguyen A.
(C) A, B trong [-2^{W-1}, 2^{W-1} - 1] => -2^{2W-1} <= A * B < 2^{2W-1}: tich dung trong P = 2W bit co dau, nen
    (A * B mod 2^P) doc theo co dau chinh la A * B.
(A) + (B) + (C): sum + carry (2W bit, co dau) = a * b chinh xac. Phep chuyen tu so nguyen sang mod 2^P o (A)/(B) la dong
    cau vanh Z -> Z/2^P (cong, nhan giu nguyen), khong can kiem.
"""
import sys
import z3

W = 33
N = (W + 2) // 2
P = 2 * W


def prove(name, claim, hyps=(), expect=True):
    """expect = False: doi chung am, menh de sai phai bi z3 bac bo (co phan vi du)"""
    s = z3.Solver()
    s.set("timeout", 600_000)
    s.add(*hyps)
    s.add(z3.Not(claim))
    r = s.check()
    if expect:
        ok = r == z3.unsat
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f" ({r})"), flush=True)
    else:
        ok = r == z3.sat
        print(f"  {'BAT' if ok else 'SOT'}  doi chung am: {name}" + ("" if ok else f" ({r})"), flush=True)
    return ok


def main():
    ok = True
    # (A)
    r = [z3.BitVec(f"r{i}", P) for i in range(N)]
    c = [z3.BitVec(f"c{i}", P) for i in range(N)]
    e = [z3.BitVec(f"e{i}", P) for i in range(N)]
    corr = z3.BitVec("corr", P)
    ok &= prove("(A) cong cac dang thuc tung hang: sum r_i + corr = sum e_i (mod 2^P)",
                z3.Sum(r) + corr == z3.Sum(e),
                [r[i] + c[i] == e[i] for i in range(N)] + [corr == z3.Sum(c)])
    # (B)
    bits = [z3.Int(f"b{k}") for k in range(W)]
    rng = [z3.Or(x == 0, x == 1) for x in bits]

    def bit(k):
        return 0 if k < 0 else bits[min(k, W - 1)]

    B = -bits[W - 1] * 2 ** (W - 1) + z3.Sum([bits[k] * 2 ** k for k in range(W - 1)])
    d = [-2 * bit(2 * i + 1) + bit(2 * i) + bit(2 * i - 1) for i in range(N)]
    ok &= prove("(B1) dang thuc Booth: sum_i d_i 4^i = B", z3.Sum([d[i] * 4 ** i for i in range(N)]) == B, rng)
    A = z3.Int("A")
    ok &= prove("(B2) sum_i d_i * A * 4^i = A * B voi moi so nguyen A",
                z3.Sum([d[i] * A * 4 ** i for i in range(N)]) == A * B, rng)
    # (C)
    Ai, Bi = z3.Int("Ai"), z3.Int("Bi")
    lo, hi = -2 ** (W - 1), 2 ** (W - 1) - 1
    ok &= prove("(C) |A * B| vua 2W bit co dau",
                z3.And(Ai * Bi >= -2 ** (P - 1), Ai * Bi < 2 ** (P - 1)),
                [Ai >= lo, Ai <= hi, Bi >= lo, Bi <= hi])
    # doi chung am: cac menh de sai gan giong phai bi bac bo
    Bu = z3.Sum([bits[k] * 2 ** k for k in range(W)])                       # coi b khong dau
    ok &= prove("Booth voi b khong dau", z3.Sum([d[i] * 4 ** i for i in range(N)]) == Bu, rng, expect=False)
    d_bad = [-2 * bit(2 * i + 1) + bit(2 * i) for i in range(N)]            # quen b[2i-1]
    ok &= prove("Booth quen b[2i-1]", z3.Sum([d_bad[i] * 4 ** i for i in range(N)]) == B, rng, expect=False)
    ok &= prove("tich vua 2W - 2 bit", z3.And(Ai * Bi >= -2 ** (P - 3), Ai * Bi < 2 ** (P - 3)),
                [Ai >= lo, Ai <= hi, Bi >= lo, Bi <= hi], expect=False)
    ok &= prove("cong tung hang khi corr thieu mot bit", z3.Sum(r) + corr == z3.Sum(e),
                [r[i] + c[i] == e[i] for i in range(N)] + [corr == z3.Sum(c[1:])], expect=False)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
