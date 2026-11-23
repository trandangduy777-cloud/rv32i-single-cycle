#!/usr/bin/env python3
"""Mutation test cho bo nhan song song (rv32_mul_csa va phan noi vao rv32m trong rv32i_core.v).

Bo kiem chung:
- "unit":  mul/tb_mul.v thu het moi cap o W = 8 va cac gia tri bien + 2000 cap ngau nhien o W = 33.
- "rand":  verify/run_verify.py --pipem (MUL_LAT = 2, mac dinh), 40 chuong trinh ngau nhien so voi ISS Python.
- "rand1": nhu "rand" voi --mul-lat 1.
Moi dot bien chay tren mot ban sao cua repo trong thu muc tam. Dung (tu thu muc goc repo): python3 mul/mutate_mul.py
"""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
F = "rv32i_core.v"

MUTATIONS = [
    # ---- rv32_mul_csa ----
    ("Booth: nhom 011 chon a thay vi 2a", "3'b011:         begin pp = a2m; neg = 1'b0; end",
     "3'b011:         begin pp = am;  neg = 1'b0; end", "unit"),
    ("Booth: nhom 100 quen dau am", "3'b100:         begin pp = a2m; neg = 1'b1; end",
     "3'b100:         begin pp = a2m; neg = 1'b0; end", "unit"),
    ("thieu hang hieu chinh (+1 cua cac hang am)", "row0[N] = corr;", "row0[N] = {P{1'b0}};", "unit"),
    ("hang hieu chinh dat sai vi tri", "corr    = corr | ({{(P-1){1'b0}}, neg} << (2 * i));",
     "corr    = corr | ({{(P-1){1'b0}}, neg} << (2 * i + 1));", "unit"),
    ("bo cong 3:2: nho khong dich trai", "assign t[l+1][(2*g+1)*P +: P] = ((x & y) | (x & z) | (y & z)) << 1;",
     "assign t[l+1][(2*g+1)*P +: P] = ((x & y) | (x & z) | (y & z));", "unit"),
    ("bo cong 3:2: tong dung OR", "assign t[l+1][(2*g)*P +: P]   = x ^ y ^ z;",
     "assign t[l+1][(2*g)*P +: P]   = x | y | z;", "unit"),
    ("so bi nhan khong mo rong dau", "am   = {{W{a[W-1]}}, a};", "am   = {{W{1'b0}}, a};", "unit"),
    ("so nhan khong mo rong dau", "bb   = {{(2*N-W){b[W-1]}}, b, 1'b0};", "bb   = {{(2*N-W){1'b0}}, b, 1'b0};", "unit"),
    ("hang thua cua tang rut gon bi mat", "assign t[l+1][(2*NG + g - 3*NG)*P +: P] = t[l][g*P +: P];",
     "assign t[l+1][(2*NG + g - 3*NG)*P +: P] = {P{1'b0}};", "unit"),
    # ---- noi vao rv32m ----
    ("MULHSU coi a khong dau", "wire        fsa = (funct3[1:0] == 2'b01 | funct3[1:0] == 2'b10) & a[31];",
     "wire        fsa = (funct3[1:0] == 2'b01) & a[31];", "rand"),
    ("MULH coi b khong dau", "wire        fsb = (funct3[1:0] == 2'b01) & b[31];", "wire        fsb = 1'b0;", "rand"),
    ("MULHU lay nua thap", "wire [31:0] f_res = (f_op == 2'b00) ? f_p[31:0] : f_p[63:32];",
     "wire [31:0] f_res = (f_op == 2'b00 | f_op == 2'b11) ? f_p[31:0] : f_p[63:32];", "rand"),
    ("2 tang: khong chot loai lenh nhan", "mw_op <= funct3[1:0];", "mw_op <= 2'b00;", "rand"),
    ("2 tang: bao xong som 1 chu ky", "assign done = (state == FIN) | (state == MW) | f_now;",
     "assign done = (state == FIN) | (state == MW) | f_now | ((MUL_LAT == 2) & f_go);", "rand"),
    ("co lap toan hang sai trang thai", "wire        f_go = (MUL_LAT != 0) & (state == IDLE) & req & fast_mul;",
     "wire        f_go = (MUL_LAT != 0) & (state == MW) & req & fast_mul;", "rand"),
    ("lenh chia bi dua vao bo nhan", "wire        fast_mul = (MUL_LAT != 0) & ~funct3[2];",
     "wire        fast_mul = (MUL_LAT != 0);", "rand"),
    ("1 chu ky: khong bao xong", "wire        f_now = (MUL_LAT == 1) & f_go;", "wire        f_now = 1'b0;", "rand1"),
    ("1 chu ky: ket qua lay tu thanh ghi tang 2", "wire [65:0] f_p  = (MUL_LAT == 2) ? (mw_s + mw_c) : (f_s + f_c);",
     "wire [65:0] f_p  = (MUL_LAT != 0) ? (mw_s + mw_c) : (f_s + f_c);", "rand1"),
]


def run_unit(rep):
    for w, extra in ((8, []), (33, ["+n=2000"])):
        vvp = os.path.join(rep, f"m{w}.vvp")
        r = subprocess.run(["iverilog", "-g2012", f"-DW={w}", "-o", vvp, os.path.join(rep, "mul", "tb_mul.v"),
                            os.path.join(rep, F)], capture_output=True, text=True)
        if r.returncode:
            return None, "loi bien dich: " + r.stderr[-150:]
        try:
            out = subprocess.run(["vvp", "-n", vvp] + extra, capture_output=True, text=True, timeout=900).stdout
        except subprocess.TimeoutExpired:
            return True, f"treo (W={w})"
        line = next((l for l in out.splitlines() if l.startswith("[MUL]")), "khong co ket qua")
        if "PASS" not in line:
            return True, line
    return False, "tb_mul PASS"


def run_rand(rep, extra):
    try:
        r = subprocess.run([sys.executable, os.path.join(rep, "verify", "run_verify.py"), "--pipem", "--n", "40"] + extra,
                           capture_output=True, text=True, timeout=2400)
    except subprocess.TimeoutExpired:
        return True, "treo"
    out = r.stdout + r.stderr
    if "Bien dich RTL that bai" in out:
        return None, out.strip()[-200:]
    first = out.splitlines()[0] if out else ""
    return bool(r.returncode), first


def main():
    src = open(os.path.join(ROOT, F)).read()
    killed, bad = 0, 0
    for name, old, new, how in MUTATIONS:
        if src.count(old) != 1:
            print(f"  BO QUA  {name}: khong tim thay chuoi goc", flush=True)
            bad += 1
            continue
        tmp = tempfile.mkdtemp(prefix="mutm_")
        rep = os.path.join(tmp, "repo")
        shutil.copytree(ROOT, rep, ignore=shutil.ignore_patterns(".git", "results", "*.vcd", "*.vvp", "eembc"))
        open(os.path.join(rep, F), "w").write(src.replace(old, new))
        if how == "unit":
            caught, detail = run_unit(rep)
        else:
            caught, detail = run_rand(rep, ["--mul-lat", "1"] if how == "rand1" else [])
        if caught is None:
            bad += 1
            print(f"  LOI   [{how}] {name}: {detail}", flush=True)
        else:
            killed += caught
            print(f"  {'BAT' if caught else 'SOT'}  [{how}] {name}: {str(detail)[:150]}", flush=True)
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"bat duoc {killed}/{len(MUTATIONS)} dot bien")
    sys.exit(0 if killed == len(MUTATIONS) else 1)


if __name__ == "__main__":
    main()
