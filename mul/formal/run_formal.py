#!/usr/bin/env python3
"""Chung minh hinh thuc bo nhan song song 33 x 33 bit (rv32_mul_csa) va phan noi vao rv32m, bang yosys + z3.

Nhan nguyen khoi 33 bit qua kho cho SAT, nen chia thanh cac bo de nho tren tung module con, roi ghep bang dai so:
  L1 l1_csa32.v   bo cong 3:2: s + c = x + y + z (mod 2^66)
  L2 l2_tree.v    cay CSA 18 hang giu tong (bo cong 3:2 thay bang mo hinh truu tuong thoa L1)
  L3 l3_booth.v   moi hang Booth i: hang + bit hieu chinh = d_i * A * 4^i (mod 2^66), i = 0..16; hang hieu chinh dung dang
  ALG algebra.py  ghep: tong hang = sum d_i A 4^i = A * B, va A * B vua 66 bit co dau
  => sum + carry cua rv32_mul_csa = a * b (co dau, chinh xac) voi MOI a, b 33 bit.
  L4 l4_rv32m.v   rv32m (MUL_LAT = 1 va 2) dung dac ta RISC-V cho MUL / MULH / MULHSU / MULHU, voi bo nhan thay bang
                  dinh ly tren va phep nhan thay bang ham khong dien giai (dung voi moi ham => dung voi phep nhan that).
Doi chung am: moi bo de chay them tren vai ban RTL co y sai, cac ban nay phai bi bao FAILED (bo de khong rong).
Dung (tu thu muc goc repo): python3 mul/formal/run_formal.py [--core <file rv32i_core.v>] [--no-neg]
Can yowasp-yosys (hoac yosys) va z3 (pip install z3-solver).
"""
import argparse, os, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
W, N = 33, (33 + 2) // 2


def tool(name):
    for t in (name, "yowasp-" + name):
        if shutil.which(t):
            return t
    sys.exit(f"khong tim thay {name} / yowasp-{name}")


YOSYS, SMTBMC = tool("yosys"), tool("yosys-smtbmc")

# (ten, file harness, top, chparam, so buoc, harness doc sau loi voi -overwrite, thay bvmul bang ham khong dien giai)
LEMMAS = [("L1 bo cong 3:2", "l1_csa32.v", "l1_csa32", {}, 1, False, False),
          ("L2 cay CSA 18 hang", "l2_tree.v", "l2_tree", {}, 1, True, False)]
LEMMAS += [(f"L3 hang Booth {i}", "l3_booth.v", "l3_booth", {"I": i}, 1, False, False) for i in range(N)]
LEMMAS += [("L3 hang hieu chinh", "l3_booth.v", "l3_booth", {"CORR": 1}, 1, False, False),
           ("L4 rv32m MUL_LAT = 1", "l4_rv32m.v", "l4_rv32m", {"LAT": 1}, 3, True, True),
           ("L4 rv32m MUL_LAT = 2", "l4_rv32m.v", "l4_rv32m", {"LAT": 2}, 3, True, True)]

# ban RTL co y sai (chuoi goc, chuoi thay, bo de phai bat) cho doi chung am
NEG = [
    ("bo cong 3:2: tong dung OR", "assign s = x ^ y ^ z;", "assign s = x | y | z;", "L1"),
    ("bo cong 3:2: nho khong dich trai", "assign c = ((x & y) | (x & z) | (y & z)) << 1;",
     "assign c = ((x & y) | (x & z) | (y & z));", "L1"),
    ("cay: hang chuyen thang bi mat", "assign t[l+1][(2*NG + g - 3*NG)*P +: P] = t[l][g*P +: P];",
     "assign t[l+1][(2*NG + g - 3*NG)*P +: P] = {P{1'b0}};", "L2"),
    ("cay: lay nho tang cuoi o sai hang", "assign carry = t[LV][P +: P];", "assign carry = t[LV][0 +: P];", "L2"),
    ("Booth: nhom 011 chon a", "3'b011:         begin pp = a2m; neg = 1'b0; end",
     "3'b011:         begin pp = am;  neg = 1'b0; end", "L3"),
    ("Booth: nhom 100 quen dau am", "3'b100:         begin pp = a2m; neg = 1'b1; end",
     "3'b100:         begin pp = a2m; neg = 1'b0; end", "L3"),
    ("Booth: bit hieu chinh lech vi tri", "corr    = corr | ({{(P-1){1'b0}}, neg} << (2 * i));",
     "corr    = corr | ({{(P-1){1'b0}}, neg} << (2 * i + 1));", "L3"),
    ("Booth: a khong mo rong dau", "am   = {{W{a[W-1]}}, a};", "am   = {{W{1'b0}}, a};", "L3"),
    ("Booth: b khong mo rong dau", "bb   = {{(2*N-W){b[W-1]}}, b, 1'b0};", "bb   = {{(2*N-W){1'b0}}, b, 1'b0};", "L3"),
    ("rv32m: MULHSU coi a khong dau", "wire        fsa = (funct3[1:0] == 2'b01 | funct3[1:0] == 2'b10) & a[31];",
     "wire        fsa = (funct3[1:0] == 2'b01) & a[31];", "L4"),
    ("rv32m: MULH coi b khong dau", "wire        fsb = (funct3[1:0] == 2'b01) & b[31];", "wire        fsb = 1'b0;", "L4"),
    ("rv32m: MULHU lay nua thap", "wire [31:0] f_res = (f_op == 2'b00) ? f_p[31:0] : f_p[63:32];",
     "wire [31:0] f_res = (f_op == 2'b00 | f_op == 2'b11) ? f_p[31:0] : f_p[63:32];", "L4"),
    ("rv32m: 2 tang khong chot loai lenh", "mw_op <= funct3[1:0];", "mw_op <= 2'b00;", "L4"),
    ("rv32m: 2 tang bao xong som", "assign done = (state == FIN) | (state == MW) | f_now;",
     "assign done = (state == FIN) | (state == MW) | f_now | ((MUL_LAT == 2) & f_go);", "L4"),
    ("rv32m: 1 chu ky khong bao xong", "wire        f_now = (MUL_LAT == 1) & f_go;", "wire        f_now = 1'b0;", "L4"),
    ("rv32m: co lap toan hang sai trang thai", "wire        f_go = (MUL_LAT != 0) & (state == IDLE) & req & fast_mul;",
     "wire        f_go = (MUL_LAT != 0) & (state == MW) & req & fast_mul;", "L4"),
]


