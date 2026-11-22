#!/usr/bin/env python3
"""Mutation test cho mo rong C: moi dot bien phai bi bo kiem chung tuong ung bat duoc.

- Dot bien trong pipeline (rv32im_pipeline.v, phan ENABLE_C): chay cosim/run_cosim.py tren loi pipeline RV32IMC voi
  cac chuong trinh bien dich co C (riscv-tests rv32ui/um/uc, bench, bench_m). Phai co it nhat 1 chuong trinh lech Spike.
- Dot bien trong bo giai nen (rv32c_decompress.v): chay rvc/check_decompress.py. Phai co it nhat 1 ma lenh lech objdump.

Moi dot bien chay tren mot ban sao cua repo trong thu muc tam, repo goc khong bi sua.
Dung (tu thu muc goc repo): python3 rvc/mutate_rvc.py <thu_muc_riscv-tests> [--spike <duong dan spike>]
"""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (ten, file, chuoi goc, chuoi thay the, bo kiem chung: "cosim" hoac "decomp")
MUTATIONS = [
    ("dia chi lien ket JAL/JALR luon pc+4", "rv32im_pipeline.v",
     "wire [31:0] pc_next     = idex_pc + (idex_c ? 32'd2 : 32'd4);",
     "wire [31:0] pc_next     = idex_pc + 32'd4;", "cosim"),
    ("doan sai nhanh nen: chay tiep o pc+4", "rv32im_pipeline.v",
     "idex_jalr ? jalr_target : (idex_pred_taken ? pc_next : pc_imm);",
     "idex_jalr ? jalr_target : (idex_pred_taken ? idex_pc + 32'd4 : pc_imm);", "cosim"),
    ("IF luon tang pc 4", "rv32im_pipeline.v",
     "if_pred ? if_ptgt : pc + (if_c ? 32'd2 : 32'd4);", "if_pred ? if_ptgt : pc + 32'd4;", "cosim"),
    ("van bao lech dia chi lenh khi co C", "rv32im_pipeline.v",
     "wire misaligned = (ENABLE_C == 0) & (", "wire misaligned = 1'b1 & (", "cosim"),
    ("lenh goc 16 bit khong duoc giu (mtval, vet)", "rv32im_pipeline.v",
     "ifid_raw   <= if_c ? {16'd0, imem_data[15:0]} : imem_data;", "ifid_raw   <= imem_data;", "cosim"),
    ("nhan dang lenh nen sai (chi xet bit 0)", "rv32im_pipeline.v",
     "wire        if_c = (ENABLE_C != 0) && (imem_data[1:0] != 2'b11);",
     "wire        if_c = (ENABLE_C != 0) && (imem_data[0] != 1'b1);", "cosim"),
    ("c.j / c.jal: dao bit imm[7] va imm[6]", "rv32c_decompress.v",
     "c[10:9], c[6], c[7], c[2]", "c[10:9], c[7], c[6], c[2]", "decomp"),
    ("c.beqz / c.bnez: dao bit imm[4] va imm[3]", "rv32c_decompress.v",
     "c[11:10], c[4:3], 1'b0};     // c.beqz", "c[11:10], c[3], c[4], 1'b0};     // c.beqz", "decomp"),
    ("c.addi4spn: dao bit nzuimm[3] va nzuimm[2]", "rv32c_decompress.v",
     "c[12:11], c[5], c[6], 2'b00};", "c[12:11], c[6], c[5], 2'b00};", "decomp"),
    ("c.addi16sp: sai vi tri bit nzimm[5]", "rv32c_decompress.v",
     "{c[12], c[4:3], c[5], c[2], c[6], 4'b0000}", "{c[12], c[4:3], c[2], c[5], c[6], 4'b0000}", "decomp"),
    ("c.lwsp: thieu uimm[7:6]", "rv32c_decompress.v",
     "wire [7:0]  uimm_lwsp   = {c[3:2], c[12], c[6:4], 2'b00};",
     "wire [7:0]  uimm_lwsp   = {2'b00, c[12], c[6:4], 2'b00};", "decomp"),
    ("c.srai giai nen thanh srli", "rv32c_decompress.v",
     "out = enc_i({1'b0, c[10], 5'b00000, c[6:2]}, rs1p, 3'b101, rs1p, OP_IMM);",
     "out = enc_i({7'b0000000, c[6:2]}, rs1p, 3'b101, rs1p, OP_IMM);", "decomp"),
    ("c.sub giai nen thanh add", "rv32c_decompress.v",
     "enc_r(7'b0100000, rdp, rs1p, 3'b000, rs1p);   // c.sub",
     "enc_r(7'b0000000, rdp, rs1p, 3'b000, rs1p);   // c.sub", "decomp"),
    ("c.jalr khong ghi ra (x1)", "rv32c_decompress.v",
     "else out = enc_i(12'd0, rd, 3'b000, 5'd1, JALR);         // c.jalr",
     "else out = enc_i(12'd0, rd, 3'b000, 5'd0, JALR);         // c.jalr", "decomp"),
    ("c.lui voi nzimm = 0 khong bi bao illegal", "rv32c_decompress.v",
     "if (imm6 == 6'd0) illegal = 1'b1;\n                        else out = {{14{imm6[5]}}, imm6, rd, LUI};",
     "out = {{14{imm6[5]}}, imm6, rd, LUI};", "decomp"),
    ("c.srli voi shamt[5] = 1 khong bi bao illegal", "rv32c_decompress.v",
     "if (c[12]) illegal = 1'b1;                                   // shamt[5] = 1: chi RV64\n"
     "                        else out",
     "if (1'b0) illegal = 1'b1;                                   // shamt[5] = 1: chi RV64\n"
     "                        else out", "decomp"),
    ("c.fsw (so thuc) khong bi bao illegal", "rv32c_decompress.v",
     "3'b110: out = enc_s({5'd0, uimm_lw}, rdp, rs1p, 3'b010);         // c.sw\n                default: illegal = 1'b1;",
     "3'b110: out = enc_s({5'd0, uimm_lw}, rdp, rs1p, 3'b010);         // c.sw\n"
     "                3'b111: out = enc_s({5'd0, uimm_lw}, rdp, rs1p, 3'b010);\n                default: illegal = 1'b1;",
     "decomp"),
]


