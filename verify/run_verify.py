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
import rv32_zb                                            # noqa: E402

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
        if MA:                          # load/store lech dia chi bang phan cung (MISALIGNED = 1)
            cmd[2:2] = ["-DMA"]
        if BPSTRESS:                    # bo du doan nho, tag 1 bit (xem tb_trace_pipe.v)
            cmd[2:2] = ["-DBPSTRESS"]
        cmd[2:2] = [f"-DMULLAT={MUL_LAT}"]   # bo nhan cua pipeline RV32IM
        for e in ZB:                    # Zba/Zbb/Zbs/Zbc/Zicond: tham so tuong ung cua pipeline = 1
            cmd[2:2] = [f"-D{e.upper()}=1"]
        if CACHE:                       # bo nho co do tre qua cache 2 x 2 (xem tb_trace_pipe.v)
            cmd[2:2] = ["-DCACHE", f"-DCWY={WAYS}"]
            cmd += [os.path.join(HERE, "..", f) for f in ("rv32_icache.v", "rv32_dcache.v")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr)
        sys.exit("Bien dich RTL that bai")


CACHE = False                           # --cache: chay pipeline RV32IM qua cache voi bo nho tre ngau nhien
WAYS = 1                                # --ways: so duong cua 2 cache (2 dong: 1 = anh xa truc tiep, 2 = 1 tap 2 duong)
MA = False                              # --ma: pipeline RV32IM voi MISALIGNED = 1, ISS cung khong trap khi lech
ZB = ()                                 # --zb: cac phan mo rong zba/zbb/zbs/zbc/zicond dang bat (RTL, ISS, bo sinh cung bat)
STOP_FAIL = False                       # --stop-on-fail: dung o chuong trinh dau tien lech (mutation test: bat duoc la du)
ZB_PROBE = False                        # --zb-probe: bo sinh them ma Zb cua phan mo rong tat / gan hop le (phai trap lenh bat hop le)
BPSTRESS = False                        # --bpstress: BTB 4 muc tag 1 bit, RAS 2 muc, gshare 2 bit
MUL_LAT = 2                             # --mul-lat: bo nhan 0 lap, 1 song song 1 chu ky, 2 song song 2 tang
_seed = [0]
_hung = [False]                          # co chuong trinh mo phong qua 120 giay


