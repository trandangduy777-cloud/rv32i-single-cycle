#!/usr/bin/env python3
"""So sanh RTL voi mo hinh tham chieu tren nhieu chuong trinh ngau nhien.

Cach dung:
  python3 run_verify.py                      # 200 chuong trinh, moi chuong trinh 300 don vi
  python3 run_verify.py --n 500 --len 400    # nhieu hon
  python3 run_verify.py --rtl ../rv32i_core.v
  python3 run_verify.py --mutate             # kiem tra bo kiem chung co bat duoc loi chen co y khong
"""
import argparse
import os
import subprocess
import sys
import tempfile
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rv32i_iss import ISS, load_hex                       # noqa: E402
from gen_prog import Gen, write_hex                       # noqa: E402

ALL_INSTR = ["lui", "auipc", "jal", "jalr", "beq", "bne", "blt", "bge", "bltu", "bgeu",
             "lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw",
             "addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai",
             "add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
             "fence", "ecall", "ebreak", "mret",
             "csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci",
             "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
# truong hop bien cua phep chia: chia cho 0 va tran so INT_MIN / -1
ALL_EDGE = ["div0", "divovf"]
# RV32I thuan + FENCE (pipeline chua co CSR, trap, M)
ALL_INSTR_BASE = [x for x in ALL_INSTR if not (x.startswith("csr") or x in
                  ("ecall", "ebreak", "mret", "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"))]
# nguyen nhan trap can phu: 0 = nhay khong can chinh, 2 = lenh bat hop le, 3 = EBREAK, 11 = ECALL
ALL_TRAPS = ["trap:0", "trap:2", "trap:3", "trap:4", "trap:6", "trap:11"]


def compile_rtl(rtl, out_vvp, tb="tb_trace.v", full_pipe=False):
    cmd = ["iverilog", "-g2012", "-o", out_vvp, rtl, os.path.join(HERE, tb)]
    if full_pipe:                       # rv32im_pipeline can module rv32m trong rv32i_core.v
        cmd[2:2] = ["-DPIPE_FULL"]
        cmd.append(os.environ.get("RV32_CORE") or os.path.join(HERE, "..", "rv32i_core.v"))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr)
        sys.exit("Bien dich RTL that bai")


def run_rtl(vvp, prog, dmem=None):
    cmd = ["vvp", vvp, f"+prog={prog}"] + ([f"+dmem={dmem}"] if dmem else [])
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    lines = [l for l in r.stdout.splitlines() if l.startswith("pc=")]
    timeout = "TIMEOUT" in r.stdout
    return lines, timeout


def compare(rtl_lines, iss_lines):
    """Tra ve None neu khop, nguoc lai (chi so, dong RTL, dong ISS)."""
    for i in range(max(len(rtl_lines), len(iss_lines))):
        a = rtl_lines[i] if i < len(rtl_lines) else "<het vet RTL>"
        b = iss_lines[i] if i < len(iss_lines) else "<het vet ISS>"
        if a != b:
            return i, a, b
    return None


def check_one(vvp, prog_words, dmem_words, tmp, tag):
    p = os.path.join(tmp, f"{tag}.prog.hex")
    d = os.path.join(tmp, f"{tag}.dmem.hex")
    write_hex(p, prog_words + [0x13] * (1024 - len(prog_words)))
    write_hex(d, dmem_words)
    rtl_lines, timeout = run_rtl(vvp, p, d)
    iss = ISS(prog_words, dmem_words)
    iss_lines, halted = iss.run()
    if timeout or not halted:
        return ("TIMEOUT", None), iss.coverage
    diff = compare(rtl_lines, iss_lines)
    return (("FAIL", diff) if diff else ("PASS", None)), iss.coverage


