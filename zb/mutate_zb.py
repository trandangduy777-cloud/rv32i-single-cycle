#!/usr/bin/env python3
"""Mutation test cho Zba/Zbb/Zbs/Zbc/Zicond cua rv32im_pipeline.v: moi dot bien phai bi bat.

Moi dot bien sua 1 doan trong khoi giai ma (ID) hoac thuc thi (zb_out, EX) cua cac lenh moi, roi chay
verify/run_verify.py --pipem (so vet tung lenh voi ISS Python) tren mot ban sao cua repo trong thu muc tam.
Hai cau hinh:
- "all":  ca 5 phan mo rong bat (--zb all --zb-probe): bat sai ket qua / sai giai ma tung lenh.
- "gate1": chi bat zbb + zbs (ZBA, ZBC, ZICOND tat); "gate2": chi bat zba + zbc + zicond (ZBB, ZBS tat). Bat dot bien
          lam lenh cua phan mo rong DANG TAT khong con la lenh bat hop le (--zb-probe sinh ca ma cua phan mo rong tat).
Dung (tu thu muc goc repo): python3 zb/mutate_zb.py [--only <chuoi trong ten>] [--n <so chuong trinh>]
"""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
F = "rv32im_pipeline.v"

# (ten, chuoi goc (xuat hien dung 1 lan), chuoi thay, cau hinh)
M = []


def m(name, old, new, cfg="all"):
    M.append((name, old, new, cfg))


# ---- giai ma (ID) ----
m("sh1add: sai funct3 (010 -> 011)", "{7'b0010000, 3'b010}: begin zb_reg_ok = (ZBA != 0); zb_op = Z_SH1ADD;",
  "{7'b0010000, 3'b011}: begin zb_reg_ok = (ZBA != 0); zb_op = Z_SH1ADD;")
m("sh2add va sh3add doi ma thao tac", "zb_op = Z_SH2ADD; end", "zb_op = Z_SH3ADD; end")
m("andn va orn doi ma thao tac", "{7'b0100000, 3'b111}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_ANDN;",
  "{7'b0100000, 3'b111}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_ORN;")
m("min va minu doi ma thao tac", "{7'b0000101, 3'b100}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_MIN;",
  "{7'b0000101, 3'b100}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_MINU;")
m("max va maxu doi ma thao tac", "{7'b0000101, 3'b110}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_MAX;",
  "{7'b0000101, 3'b110}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_MAXU;")
m("rol va ror doi ma thao tac", "{7'b0110000, 3'b001}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_ROL; end",
  "{7'b0110000, 3'b001}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_ROR; end")
m("zext.h khong kiem rs2 = 0", "zb_reg_ok = (ZBB != 0) & (rs2 == 5'd0); zb_op = Z_ZEXTH;", "zb_reg_ok = (ZBB != 0); zb_op = Z_ZEXTH;")
m("bclr va bset doi ma thao tac", "{7'b0100100, 3'b001}: begin zb_reg_ok = (ZBS != 0); zb_op = Z_BCLR; end",
  "{7'b0100100, 3'b001}: begin zb_reg_ok = (ZBS != 0); zb_op = Z_BSET; end")
m("bext thanh binv (dang thanh ghi)", "{7'b0100100, 3'b101}: begin zb_reg_ok = (ZBS != 0); zb_op = Z_BEXT; end",
  "{7'b0100100, 3'b101}: begin zb_reg_ok = (ZBS != 0); zb_op = Z_BINV; end")
m("clmulh va clmulr doi ma thao tac", "{7'b0000101, 3'b011}: begin zb_reg_ok = (ZBC != 0); zb_op = Z_CLMULH; end",
  "{7'b0000101, 3'b011}: begin zb_reg_ok = (ZBC != 0); zb_op = Z_CLMULR; end")
m("czero.eqz va czero.nez doi ma thao tac", "{7'b0000111, 3'b101}: begin zb_reg_ok = (ZICOND != 0); zb_op = Z_CZEQZ; end",
  "{7'b0000111, 3'b101}: begin zb_reg_ok = (ZICOND != 0); zb_op = Z_CZNEZ; end")