def check(lemma, core, work):
    """-> (True: PASSED / False: FAILED / None: loi hoac het gio, thoi gian)"""
    name, harness, top, params, steps, overwrite, uf = lemma
    for f in (harness, "l2_tree.v", "l4_rv32m.v"):
        shutil.copy(os.path.join(HERE, f), work)
    shutil.copy(core, os.path.join(work, "core.v"))
    ch = "".join(f"chparam -set {k} {v} {top}; " for k, v in params.items())
    rd = (f"read_verilog -formal core.v; read_verilog -formal -overwrite {harness}; " if overwrite
          else f"read_verilog -formal {harness} core.v; ")
    # khong dung wreduce / opt de yosys khong thu hep do rong phep nhan (can giu 66 bit cho ham khong dien giai)
    flow = (f"hierarchy -top {top}; proc; flatten; opt_clean; async2sync; dffunmap" if uf
            else f"prep -top {top}; flatten; async2sync; opt; dffunmap")
    t0 = time.time()
    r = subprocess.run([YOSYS, "-q", "-p", rd + ch + flow + "; write_smt2 -wires m.smt2"], cwd=work,
                       capture_output=True, text=True)
    if r.returncode:
        return None, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "loi yosys", 0
    if uf:
        s = open(os.path.join(work, "m.smt2")).read().replace("(bvmul ", "(ufmul ")
        i = s.index("\n(")
        s = s[:i] + "\n(declare-fun ufmul ((_ BitVec 66) (_ BitVec 66)) (_ BitVec 66))" + s[i:]
        open(os.path.join(work, "m.smt2"), "w").write(s)
    try:
        r = subprocess.run([SMTBMC, "-s", "z3", "-t", str(steps), "m.smt2"], cwd=work, capture_output=True, text=True,
                           timeout=600)
    except subprocess.TimeoutExpired:
        return None, "het gio 600 s", time.time() - t0
    out = r.stdout + r.stderr
    st = re.search(r"Status: (\w+)", out)
    if not st:
        return None, (out.strip().splitlines() or ["?"])[-1][:150], time.time() - t0
    return st.group(1) == "PASSED", "", time.time() - t0


def run_lemmas(core, work, only=None, show=True):
    res = {}
    for k, lm in enumerate(LEMMAS):
        if only and not lm[0].startswith(only):
            continue
        ok, why, dt = check(lm, core, work)
        res[lm[0]] = ok
        if show:
            tag = {True: "PASS", False: "FAIL", None: "LOI "}[ok]
            print(f"  [{k + 1:2}/{len(LEMMAS)}] {tag}  {lm[0]}  ({dt:.1f} s){'  ' + why if why else ''}", flush=True)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", default=os.path.join(ROOT, "rv32i_core.v"))
    ap.add_argument("--no-neg", action="store_true", help="bo qua doi chung am")
    a = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mulf_")
    print("Bo de tren RTL that:")
    res = run_lemmas(a.core, work)
    print("Ghep dai so (algebra.py):")
    alg = subprocess.run([sys.executable, os.path.join(HERE, "algebra.py")], capture_output=True, text=True)
    print(alg.stdout.rstrip())
    ok = all(v is True for v in res.values()) and alg.returncode == 0
    if not a.no_neg:
        print("Doi chung am (RTL co y sai, phai FAIL):")
        src = open(a.core).read()
        for k, (name, old, new, lem) in enumerate(NEG):
            if src.count(old) != 1:
                print(f"  [{k + 1:2}/{len(NEG)}] BO QUA  {name}: khong tim thay chuoi goc")
                ok = False
                continue
            bad = os.path.join(work, "bad_core.v")
            open(bad, "w").write(src.replace(old, new))
            r = run_lemmas(bad, work, only=lem, show=False)
            caught = any(v is False for v in r.values())
            ok &= caught
            print(f"  [{k + 1:2}/{len(NEG)}] {'BAT' if caught else 'SOT'}  {name}: "
                  f"{sum(v is False for v in r.values())}/{len(r)} bo de {lem} FAIL", flush=True)
    shutil.rmtree(work, ignore_errors=True)
    print("KET QUA:", "DAT" if ok else "KHONG DAT")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