def run_suite(rtl, n, length, seed0, tmp, verbose=True, pipe=False, full_pipe=False):
    vvp = os.path.join(tmp, "sim.vvp")
    compile_rtl(rtl, vvp, "tb_trace_pipe.v" if pipe else "tb_trace.v", full_pipe)
    profile = "base" if (pipe and not full_pipe) else "full"
    cov, fails, instr_total = {}, [], 0
    # chuong trinh dinh huong co san (pipeline chi chay ban RV32I thuan)
    directed = load_hex(os.path.join(HERE, "..", "prog_base.hex" if (pipe and not full_pipe) else "prog.hex"))
    res, c = check_one(vvp, directed, [0] * 1024, tmp, "directed")
    for k, v in c.items():
        cov[k] = cov.get(k, 0) + v
    if res[0] != "PASS":
        fails.append(("directed", res))
    # chuong trinh ngau nhien
    for s in range(seed0, seed0 + n):
        words, dmem = Gen(s, length, profile).build()
        res, c = check_one(vvp, words, dmem, tmp, f"s{s}")
        for k, v in c.items():
            cov[k] = cov.get(k, 0) + v
        instr_total += len(words)
        if res[0] != "PASS":
            fails.append((f"seed {s}", res))
    return cov, fails


def report(cov, fails, n, pipe=False):
    # pipe=True: pipeline RV32I thuan. pipeline day du (--pipem) bao cao nhu single-cycle (pipe=False)
    print(f"Chuong trinh: {n} ngau nhien + 1 dinh huong, that bai: {len(fails)}")
    for name, (status, diff) in fails[:3]:
        print(f"  [{name}] {status}")
        if diff:
            i, a, b = diff
            print(f"    lenh thu {i}\n    RTL: {a}\n    ISS: {b}")
    missing = [x for x in (ALL_INSTR_BASE if pipe else ALL_INSTR) if cov.get(x, 0) == 0]
    tot = len(ALL_INSTR_BASE if pipe else ALL_INSTR)
    print("Phu lenh: %d/%d" % (tot - len(missing), tot),
          ("| chua phu: " + ", ".join(missing)) if missing else "| du lenh")
    if not pipe:
        print("Phu truong hop bien chia:", ", ".join(f"{k}={cov.get(k, 0)}" for k in ALL_EDGE),
              "| du" if all(cov.get(k, 0) for k in ALL_EDGE) else "| THIEU")
        miss_t = [x for x in ALL_TRAPS if cov.get(x, 0) == 0]
        print("Phu trap:", ", ".join(f"{k}={cov.get(k, 0)}" for k in ALL_TRAPS),
              ("| chua phu: " + ", ".join(miss_t)) if miss_t else "| du 6 loai trap")
    low = sorted((v, k) for k, v in cov.items() if k in (ALL_INSTR_BASE if pipe else ALL_INSTR))[:5]
    print("Lenh it xuat hien nhat:", ", ".join(f"{k}={v}" for v, k in low))


