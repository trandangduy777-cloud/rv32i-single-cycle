#!/usr/bin/env python3
"""Mutation test cho chuong trinh ngau nhien (cosim/run_random.py): moi dot bien RTL phai bi so vet voi Spike bat duoc trong N
chuong trinh ngau nhien tren cac loi chi dinh. Dot bien chay tren ban sao cua cac file .v (bien moi truong RV_ROOT).
Dung: python3 cosim/mutate_random.py [--n 60] [--jobs 2]"""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (ten, file, chuoi goc, chuoi thay the, cac chi so loi (run_random --list))
M = [
    ("DOI CHUNG: khong dot bien (phai THOAT)", "rv32im_pipeline.v", "module rv32im_pipeline", "module rv32im_pipeline", [3, 0]),
    ("bypass WB -> EX bo di (toan hang A)", "rv32im_pipeline.v",
     "(idex_fa_wb ? memwb_val : idex_rs1_val)", "idex_rs1_val", [3]),
    ("bypass MEM -> EX bo di (toan hang B)", "rv32im_pipeline.v",
     "idex_fb_mem ? exmem_result : (idex_fb_wb", "1'b0 ? exmem_result : (idex_fb_wb", [3]),
    ("load nua tu lech khong trap", "rv32im_pipeline.v",
     "(((idex_funct3[1:0] == 2'b01) & ea_lo[0]) | ((idex_funct3[1:0] == 2'b10) & (ea_lo != 2'b00)));\n    wire st_misal",
     "(((idex_funct3[1:0] == 2'b01) & 1'b0) | ((idex_funct3[1:0] == 2'b10) & (ea_lo != 2'b00)));\n    wire st_misal", [3]),
    ("doan nhanh sai chi tinh khi khong nhay", "rv32im_pipeline.v",
     "idex_branch & (take_branch ^ idex_pred_taken)", "idex_branch & (take_branch & ~idex_pred_taken)", [3]),
    ("JALR: chi so 30 bit cao cua dich du doan", "rv32im_pipeline.v",
     "idex_jp_v & (idex_jp_t == jalr_target)", "idex_jp_v & (idex_jp_t[31:2] == jalr_target[31:2])", [3]),
    ("ECALL: mcause = 10", "rv32im_pipeline.v", "trap_cause = {28'd0, 2'b10, priv}; trap_tval = 32'd0;", "trap_cause = 32'd10; trap_tval = 32'd0;", [3]),
    ("mscratch mat bit 0", "rv32im_pipeline.v", "12'h340: mscratch <= csr_new;", "12'h340: mscratch <= csr_new & 32'hFFFF_FFFE;", [3]),
    ("mepc mat bit 1 (IALIGN = 16)", "rv32im_pipeline.v", "12'h341: mepc_r   <= csr_new[31:1];", "12'h341: mepc_r   <= {csr_new[31:2], 1'b0};", [3]),
    ("mstatus.MPIE lay bit 3", "rv32im_pipeline.v", "mstatus_mie <= csr_new[3]; mstatus_mpie <= csr_new[7];", "mstatus_mie <= csr_new[3]; mstatus_mpie <= csr_new[3];", [3]),
    ("ghi CSR chi doc khong trap", "rv32im_pipeline.v", "~(id_csr_we_req & id_csr_ro)", "1'b1", [3]),
    ("single-cycle: SLTU so co dau", "rv32i_core.v", "3'b011: alu_out = (alu_a < alu_b) ? 32'd1 : 32'd0;",
     "3'b011: alu_out = ($signed(alu_a) < $signed(alu_b)) ? 32'd1 : 32'd0;", [0]),
    ("single-cycle: SUB thanh ADD voi immediate", "rv32i_core.v", "wire do_sub = is_reg & funct7_5;", "wire do_sub = funct7_5;", [0]),
    ("Zba: sh1add dung XOR thay cho cong", "rv32im_pipeline.v", "wire [31:0] z_sh1   = {zb_a[30:0], 1'b0} + zb_b;",
     "wire [31:0] z_sh1   = {zb_a[30:0], 1'b0} ^ zb_b;", [13]),
    ("Zbc: clmul cong thay cho XOR", "rv32im_pipeline.v", "zb_clmul64 = zb_clmul64 ^ ({32'd0, x} << i);",
     "zb_clmul64 = zb_clmul64 + ({32'd0, x} << i);", [13]),
    ("Zbs: bexti giai ma thanh binvi", "rv32im_pipeline.v", "zb_op = Z_BEXT; end                // bexti",
     "zb_op = Z_BINV; end                // bexti", [13]),
    ("giai nen: c.addi16sp nzimm = 0 hop le", "rv32c_decompress.v", "if (nzimm_16sp == 10'd0) illegal = 1'b1;", "if (1'b0) illegal = 1'b1;", [3]),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=60, help="so chuong trinh moi loi toi da")
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--seed0", type=int, default=90000)
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    a = ap.parse_args()
    caught = 0
    for name, fn, old, new, idx in M:
        tmp = tempfile.mkdtemp(prefix="mutr_")
        for f in os.listdir(ROOT):
            if f.endswith(".v"):
                shutil.copy(os.path.join(ROOT, f), tmp)
        txt = open(os.path.join(tmp, fn)).read()
        if txt.count(old) < 1:
            print(f"KHONG TIM THAY chuoi goc: {name}")
            sys.exit(2)
        open(os.path.join(tmp, fn), "w").write(txt.replace(old, new, 1))
        env = dict(os.environ, RV_ROOT=tmp)
        r = subprocess.run([sys.executable, os.path.join(HERE, "run_random.py"), "--n", str(a.n), "--seed0", str(a.seed0),
                            "--jobs", str(a.jobs), "--spike", a.spike, "--idx"] + [str(i) for i in idx] + ["--stop-on-fail", "--fail-dir", os.path.join(tmp, "f")],
                           capture_output=True, text=True, env=env)
        if "FAIL loi" not in r.stdout and r.returncode not in (0,):
            print("loi cong cu / dich:", (r.stdout + r.stderr)[-400:])
            sys.exit(2)
        got = "FAIL loi" in r.stdout
        line = [l for l in r.stdout.splitlines() if l.startswith("TONG")]
        first = [l for l in r.stdout.splitlines() if "FAIL loi" in l]
        print(f"{'BAT DUOC ' if got else 'THOAT    '} {name}  | {line[0] if line else r.stdout[-200:]}", flush=True)
        caught += got
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"DOT BIEN: bat duoc {caught}/{len(M) - 1} (khong tinh dong doi chung)")
    sys.exit(0 if caught == len(M) - 1 else 1)


if __name__ == "__main__":
    main()