m("clz: bo kiem rs2 (rs2 = 3 cung chay clz)", "                        default: ;\n                    endcase\n                end\n                {7'b0110000, 3'b101}",
  "                        default: begin zb_imm_ok = (ZBB != 0); zb_op = Z_CLZ; end\n                    endcase\n                end\n                {7'b0110000, 3'b101}")
m("cpop va ctz doi ma", "5'd2:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_CPOP; end", "5'd2:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_CTZ; end")
m("sext.b va sext.h doi ma", "5'd4:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_SEXTB; end", "5'd4:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_SEXTH; end")
m("orc.b khong kiem rs2", "zb_imm_ok = (ZBB != 0) & (rs2 == 5'b00111); zb_op = Z_ORCB;", "zb_imm_ok = (ZBB != 0); zb_op = Z_ORCB;")
m("rev8 khong kiem rs2", "zb_imm_ok = (ZBB != 0) & (rs2 == 5'b11000); zb_op = Z_REV8;", "zb_imm_ok = (ZBB != 0); zb_op = Z_REV8;")
m("rori nhan ca shamt[5] = 1 (instr[25]) lam hop le", "{7'b0110000, 3'b101}: begin zb_imm_ok = (ZBB != 0); zb_op = Z_ROR; end",
  "{6'b011000, instr[25], 3'b101}: begin zb_imm_ok = (ZBB != 0); zb_op = Z_ROR; end")