MUTATIONS = [
    ("SRA bi dich logic", "3'b101: alu_out = do_sra ? sra_out : srl_out;",
     "3'b101: alu_out = srl_out;"),
    ("LB khong mo rong dau", "3'b000:  ld_data = {{24{ld_byte[7]}},  ld_byte};",
     "3'b000:  ld_data = {24'b0, ld_byte};"),
    ("BLTU so sanh co dau", "3'b110:  take_branch = ltu;", "3'b110:  take_branch = lt;"),
    ("SLTU so sanh co dau", "3'b011: alu_out = (alu_a < alu_b) ? 32'd1 : 32'd0;",
     "3'b011: alu_out = ($signed(alu_a) < $signed(alu_b)) ? 32'd1 : 32'd0;"),
    ("JALR khong xoa bit 0", "& 32'hFFFF_FFFE;", ";"),
    ("SH sai byte-enable", "byte_off[1] ? 4'b1100 : 4'b0011", "byte_off[1] ? 4'b0011 : 4'b1100"),
    ("AUIPC cong pc+4", "rd_val = pc + imm_u;", "rd_val = pc_plus4 + imm_u;"),
    ("SUB thanh ADD o OP_REG", "wire do_sub = is_reg & funct7_5;", "wire do_sub = 1'b0;"),
    ("BGE thanh BGEU", "3'b101:  take_branch = ~lt;", "3'b101:  take_branch = ~ltu;"),
    ("ECALL sai ma nguyen nhan", "trap_cause = 32'd11;", "trap_cause = 32'd8;"),
    ("mepc luu pc+4", "mepc_r       <= pc[31:2];", "mepc_r       <= pc_plus4[31:2];"),
    ("mtval cua lenh bat hop le = 0", "trap_cause = 32'd2;  trap_tval = instr;", "trap_cause = 32'd2;  trap_tval = 32'd0;"),
    ("EBREAK mtval = 0", "trap_cause = 32'd3;  trap_tval = pc;", "trap_cause = 32'd3;  trap_tval = 32'd0;"),
    ("CSRRC thanh OR", "default: csr_new = csr_rdata & ~csr_src;", "default: csr_new = csr_rdata | csr_src;"),
    ("CSRRS/RC rs1=x0 van coi la ghi", "wire        csr_we_req = (funct3[1:0] == 2'b01) | (rs1 != 5'd0);",
     "wire        csr_we_req = 1'b1;"),
    ("ghi CSR chi doc khong trap", "wire        csr_ro     = (csr_addr[11:10] == 2'b11);", "wire        csr_ro     = 1'b0;"),
    ("trap khong xoa MIE", "mstatus_mpie <= mstatus_mie;\n                mstatus_mie  <= 1'b0;",
     "mstatus_mpie <= mstatus_mie;"),
    ("MRET khong dat MPIE=1", "mstatus_mpie <= 1'b1;", "mstatus_mpie <= 1'b0;"),
    ("nhanh nhay khong can chinh khong trap", "(legal_branch & take_branch & branch_target[1]);", "1'b0;"),
    ("JALR nhay khong can chinh khong trap", "(legal_jalr & jalr_target[1]) |", "1'b0 |"),
    ("lenh trap van ghi thanh ghi dich",
     "wire        rd_we = (is_lui | is_auipc | is_jal | is_jalr | is_load | is_imm | is_reg | is_csr) & ~trap & ~stall;",
     "wire        rd_we = (is_lui | is_auipc | is_jal | is_jalr | is_load | is_imm | is_reg | is_csr) & ~stall;"),
    ("OP_REG khong kiem tra funct7", "wire legal_reg    = is_reg & (f7_zero | f7_m | (f7_alt & (funct3 == 3'b000 | funct3 == 3'b101)));",
     "wire legal_reg    = is_reg;"),
    ("SLLI khong kiem tra funct7", "wire legal_imm    = is_imm & ((funct3 == 3'b001) ? f7_zero :",
     "wire legal_imm    = is_imm & ((funct3 == 3'b001) ? 1'b1 :"),
    ("FENCE.I bi coi la bat hop le", "wire legal_fence  = is_fence & (funct3 == 3'b000 | funct3 == 3'b001);",
     "wire legal_fence  = is_fence & (funct3 == 3'b000);"),
    ("ghi mepc bang CSR bi sai", "12'h341: mepc_r   <= csr_new[31:2];", "12'h341: mepc_r   <= pc[31:2];"),
    ("ghi mscratch bi bo qua", "12'h340: mscratch <= csr_new;", "12'h340: mscratch <= mscratch;"),
    ("M: MULH khong dao dau tich", "neg_res <= sa ^ sb;", "neg_res <= 1'b0;"),
    ("M: REM lay dau cua so chia", "neg_rem <= sa;", "neg_rem <= sb;"),
    ("M: chia cho 0 van dao dau thuong", "neg_res <= (sa ^ sb) & (b != 32'd0);", "neg_res <= (sa ^ sb);"),
    ("M: MULHSU coi so thu hai co dau",
     "wire sb = (funct3 == 3'b001 | funct3 == 3'b100 | funct3 == 3'b110) & b[31];",
     "wire sb = (funct3 == 3'b001 | funct3 == 3'b010 | funct3 == 3'b100 | funct3 == 3'b110) & b[31];"),
    ("M: MULHU coi so thu nhat co dau",
     "wire sa = (funct3 == 3'b001 | funct3 == 3'b010 | funct3 == 3'b100 | funct3 == 3'b110) & a[31];",
     "wire sa = (funct3 == 3'b001 | funct3 == 3'b010 | funct3 == 3'b011 | funct3 == 3'b100 | funct3 == 3'b110) & a[31];"),
    ("M: so sanh chia dung > thay vi >=", "wire        div_ge   = (div_rem >= {1'b0, m});", "wire        div_ge   = (div_rem > {1'b0, m});"),
    ("M: chi lap 31 chu ky", "if (cnt == 5'd31) state <= FIN;", "if (cnt == 5'd30) state <= FIN;"),
    ("M: DIV khong dao dau thuong", "3'b100:  result = neg_res ? (~p[31:0] + 32'd1) : p[31:0];    // DIV",
     "3'b100:  result = p[31:0];"),
    ("M: REMU tra ve thuong", "default: result = p[63:32];                                  // REMU",
     "default: result = p[31:0];"),
    ("M: stall khong giu pc", "assign pc_next = stall                        ? pc               :",
     "assign pc_next = 1'b0                          ? pc               :"),
    ("M: coi funct7=1 la bat hop le", "wire legal_reg    = is_reg & (f7_zero | f7_m | (f7_alt", "wire legal_reg    = is_reg & (f7_zero | (f7_alt"),
    ("T: LH/SH lech khong trap", "wire ld_misal = legal_load  & (((funct3[1:0] == 2'b01) & mem_addr[0]) |",
     "wire ld_misal = legal_load  & (((funct3[1:0] == 2'b01) & 1'b0) |"),
    ("T: LW chi kiem tra bit 0", "((funct3[1:0] == 2'b10) & (mem_addr[1:0] != 2'b00)));\n    wire st_misal",
     "((funct3[1:0] == 2'b10) & (mem_addr[0])));\n    wire st_misal"),
    ("T: store lech van ghi bo nho", "assign dmem_we = is_store & ~trap;", "assign dmem_we = is_store & ~(trap & ~st_misal);"),
    ("T: store lech sai cause (4)", "else if (st_misal) begin trap_cause = 32'd6;", "else if (st_misal) begin trap_cause = 32'd4;"),
    ("T: load lech mtval = 0", "else if (ld_misal) begin trap_cause = 32'd4;  trap_tval = mem_addr;",
     "else if (ld_misal) begin trap_cause = 32'd4;  trap_tval = 32'd0;"),
]