def copy_repo(dst):
    shutil.copytree(ROOT, dst, ignore=shutil.ignore_patterns(".git", "results", "*.vcd", "*.vvp"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("riscv_tests")
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    a = ap.parse_args()

    killed, skipped = 0, 0
    for name, fn, old, new, how in MUTATIONS:
        src = open(os.path.join(ROOT, fn)).read()
        if src.count(old) != 1:
            print(f"  BO QUA  {name}: khong tim thay chuoi goc trong {fn}")
            skipped += 1
            continue
        tmp = tempfile.mkdtemp(prefix="mutrvc_")
        rep = os.path.join(tmp, "repo")
        copy_repo(rep)
        open(os.path.join(rep, fn), "w").write(src.replace(old, new))
        if how == "cosim":
            cmd = [sys.executable, os.path.join(rep, "cosim", "run_cosim.py"), a.riscv_tests, "--spike", a.spike,
                   "--only=-c", "--core=RV32IMC", "--stop-on-fail"]
        else:
            cmd = [sys.executable, os.path.join(rep, "rvc", "check_decompress.py")]
        r = subprocess.run(cmd, capture_output=True, text=True)
        out = r.stdout + r.stderr
        # bi bat: bo kiem chung bao loi that (khong tinh loi bien dich hay loi script)
        if how == "cosim":
            caught = r.returncode != 0 and "FAIL " in out
        else:
            caught = r.returncode != 0 and "Traceback" not in out and ", 0 lech" not in out
        killed += caught
        detail = next((l.strip() for l in out.splitlines() if l.startswith("FAIL") or "ma lenh 16 bit" in l),
                      out.strip()[-120:])
        print(f"  {'BAT' if caught else 'SOT'}  [{how}] {name}: {detail[:140]}", flush=True)
        shutil.rmtree(tmp, ignore_errors=True)
    total = len(MUTATIONS) - skipped
    print(f"bat duoc {killed}/{total} dot bien" + (f", bo qua {skipped}" if skipped else ""))
    sys.exit(0 if killed == total and not skipped else 1)


if __name__ == "__main__":
    main()