m("bclri thanh bseti", "{7'b0100100, 3'b001}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BCLR; end", "{7'b0100100, 3'b001}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BSET; end")
m("bexti thanh bclri", "{7'b0100100, 3'b101}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BEXT; end", "{7'b0100100, 3'b101}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BCLR; end")
m("binvi sai funct7", "{7'b0110100, 3'b001}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BINV; end", "{7'b0110101, 3'b001}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BINV; end")
m("Zb khong lam rd ghi (legal_reg bo zb_reg_ok)", "funct3 == 3'b101))) | zb_reg_ok;", "funct3 == 3'b101)));")
m("Zb dang immediate khong hop le (legal_imm bo zb_imm_ok)", "(f7_zero | f7_alt) : 1'b1) | zb_imm_ok;", "(f7_zero | f7_alt) : 1'b1);")
m("ID/EX: ma thao tac Zb khong chuyen xuong EX", "idex_zop     <= zb_op;", "idex_zop     <= 5'd0;")
m("ID/EX: co Zb khong chuyen xuong EX", "idex_zb      <= id_zb;", "idex_zb      <= 1'b0;")
m("ID/EX: co Zb luon bat (moi lenh di qua zb_out)", "idex_zb      <= id_zb;", "idex_zb      <= 1'b1;")
m("EX: ket qua Zb khong duoc chon (idex_zb bi bo)", "idex_zb               ? zb_out          :\n", "")
# ---- gating phan mo rong (cau hinh gate: ZBB/ZBC/ZICOND dang tat) ----
m("gating: sh3add chay khi ZBA tat", "{7'b0010000, 3'b110}: begin zb_reg_ok = (ZBA != 0);", "{7'b0010000, 3'b110}: begin zb_reg_ok = 1'b1;", "gate1")
m("gating: min chay khi ZBB tat", "{7'b0000101, 3'b100}: begin zb_reg_ok = (ZBB != 0);", "{7'b0000101, 3'b100}: begin zb_reg_ok = 1'b1;", "gate2")
m("gating: andn chay khi ZBB tat", "{7'b0100000, 3'b111}: begin zb_reg_ok = (ZBB != 0);", "{7'b0100000, 3'b111}: begin zb_reg_ok = 1'b1;", "gate2")
m("gating: clz chay khi ZBB tat", "5'd0:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_CLZ; end", "5'd0:    begin zb_imm_ok = 1'b1; zb_op = Z_CLZ; end", "gate2")
m("gating: rev8 chay khi ZBB tat", "zb_imm_ok = (ZBB != 0) & (rs2 == 5'b11000);", "zb_imm_ok = (rs2 == 5'b11000);", "gate2")
m("gating: clmul chay khi ZBC tat", "{7'b0000101, 3'b001}: begin zb_reg_ok = (ZBC != 0);", "{7'b0000101, 3'b001}: begin zb_reg_ok = 1'b1;", "gate1")
m("gating: czero.eqz chay khi ZICOND tat", "{7'b0000111, 3'b101}: begin zb_reg_ok = (ZICOND != 0);", "{7'b0000111, 3'b101}: begin zb_reg_ok = 1'b1;", "gate1")
m("gating: bset chay khi ZBS tat", "{7'b0010100, 3'b001}: begin zb_reg_ok = (ZBS != 0);", "{7'b0010100, 3'b001}: begin zb_reg_ok = 1'b1;", "gate2")
m("gating: bseti (dang immediate) chay khi ZBS tat", "{7'b0010100, 3'b001}: begin zb_imm_ok = (ZBS != 0);", "{7'b0010100, 3'b001}: begin zb_imm_ok = 1'b1;", "gate2")
m("gating: clmulh chay khi ZBC tat", "{7'b0000101, 3'b011}: begin zb_reg_ok = (ZBC != 0);", "{7'b0000101, 3'b011}: begin zb_reg_ok = 1'b1;", "gate1")
m("gating: czero.nez chay khi ZICOND tat", "{7'b0000111, 3'b111}: begin zb_reg_ok = (ZICOND != 0);", "{7'b0000111, 3'b111}: begin zb_reg_ok = 1'b1;", "gate1")
m("gating: sh1add chay khi ZBA tat", "{7'b0010000, 3'b010}: begin zb_reg_ok = (ZBA != 0);", "{7'b0010000, 3'b010}: begin zb_reg_ok = 1'b1;", "gate1")
m("gating: cpop chay khi ZBB tat", "5'd2:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_CPOP; end", "5'd2:    begin zb_imm_ok = 1'b1; zb_op = Z_CPOP; end", "gate2")
m("gating: rori chay khi ZBB tat", "{7'b0110000, 3'b101}: begin zb_imm_ok = (ZBB != 0); zb_op = Z_ROR; end", "{7'b0110000, 3'b101}: begin zb_imm_ok = 1'b1; zb_op = Z_ROR; end", "gate2")
m("gating: bexti chay khi ZBS tat", "{7'b0100100, 3'b101}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BEXT; end", "{7'b0100100, 3'b101}: begin zb_imm_ok = 1'b1; zb_op = Z_BEXT; end", "gate2")
# ---- thuc thi (EX) ----
m("sh1add dich 2", "wire [31:0] z_sh1   = {zb_a[30:0], 1'b0} + zb_b;", "wire [31:0] z_sh1   = {zb_a[29:0], 2'b0} + zb_b;")
m("sh2add dich 3", "wire [31:0] z_sh2   = {zb_a[29:0], 2'b0} + zb_b;", "wire [31:0] z_sh2   = {zb_a[28:0], 3'b0} + zb_b;")
m("sh3add dich 2", "wire [31:0] z_sh3   = {zb_a[28:0], 3'b0} + zb_b;", "wire [31:0] z_sh3   = {zb_a[29:0], 2'b0} + zb_b;")
m("sh3add khong cong rs2", "wire [31:0] z_sh3   = {zb_a[28:0], 3'b0} + zb_b;", "wire [31:0] z_sh3   = {zb_a[28:0], 3'b0};")
m("andn: khong dao rs2", "(zb_a & ~zb_b)", "(zb_a & zb_b)")
m("orn: khong dao rs2", "(zb_a | ~zb_b)", "(zb_a | zb_b)")
m("xnor thanh xor", "~(zb_a ^ zb_b)", "(zb_a ^ zb_b)")
m("clz: x = 0 tra 31", "zb_clz32 = 6'd32; done = 1'b0;", "zb_clz32 = 6'd31; done = 1'b0;")
m("clz: dem lech 1", "zb_clz32 = 6'd31 - i[5:0]; done = 1'b1;", "zb_clz32 = 6'd30 - i[5:0]; done = 1'b1;")
m("ctz: dung clz cua so khong dao bit", "wire [5:0]  z_ctz_r = zb_clz32(zb_rev32(zb_a));", "wire [5:0]  z_ctz_r = zb_clz32(zb_a);")
m("cpop: bo bit 31", "for (i = 0; i < 32; i = i + 1) zb_pop32 = zb_pop32 + {5'd0, x[i]};", "for (i = 0; i < 31; i = i + 1) zb_pop32 = zb_pop32 + {5'd0, x[i]};")
m("sext.b: mo rong dau tu bit 6", "{{24{zb_a[7]}}, zb_a[7:0]}", "{{24{zb_a[6]}}, zb_a[7:0]}")
m("sext.h: mo rong khong", "{{16{zb_a[15]}}, zb_a[15:0]}", "{16'd0, zb_a[15:0]}")
m("zext.h: giu 17 bit", "{16'd0, zb_a[15:0]} : 32'd0;\n            Z_MAX:", "{15'd0, zb_a[16:0]} : 32'd0;\n            Z_MAX:")
m("max so sanh khong dau", "Z_MAX:    zb_out = (ZBB != 0) ? (z_lt  ? zb_b : zb_a)", "Z_MAX:    zb_out = (ZBB != 0) ? (z_ltu ? zb_b : zb_a)")
m("maxu so sanh co dau", "Z_MAXU:   zb_out = (ZBB != 0) ? (z_ltu ? zb_b : zb_a)", "Z_MAXU:   zb_out = (ZBB != 0) ? (z_lt  ? zb_b : zb_a)")
m("min lay lon", "Z_MIN:    zb_out = (ZBB != 0) ? (z_lt  ? zb_a : zb_b)", "Z_MIN:    zb_out = (ZBB != 0) ? (z_lt  ? zb_b : zb_a)")
m("minu so sanh co dau", "Z_MINU:   zb_out = (ZBB != 0) ? (z_ltu ? zb_a : zb_b)", "Z_MINU:   zb_out = (ZBB != 0) ? (z_lt  ? zb_a : zb_b)")
m("rol quay phai", "wire        z_rol   = (idex_zop == Z_ROL);", "wire        z_rol   = 1'b0;")
m("rol: so bit quay = shamt thay vi 32 - shamt (bo dao)", "wire [4:0]  z_ramt  = z_rol ? (5'd0 - zb_sh) : zb_sh;", "wire [4:0]  z_ramt  = zb_sh;")
m("ror: quay 4 bit thap cua shamt", "wire [63:0] z_rot   = {zb_a, zb_a} >> z_ramt;", "wire [63:0] z_rot   = {zb_a, zb_a} >> {1'b0, z_ramt[3:0]};")
m("orc.b: byte 1 lay or cua byte 0", "{8{|zb_a[23:16]}}, {8{|zb_a[15:8]}}, {8{|zb_a[7:0]}}}", "{8{|zb_a[23:16]}}, {8{|zb_a[7:0]}}, {8{|zb_a[7:0]}}}")
m("orc.b: dung bit 0 thay vi or ca byte", "{{8{|zb_a[31:24]}}, ", "{{8{zb_a[24]}}, ")
m("rev8: khong dao 2 byte giua", "{zb_a[7:0], zb_a[15:8], zb_a[23:16], zb_a[31:24]}", "{zb_a[7:0], zb_a[23:16], zb_a[15:8], zb_a[31:24]}")
m("bclr: xoa bit shamt+1", "Z_BCLR:   zb_out = (ZBS != 0) ? (zb_a & ~z_bit)", "Z_BCLR:   zb_out = (ZBS != 0) ? (zb_a & ~(z_bit << 1))")
m("bext: tra ca bit khong dich", "{31'd0, zb_a[zb_sh]}", "{31'd0, zb_a[zb_sh[3:0]]}")
m("binv thanh bset", "Z_BINV:   zb_out = (ZBS != 0) ? (zb_a ^ z_bit)", "Z_BINV:   zb_out = (ZBS != 0) ? (zb_a | z_bit)")
m("bset thanh binv", "Z_BSET:   zb_out = (ZBS != 0) ? (zb_a | z_bit)", "Z_BSET:   zb_out = (ZBS != 0) ? (zb_a ^ z_bit)")
m("shamt dang immediate lay 4 bit", "wire [4:0]  zb_sh = zb_b[4:0];", "wire [4:0]  zb_sh = {1'b0, zb_b[3:0]};")
m("toan hang 2 luon la thanh ghi (immediate bi bo)", "wire [31:0] zb_b = alu_b;", "wire [31:0] zb_b = op_b;")
m("toan hang 1 khong qua forwarding", "wire [31:0] zb_a = op_a;", "wire [31:0] zb_a = idex_rs1_val;")
m("clmul: dung OR thay XOR", "zb_clmul64 = zb_clmul64 ^ ({32'd0, x} << i);", "zb_clmul64 = zb_clmul64 | ({32'd0, x} << i);")
m("clmul: bo bit cao cua rs2", "for (i = 0; i < 32; i = i + 1)\n                if (y[i]) zb_clmul64", "for (i = 0; i < 31; i = i + 1)\n                if (y[i]) zb_clmul64")
m("clmulh lay nua thap", "Z_CLMULH: zb_out = z_clm[63:32];", "Z_CLMULH: zb_out = z_clm[31:0];")
m("clmulr lay lech 1 bit", "Z_CLMULR: zb_out = z_clm[62:31];", "Z_CLMULR: zb_out = z_clm[63:32];")
m("czero.eqz doi nghia (nez)", "Z_CZEQZ:  zb_out = (ZICOND != 0) ? ((zb_b == 32'd0) ? 32'd0 : zb_a)", "Z_CZEQZ:  zb_out = (ZICOND != 0) ? ((zb_b != 32'd0) ? 32'd0 : zb_a)")
m("czero.nez chi xet bit 0 cua rs2", "((zb_b != 32'd0) ? 32'd0 : zb_a) : 32'd0;\n            default", "((zb_b[0] != 1'b0) ? 32'd0 : zb_a) : 32'd0;\n            default")