PIPE_MUTATIONS = [
    ("P: khong forward A tu EX/MEM", "assign id_fa_mem = idex_valid  & idex_rd_we  & (idex_rd  != 5'd0) & (idex_rd  == rs1);",
     "assign id_fa_mem = 1'b0;"),
    ("P: khong forward B tu EX/MEM", "assign id_fb_mem = idex_valid  & idex_rd_we  & (idex_rd  != 5'd0) & (idex_rd  == rs2);",
     "assign id_fb_mem = 1'b0;"),
    ("P: khong forward A tu MEM/WB", "assign id_fa_wb  = exmem_valid & exmem_rd_we & (exmem_rd != 5'd0) & (exmem_rd == rs1);",
     "assign id_fa_wb  = 1'b0;"),
    ("P: khong forward B tu MEM/WB", "assign id_fb_wb  = exmem_valid & exmem_rd_we & (exmem_rd != 5'd0) & (exmem_rd == rs2);",
     "assign id_fb_wb  = 1'b0;"),
    ("P: forward uu tien lenh cu (A)", "wire [31:0] op_a = idex_fa_mem ? exmem_result : (idex_fa_wb ? memwb_val : idex_rs1_val);",
     "wire [31:0] op_a = idex_fa_wb ? memwb_val : (idex_fa_mem ? exmem_result : idex_rs1_val);"),
    ("P: forward ca khi rd = x0", "assign id_fb_mem = idex_valid  & idex_rd_we  & (idex_rd  != 5'd0) & (idex_rd  == rs2);",
     "assign id_fb_mem = idex_valid  & idex_rd_we  & (idex_rd  == rs2);"),
    ("P: khong stall load-use", "assign stall = ifid_valid & idex_valid & idex_load", "assign stall = 1'b0 & ifid_valid & idex_valid & idex_load"),
    ("P: load-use bo qua rs2", "((uses_rs1 & (idex_rd == rs1)) | (uses_rs2 & (idex_rd == rs2)));",
     "((uses_rs1 & (idex_rd == rs1)));"),
    ("P: khong bypass WB->ID (rs1)", "(wb_we && memwb_rd == rs1) ? memwb_val : regs[rs1];", "regs[rs1];"),
    ("P: khong bypass WB->ID (rs2)", "(wb_we && memwb_rd == rs2) ? memwb_val : regs[rs2];", "regs[rs2];"),
    ("P: khong huy lenh o ID sau khi nhay", "wire id_bubble = redirect | stall;", "wire id_bubble = stall;"),
    ("P: khong huy lenh o IF sau khi nhay", "ifid_valid <= 1'b0;                // huy lenh vua doc nham duong",
     "ifid_valid <= 1'b1;"),
    ("P: du lieu store khong duoc forward", "exmem_store_val <= op_b;", "exmem_store_val <= idex_rs2_val;"),
    ("P: JALR dung rs1 chua forward", "wire [31:0] jalr_target = (op_a + idex_imm)", "wire [31:0] jalr_target = (idex_rs1_val + idex_imm)"),
    ("P: so sanh nhanh dung rs2 chua forward", "wire eq  = (op_a == op_b);", "wire eq  = (op_a == idex_rs2_val);"),
    ("P: dia chi load/store dung rs1 chua forward", "(idex_load | idex_store) ? (op_a + idex_imm)", "(idex_load | idex_store) ? (idex_rs1_val + idex_imm)"),
    ("P: SRA dich logic", "3'b101: alu_out = do_sra ? sra_out : srl_out;", "3'b101: alu_out = srl_out;"),
    ("P: LB khong mo rong dau", "3'b000:  ld_data = {{24{ld_byte[7]}},  ld_byte};", "3'b000:  ld_data = {24'b0, ld_byte};"),
    ("P: AUIPC cong pc+4", "idex_auipc            ? pc_imm          :", "idex_auipc            ? idex_pc + 32'd4 + idex_imm :"),
    ("P: SH sai byte-enable", "byte_off[1] ? 4'b1100 : 4'b0011", "byte_off[1] ? 4'b0011 : 4'b1100"),
    # --- du doan nhanh ---
    ("B: doan sai nhay ve dich nham", "(idex_pred_taken ? idex_pc + 32'd4 : pc_imm)", "(idex_pred_taken ? pc_imm : idex_pc + 32'd4)"),
    ("B: bo sot doan 'nhay' nhung thuc te khong nhay", "wire mispredict    = idex_branch & (take_branch ^ idex_pred_taken);", "wire mispredict    = idex_branch & take_branch & ~idex_pred_taken;"),
    ("B: bo sot doan 'khong nhay' nhung thuc te nhay", "wire mispredict    = idex_branch & (take_branch ^ idex_pred_taken);", "wire mispredict    = idex_branch & ~take_branch & idex_pred_taken;"),
    ("B: ID nhay som khi dang stall load-use", "assign id_redirect = ifid_valid & ~stall & (is_jal | id_pred_taken);", "assign id_redirect = ifid_valid & (is_jal | id_pred_taken);"),
    ("B: ID nhay som thang redirect cua EX", "end else if (redirect) begin\n            pc         <= redirect_pc;", "end else if (redirect & ~id_redirect) begin\n            pc         <= redirect_pc;"),
    ("B: JAL khong nhay o ID", "(is_jal | id_pred_taken);", "(id_pred_taken);"),
    ("B: dich nhay som la pc+4", "assign id_target   = ifid_pc + imm;", "assign id_target   = ifid_pc + 32'd4;"),
    ("B: du doan khong chuyen xuong EX", "idex_pred_taken <= id_pred_taken;", "idex_pred_taken <= 1'b0;"),
]