def run_rtl(vvp, prog, dmem=None):
    cmd = ["vvp", vvp, f"+prog={prog}"] + ([f"+dmem={dmem}"] if dmem else [])
    if CACHE:
        _seed[0] += 1
        cmd += ["+lat=6", f"+seed={_seed[0]}"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:   # mo phong qua 120 giay (vd. RTL loi chay vong vo han in vet lien tuc): coi la treo
        _hung[0] = True
        return [], True
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


def check_one(vvp, prog_words, dmem_words, tmp, tag, irq_csrs=False):
    p = os.path.join(tmp, f"{tag}.prog.hex")
    d = os.path.join(tmp, f"{tag}.dmem.hex")
    write_hex(p, prog_words + [0x13] * (1024 - len(prog_words)))
    write_hex(d, dmem_words)
    rtl_lines, timeout = run_rtl(vvp, p, d)
    iss = ISS(prog_words, dmem_words, irq_csrs, misaligned_hw=MA, zb=ZB)
    iss_lines, halted = iss.run()
    if timeout or not halted:
        return ("TIMEOUT", None), iss.coverage
    diff = compare(rtl_lines, iss_lines)
    return (("FAIL", diff) if diff else ("PASS", None)), iss.coverage


def run_suite(rtl, n, length, seed0, tmp, verbose=True, pipe=False, full_pipe=False, stop_on_hang=False):
    """stop_on_hang: (mutation) dung ngay khi mot chuong trinh treo qua 120 giay, khoi cho tung chuong trinh con lai"""
    _hung[0] = False
    vvp = os.path.join(tmp, "sim.vvp")
    compile_rtl(rtl, vvp, "tb_trace_pipe.v" if pipe else "tb_trace.v", full_pipe)
    # pipeline RV32IM co them CSR ngat mie/mip; single-cycle thi hai dia chi nay la CSR khong ton tai
    profile = "base" if (pipe and not full_pipe) else ("irq" if full_pipe else "full")
    cov, fails, instr_total = {}, [], 0
    # chuong trinh dinh huong co san (pipeline chi chay ban RV32I thuan)
    directed = load_hex(os.path.join(HERE, "..", "prog_base.hex" if (pipe and not full_pipe) else "prog.hex"))
    res, c = check_one(vvp, directed, [0] * 1024, tmp, "directed", full_pipe)
    for k, v in c.items():
        cov[k] = cov.get(k, 0) + v
    if res[0] != "PASS":
        fails.append(("directed", res))
        if STOP_FAIL:
            return cov, fails
    # chuong trinh ngau nhien
    for s in range(seed0, seed0 + n):
        words, dmem = Gen(s, length, profile, ma=MA, zb=ZB, zb_probe=ZB_PROBE).build()
        res, c = check_one(vvp, words, dmem, tmp, f"s{s}", full_pipe)
        for k, v in c.items():
            cov[k] = cov.get(k, 0) + v
        instr_total += len(words)
        if res[0] != "PASS":
            fails.append((f"seed {s}", res))
            if STOP_FAIL:
                break
            if stop_on_hang and _hung[0]:
                break
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
    if ZB:                              # phu lenh cua cac phan mo rong dang bat
        zn = sorted({n for e in ZB for n in rv32_zb.NAMES_OF[e]})
        zmiss = [n for n in zn if cov.get(n, 0) == 0]
        print("Phu lenh %s: %d/%d" % ("+".join(ZB), len(zn) - len(zmiss), len(zn)),
              ("| chua phu: " + ", ".join(zmiss)) if zmiss else "| du lenh",
              "| it nhat: " + ", ".join(f"{k}={v}" for v, k in sorted((cov.get(n, 0), n) for n in zn)[:3]))


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
    ("M: so sanh chia dung > thay vi >=", "ge  = (rem >= {1'b0, mm});", "ge  = (rem > {1'b0, mm});"),
    ("M: thieu 1 chu ky lap", "if (cnt == LAST) state <= FIN;", "if (cnt == LAST - 5'd1) state <= FIN;"),
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
PIPEM_MUTATIONS = [m for m in PIPE_MUTATIONS if m[0] not in ("P: khong huy lenh o ID sau khi nhay", "B: ID nhay som thang redirect cua EX",
                                                             "B: doan sai nhay ve dich nham", "P: LB khong mo rong dau",
                                                             "P: SH sai byte-enable",
                                                             "B: ID nhay som khi dang stall load-use", "B: JAL khong nhay o ID")] + [
    # bo du doan RV32IM (BTB / RAS, xem bpred/): ID sua hoac nhay som qua id_fix_tgt / id_fix_seq / id_late
    ("B: ID nhay som khi dang stall load-use", "assign id_redirect = ifid_valid & ~stall & (id_fix_tgt | id_fix_seq | id_late);",
     "assign id_redirect = ifid_valid & (id_fix_tgt | id_fix_seq | id_late);"),
    ("B: JAL khong nhay o ID (khi BTB chua co)", "wire id_late    = ~ifid_bp & (is_jal |", "wire id_late    = ~ifid_bp & (1'b0 |"),
    # pipeline RV32IM: dich "chay tiep" la pc_next (pc + 2 voi lenh nen, pc + 4 voi lenh 32 bit)
    ("B: doan sai nhay ve dich nham", "(idex_pred_taken ? pc_next : pc_imm)", "(idex_pred_taken ? pc_imm : pc_next)"),
    ("B: ID nhay som thang redirect cua EX", "end else if (redirect_q) begin\n            pc         <= redirect_pc_q;", "end else if (redirect_q & ~id_redirect) begin\n            pc         <= redirect_pc_q;"),
    ("P: khong huy lenh o ID sau khi nhay", "idex_valid_r <= ifid_valid & ~redirect_q & ~stall;", "idex_valid_r <= ifid_valid & ~stall;"),
    ("R: lenh o EX sau redirect khong bi vo hieu", "wire        idex_valid = idex_valid_r & ~redirect_q;", "wire        idex_valid = idex_valid_r;"),
    ("R: redirect_pc_q khong dang ky (dung pc cu)", "pc         <= redirect_pc_q;", "pc         <= pc;"),
    ("X: ID nhay som khi EX dang dong bang (lenh M)", "end else if (id_redirect & ~ex_stall) begin", "end else if (id_redirect) begin"),
    ("X: lenh trap van ghi thanh ghi dich", "exmem_rd_we     <= idex_rd_we & ~ex_stall & ~trap_ex;", "exmem_rd_we     <= idex_rd_we & ~ex_stall;"),
    ("X: mepc luu pc cua tang MEM", "tepc_q       <= idex_pc[31:1];", "tepc_q       <= exmem_pc[31:1];"),
    ("R: mtval ghi gia tri cua chu ky sau trap", "mtval_r      <= ttval_q;", "mtval_r      <= trap_tval;"),
    ("R: mcause ghi gia tri cua chu ky sau trap", "mcause_r     <= {tint_q, 27'd0, tcause_q};", "mcause_r     <= trap_cause;"),
    ("X: ECALL sai ma nguyen nhan", "else if (idex_ecall)    begin trap_cause = {28'd0, 2'b10, priv};", "else if (idex_ecall)    begin trap_cause = 32'd8;"),
    ("X: mtval lenh bat hop le = 0", "begin trap_cause = 32'd2;  trap_tval = idex_instr; end", "begin trap_cause = 32'd2;  trap_tval = 32'd0; end"),
    ("X: EBREAK mtval = 0", "begin trap_cause = 32'd3;  trap_tval = idex_pc;    end", "begin trap_cause = 32'd3;  trap_tval = 32'd0;    end"),
    ("X: CSRRC thanh OR", "default: csr_new = csr_rdata & ~csr_src;", "default: csr_new = csr_rdata | csr_src;"),
    ("X: CSRRS/RC rs1=x0 coi la ghi", "wire id_csr_we_req = (funct3[1:0] == 2'b01) | (rs1 != 5'd0);", "wire id_csr_we_req = 1'b1;"),
    ("X: ghi CSR chi doc khong trap", "wire id_csr_ro     = (id_csr_addr[11:10] == 2'b11);", "wire id_csr_ro     = 1'b0;"),
    ("X: MRET khong dat MPIE=1", "mstatus_mpie <= 1'b1;", "mstatus_mpie <= 1'b0;"),
    ("X: trap khong xoa MIE", "mstatus_mpie <= mstatus_mie;\n                mstatus_mie  <= 1'b0;", "mstatus_mpie <= mstatus_mie;"),
    ("X: MRET nhay toi mtvec", "mret_ex ? mepc_v           :", "mret_ex ? {mtvec_r, 2'b00} :"),
    ("X: ghi mscratch bi bo qua", "12'h340: mscratch <= csr_new;", "12'h340: mscratch <= mscratch;"),
    ("X: CSR dung rs1 chua forward", "wire [31:0] csr_src    = idex_funct3[2] ? {27'b0, idex_rs1} : op_a;",
     "wire [31:0] csr_src    = idex_funct3[2] ? {27'b0, idex_rs1} : idex_rs1_val;"),
    ("X: JALR nhay khong can chinh khong trap", "(idex_jalr & jalr_target[1]) |", "1'b0 |"),
    ("X: nhanh nhay khong can chinh khong trap", "(idex_branch & take_branch & pc_imm[1]));", "1'b0);"),
    ("X: FENCE.I bi coi la bat hop le", "wire legal_fence  = is_fence & (funct3 == 3'b000 | funct3 == 3'b001);", "wire legal_fence  = is_fence & (funct3 == 3'b000);"),
    ("X: coi funct7=1 la bat hop le", "wire legal_reg    = is_reg & (f7_zero | f7_m | (f7_alt", "wire legal_reg    = is_reg & (f7_zero | (f7_alt"),
    ("X: M khong dong bang IF", "end else if (stall | ex_stall) begin\n            // ID hoac EX dang dung", "end else if (stall) begin\n            // ID hoac EX dang dung"),
    ("X: M khong dong bang ID/EX", "end else if (ex_stall | frz) begin\n            // lenh M dang chay", "end else if (frz) begin\n            // lenh M dang chay"),
    ("X: M khong nhan bong bay o EX/MEM", "exmem_valid     <= idex_valid & ~ex_stall;", "exmem_valid     <= idex_valid;"),
    ("X: M dung toan hang chua forward", ".a(op_a), .b(op_b),", ".a(idex_rs1_val), .b(idex_rs2_val),"),
    ("X: LH/SH lech khong trap", "wire ld_misal = (MISALIGNED == 0) & idex_load  &\n                    (((idex_funct3[1:0] == 2'b01) & ea_lo[0])",
     "wire ld_misal = (MISALIGNED == 0) & idex_load  &\n                    (((idex_funct3[1:0] == 2'b01) & 1'b0)"),
    ("X: SW lech chi kiem tra bit 0", "(((idex_funct3[1:0] == 2'b01) & ea_lo[0]) | ((idex_funct3[1:0] == 2'b10) & (ea_lo != 2'b00)));\n\n",
     "(((idex_funct3[1:0] == 2'b01) & ea_lo[0]) | ((idex_funct3[1:0] == 2'b10) & ea_lo[0]));\n\n"),
    # tang MEM viet lai theo byte (64 bit / wstrb 8 bit) tu khi co MISALIGNED: thay 2 dot bien chung voi RV32I
    ("P: LB khong mo rong dau", "3'b000:  ld_data = {{24{ld_sh[7]}},  ld_sh[7:0]};", "3'b000:  ld_data = {24'b0, ld_sh[7:0]};"),
    ("P: SH sai byte-enable", "st_wide = {48'b0, exmem_store_val[15:0]}; st_strb8 = 8'b0000_0011;",
     "st_wide = {48'b0, exmem_store_val[15:0]}; st_strb8 = 8'b0000_0110;"),
    ("X: store lech van ghi bo nho", "exmem_store     <= idex_store & ~ex_stall & ~trap_ex;", "exmem_store     <= idex_store & ~ex_stall;"),
    ("X: load lech van ghi thanh ghi dich", "exmem_rd_we     <= idex_rd_we & ~ex_stall & ~trap_ex;", "exmem_rd_we     <= idex_rd_we & ~ex_stall & ~(trap_ex & ~ld_misal);"),
    ("X: store lech sai cause (4)", "else if (st_misal)      begin trap_cause = 32'd6;", "else if (st_misal)      begin trap_cause = 32'd4;"),
    ("X: load lech mtval = 0", "else if (ld_misal)      begin trap_cause = 32'd4;  trap_tval = ea;", "else if (ld_misal)      begin trap_cause = 32'd4;  trap_tval = 32'd0;"),
    ("X: dia chi lech tinh sai (bo cong imm)", "wire [1:0]  ea_lo = op_a[1:0] + idex_imm[1:0];", "wire [1:0]  ea_lo = op_a[1:0];"),
]


def run_mutations(rtl, n, length, seed0, tmp, only=None, pipe=False, full_pipe=False):
    global MUL_LAT
    src = open(rtl).read()
    caught = skipped = 0
    muts = [m for m in (PIPEM_MUTATIONS if full_pipe else PIPE_MUTATIONS if pipe else MUTATIONS) if not only or only.lower() in m[0].lower()]
    core_path = os.path.join(HERE, "..", "rv32i_core.v")
    core_src = open(core_path).read()
    if full_pipe and (not only or only.lower() in "m:"):
        muts = muts + [m for m in M_CORE_MUTATIONS if not only or only.lower() in m[0].lower()]
    for name, old, new in muts:
        # chi o --pipem, mutation "M:" moi nam trong file rv32i_core.v rieng; o single-cycle, rv32i_core.v chinh la file dang kiem
        is_core = name.startswith("M:") and full_pipe
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
            # cac mutation "M:" nham vao bo nhan/chia lap; voi MUL_LAT != 0 lenh nhan di bo nhan song song (co
            # mutation rieng o mul/mutate_mul.py) nen chay voi MUL_LAT = 0 de duong nhan lap thuc su duoc dung
            saved_lat, MUL_LAT = MUL_LAT, 0
        else:
            open(mpath, "w").write(src.replace(old, new, 1))
        try:
            cov, fails = run_suite(mpath, n, length, seed0, tmp, verbose=False, pipe=pipe, full_pipe=full_pipe,
                                   stop_on_hang=True)
        finally:
            os.environ.pop("RV32_CORE", None)
            if is_core:
                MUL_LAT = saved_lat
        ok = len(fails) > 0
        caught += ok
        print(f"  [{'BAT DUOC' if ok else 'BO SOT  '}] {name} ({len(fails)}/{n + 1} chuong trinh loi"
              + (", dung som vi treo" if _hung[0] else "") + ")", flush=True)
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
    ap.add_argument("--cache", action="store_true",
                    help="voi --pipem: lenh/du lieu qua cache 2x2, bo nho tre ngau nhien 1..6 chu ky")
    ap.add_argument("--ways", type=int, default=1, choices=[1, 2], help="voi --cache: so duong cua cache 2 dong")
    ap.add_argument("--ma", action="store_true",
                    help="voi --pipem: load/store lech dia chi bang phan cung (MISALIGNED = 1), sinh nhieu truy cap lech")
    ap.add_argument("--bpstress", action="store_true",
                    help="voi --pipem: bo du doan nho (BTB 4 muc tag 1 bit, RAS 2, gshare 2): trung nham BTB lien tuc")
    ap.add_argument("--zb", default="", help="voi --pipem: bat phan mo rong, vd. all hoac zba,zbb,zbs,zbc,zicond (RTL, ISS, bo sinh)")
    ap.add_argument("--stop-on-fail", action="store_true", help="dung o chuong trinh dau tien lech (cho mutation test)")
    ap.add_argument("--zb-probe", action="store_true",
                    help="bo sinh them ma Zb cua phan mo rong tat va ma gan hop le: ca RTL va ISS phai bao lenh bat hop le")
    ap.add_argument("--mul-lat", type=int, default=2, choices=[0, 1, 2], help="voi --pipem: kieu bo nhan")
    a = ap.parse_args()
    MUL_LAT = a.mul_lat
    ZB = tuple(rv32_zb.ALL_EXTS) if a.zb == "all" else tuple(e for e in a.zb.split(",") if e)
    if any(e not in rv32_zb.ALL_EXTS for e in ZB) or (ZB and not a.pipem):
        sys.exit("--zb chi dung voi --pipem, danh sach: " + ",".join(rv32_zb.ALL_EXTS) + " hoac all")
    ZB_PROBE = a.zb_probe and a.pipem
    STOP_FAIL = a.stop_on_fail
    CACHE = a.cache and a.pipem
    BPSTRESS = a.bpstress and a.pipem
    WAYS = a.ways
    MA = a.ma and a.pipem
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