def run(rep, cfg, n):
    zb = {"all": "all", "gate1": "zbb,zbs", "gate2": "zba,zbc,zicond"}[cfg]
    cmd = [sys.executable, os.path.join(rep, "verify", "run_verify.py"), "--pipem", "--zb", zb, "--zb-probe", "--stop-on-fail", "--n", str(n)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return True, "treo"
    out = r.stdout + r.stderr
    if "Bien dich RTL that bai" in out or "Traceback" in out:
        return None, out.strip()[-300:]
    first = next((l for l in out.splitlines() if l.strip()), "")
    return bool(r.returncode), first


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--jobs", type=int, default=1)
    a = ap.parse_args()
    src = open(os.path.join(ROOT, F)).read()
    muts = [x for x in M if a.only.lower() in x[0].lower()]
    killed, bad = 0, 0
    for name, old, new, cfg in muts:
        if src.count(old) != 1:
            print(f"  BO QUA  {name}: chuoi goc xuat hien {src.count(old)} lan (can dung 1)", flush=True)
            bad += 1
            continue
        tmp = tempfile.mkdtemp(prefix="mutzb_")
        try:
            rep = os.path.join(tmp, "repo")
            shutil.copytree(ROOT, rep, ignore=shutil.ignore_patterns(".git", "eembc", "__pycache__", "*.vvp"))
            open(os.path.join(rep, F), "w").write(src.replace(old, new, 1))
            killed_, detail = run(rep, cfg, a.n)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        if killed_ is None:
            print(f"  LOI BIEN DICH  {name}: {detail}", flush=True)
            bad += 1
        elif killed_:
            killed += 1
            print(f"  BAT DUOC  [{cfg}] {name}", flush=True)
        else:
            bad += 1
            print(f"  BO SOT    [{cfg}] {name}", flush=True)
    print(f"Zb mutation: bat duoc {killed}/{len(muts)}" + (f", {bad} bo sot / loi" if bad else ""))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