# Loi chen vao module rv32m (nam trong rv32i_core.v) o che do PREP = 1 cua pipeline. Ten bat dau bang "M:".
M_CORE_MUTATIONS = [
    ("M: PREP, REM khong dao dau du", "neg_rem <= sa_r;", "neg_rem <= 1'b0;"),
    ("M: PREP, DIV cho 0 sai dau", "neg_res <= (sa_r ^ sb_r) & (m != 32'd0);", "neg_res <= (sa_r ^ sb_r);"),
    ("M: PREP, dao dau b theo dau a", "wire [31:0] ub_r = sb_r ? (~m + 32'd1) : m;", "wire [31:0] ub_r = sa_r ? (~m + 32'd1) : m;"),
    ("M: PREP, MUL sai dau ket qua", "neg_res <= sa_r ^ sb_r;", "neg_res <= 1'b0;"),
    ("M: PREP, khong chot dau a", "sa_r <= sa;", "sa_r <= 1'b0;"),
]

# Ban RV32IM khong con id_bubble: redirect chi xoa idex_valid, nen mutation "khong huy lenh o ID" duoc viet lai theo RTL do
PIPEM_MUTATIONS = [m for m in PIPE_MUTATIONS if m[0] not in ("P: khong huy lenh o ID sau khi nhay", "B: ID nhay som thang redirect cua EX")] + [
    ("B: ID nhay som thang redirect cua EX", "end else if (redirect_q) begin\n            pc         <= redirect_pc_q;", "end else if (redirect_q & ~id_redirect) begin\n            pc         <= redirect_pc_q;"),
    ("P: khong huy lenh o ID sau khi nhay", "idex_valid_r <= ifid_valid & ~redirect_q & ~stall;", "idex_valid_r <= ifid_valid & ~stall;"),
    ("R: lenh o EX sau redirect khong bi vo hieu", "wire        idex_valid = idex_valid_r & ~redirect_q;", "wire        idex_valid = idex_valid_r;"),
    ("R: redirect_pc_q khong dang ky (dung pc cu)", "pc         <= redirect_pc_q;", "pc         <= pc;"),
    ("X: ID nhay som khi EX dang dong bang (lenh M)", "end else if (id_redirect & ~ex_stall) begin", "end else if (id_redirect) begin"),
    ("X: lenh trap van ghi thanh ghi dich", "exmem_rd_we     <= idex_rd_we & ~ex_stall & ~trap_ex;", "exmem_rd_we     <= idex_rd_we & ~ex_stall;"),
    ("X: mepc luu pc cua tang MEM", "tepc_q       <= idex_pc[31:2];", "tepc_q       <= exmem_pc[31:2];"),
    ("R: mtval ghi gia tri cua chu ky sau trap", "mtval_r      <= ttval_q;", "mtval_r      <= trap_tval;"),
    ("R: mcause ghi gia tri cua chu ky sau trap", "mcause_r     <= {28'd0, tcause_q};", "mcause_r     <= trap_cause;"),
    ("X: ECALL sai ma nguyen nhan", "else if (idex_ecall)    begin trap_cause = 32'd11;", "else if (idex_ecall)    begin trap_cause = 32'd8;"),
    ("X: mtval lenh bat hop le = 0", "begin trap_cause = 32'd2;  trap_tval = idex_instr; end", "begin trap_cause = 32'd2;  trap_tval = 32'd0; end"),
    ("X: EBREAK mtval = 0", "begin trap_cause = 32'd3;  trap_tval = idex_pc;    end", "begin trap_cause = 32'd3;  trap_tval = 32'd0;    end"),
    ("X: CSRRC thanh OR", "default: csr_new = csr_rdata & ~csr_src;", "default: csr_new = csr_rdata | csr_src;"),
    ("X: CSRRS/RC rs1=x0 coi la ghi", "wire id_csr_we_req = (funct3[1:0] == 2'b01) | (rs1 != 5'd0);", "wire id_csr_we_req = 1'b1;"),
    ("X: ghi CSR chi doc khong trap", "wire id_csr_ro     = (id_csr_addr[11:10] == 2'b11);", "wire id_csr_ro     = 1'b0;"),
    ("X: MRET khong dat MPIE=1", "mstatus_mpie <= 1'b1;", "mstatus_mpie <= 1'b0;"),
    ("X: trap khong xoa MIE", "mstatus_mpie <= mstatus_mie;\n            mstatus_mie  <= 1'b0;", "mstatus_mpie <= mstatus_mie;"),
    ("X: MRET nhay toi mtvec", "mret_ex ? {mepc_r, 2'b00}  :", "mret_ex ? {mtvec_r, 2'b00}  :"),
    ("X: ghi mscratch bi bo qua", "12'h340: mscratch <= csr_new;", "12'h340: mscratch <= mscratch;"),
    ("X: CSR dung rs1 chua forward", "wire [31:0] csr_src    = idex_funct3[2] ? {27'b0, idex_rs1} : op_a;",
     "wire [31:0] csr_src    = idex_funct3[2] ? {27'b0, idex_rs1} : idex_rs1_val;"),
    ("X: JALR nhay khong can chinh khong trap", "(idex_jalr & jalr_target[1]) |", "1'b0 |"),
    ("X: nhanh nhay khong can chinh khong trap", "(idex_branch & take_branch & pc_imm[1]);", "1'b0;"),
    ("X: FENCE.I bi coi la bat hop le", "wire legal_fence  = is_fence & (funct3 == 3'b000 | funct3 == 3'b001);", "wire legal_fence  = is_fence & (funct3 == 3'b000);"),
    ("X: coi funct7=1 la bat hop le", "wire legal_reg    = is_reg & (f7_zero | f7_m | (f7_alt", "wire legal_reg    = is_reg & (f7_zero | (f7_alt"),
    ("X: M khong dong bang IF", "end else if (!(stall | ex_stall)) begin", "end else if (!stall) begin"),
    ("X: M khong dong bang ID/EX", "end else if (ex_stall) begin\n            // lenh M dang chay o EX: giu nguyen ID/EX", "end else if (1'b0) begin\n            // lenh M dang chay o EX: giu nguyen ID/EX"),
    ("X: M khong nhan bong bay o EX/MEM", "exmem_valid     <= idex_valid & ~ex_stall;", "exmem_valid     <= idex_valid;"),
    ("X: M dung toan hang chua forward", ".a(op_a), .b(op_b),", ".a(idex_rs1_val), .b(idex_rs2_val),"),
    ("X: LH/SH lech khong trap", "wire ld_misal = idex_load  & (((idex_funct3[1:0] == 2'b01) & ea_lo[0]) |",
     "wire ld_misal = idex_load  & (((idex_funct3[1:0] == 2'b01) & 1'b0) |"),
    ("X: SW lech chi kiem tra bit 0", "wire st_misal = idex_store & (((idex_funct3[1:0] == 2'b01) & ea_lo[0]) | ((idex_funct3[1:0] == 2'b10) & (ea_lo != 2'b00)));",
     "wire st_misal = idex_store & (((idex_funct3[1:0] == 2'b01) & ea_lo[0]) | ((idex_funct3[1:0] == 2'b10) & ea_lo[0]));"),
    ("X: store lech van ghi bo nho", "exmem_store     <= idex_store & ~ex_stall & ~trap_ex;", "exmem_store     <= idex_store & ~ex_stall;"),
    ("X: load lech van ghi thanh ghi dich", "exmem_rd_we     <= idex_rd_we & ~ex_stall & ~trap_ex;", "exmem_rd_we     <= idex_rd_we & ~ex_stall & ~(trap_ex & ~ld_misal);"),
    ("X: store lech sai cause (4)", "else if (st_misal)      begin trap_cause = 32'd6;", "else if (st_misal)      begin trap_cause = 32'd4;"),
    ("X: load lech mtval = 0", "else if (ld_misal)      begin trap_cause = 32'd4;  trap_tval = ea;", "else if (ld_misal)      begin trap_cause = 32'd4;  trap_tval = 32'd0;"),
    ("X: dia chi lech tinh sai (bo cong imm)", "wire [1:0]  ea_lo = op_a[1:0] + idex_imm[1:0];", "wire [1:0]  ea_lo = op_a[1:0];"),
]


def run_mutations(rtl, n, length, seed0, tmp, only=None, pipe=False, full_pipe=False):
    src = open(rtl).read()
    caught = skipped = 0
    muts = [m for m in (PIPEM_MUTATIONS if full_pipe else PIPE_MUTATIONS if pipe else MUTATIONS) if not only or only.lower() in m[0].lower()]
    core_path = os.path.join(HERE, "..", "rv32i_core.v")
    core_src = open(core_path).read()
    if full_pipe and (not only or only.lower() in "m:"):
        muts = muts + [m for m in M_CORE_MUTATIONS if not only or only.lower() in m[0].lower()]
    for name, old, new in muts:
        is_core = name.startswith("M:")
        if old not in (core_src if is_core else src):
            print(f"  [BO QUA] {name}: khong tim thay doan can doi trong RTL (chuoi trong MUTATIONS can cap nhat theo RTL)")
            skipped += 1
            continue
        mpath = os.path.join(tmp, "mut.v")
        if is_core:                                   # mutation trong rv32i_core.v: giu nguyen file pipeline
            cpath = os.path.join(tmp, "core_mut.v")
            open(cpath, "w").write(core_src.replace(old, new, 1))
            open(mpath, "w").write(src)
            os.environ["RV32_CORE"] = cpath
        else:
            open(mpath, "w").write(src.replace(old, new, 1))
        try:
            cov, fails = run_suite(mpath, n, length, seed0, tmp, verbose=False, pipe=pipe, full_pipe=full_pipe)
        finally:
            os.environ.pop("RV32_CORE", None)
        ok = len(fails) > 0
        caught += ok
        print(f"  [{'BAT DUOC' if ok else 'BO SOT  '}] {name} ({len(fails)}/{n + 1} chuong trinh loi)")
    print(f"Bat duoc {caught}/{len(muts)} loi chen co y" + (f" ({skipped} bi bo qua, coi la that bai)" if skipped else ""))
    return caught == len(muts)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", default=None, help="mac dinh: ../rv32i_core.v, hoac ../rv32i_pipeline.v khi co --pipe")
    ap.add_argument("--pipem", action="store_true", help="kiem chung pipeline day du ../rv32im_pipeline.v (RV32IM + CSR + trap)")
    ap.add_argument("--pipe", action="store_true", help="kiem chung pipeline (chi RV32I thuan, in vet o tang WB)")
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--len", type=int, default=300)
    ap.add_argument("--seed0", type=int, default=1)
    ap.add_argument("--mutate", action="store_true")
    ap.add_argument("--only", default=None, help="chi chay cac loi co ten chua chuoi nay (dung voi --mutate)")
    a = ap.parse_args()
    if a.pipem:
        a.pipe = True
    if a.rtl is None:
        a.rtl = os.path.join(HERE, "..", "rv32im_pipeline.v" if a.pipem else "rv32i_pipeline.v" if a.pipe else "rv32i_core.v")
    tmp = tempfile.mkdtemp(prefix="rv32i_verify_")
    try:
        if a.mutate:
            ok = run_mutations(a.rtl, max(10, a.n // 10), a.len, a.seed0, tmp, a.only, a.pipe, a.pipem)
            sys.exit(0 if ok else 1)
        cov, fails = run_suite(a.rtl, a.n, a.len, a.seed0, tmp, pipe=a.pipe, full_pipe=a.pipem)
        report(cov, fails, a.n, a.pipe and not a.pipem)
        sys.exit(1 if fails else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
