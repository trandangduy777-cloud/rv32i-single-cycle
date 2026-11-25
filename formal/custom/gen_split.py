# Chia check pc_fwd va reg cua riscv-formal theo LOP LENH de moi phan nho hon (BMC sau hon duoc), chay trong cores/rv32im_pipeline.
#   pc_fwd: lop cua lenh retire TRUOC lenh duoc kiem (lenh quyet dinh pc ke tiep): br, jal, jalr, trap (trap / mret), other
#   reg   : lop cua lenh duoc kiem (lenh doc rs1 / rs2): c (nen), ld, st, alu, m, brj, sys, oth (con lai, vd. opcode khong hop le)
# Moi check = ban sao check goc + 1 dong assume o chu ky kiem; hop cac lop = check goc (khong lop nao bi bo sot).
# Chi sinh khi dat SPLIT_PC_DEPTH / SPLIT_REG_DEPTH (do sau = chu ky kiem). Dung: SPLIT_PC_DEPTH=20 SPLIT_REG_DEPTH=30 bash formal/run.sh run 'split'
import os, re
pc_d = int(os.environ.get("SPLIT_PC_DEPTH", "0")); reg_d = int(os.environ.get("SPLIT_REG_DEPTH", "0"))
def m(i):   # (insn, trap) -> dieu kien; i la bieu thuc 32 bit
    return {
    "BRX":   "((%s[6:0] == 7'b1100011) || (%s[1:0] == 2'b01 && %s[15:14] == 2'b11))" % (i, i, i),
    "JALX":  "((%s[6:0] == 7'b1101111) || (%s[1:0] == 2'b01 && (%s[15:13] == 3'b001 || %s[15:13] == 3'b101)))" % (i, i, i, i),
    "JALRX": "((%s[6:0] == 7'b1100111) || (%s[1:0] == 2'b10 && %s[15:13] == 3'b100 && %s[6:2] == 5'd0 && %s[11:7] != 5'd0))" % (i, i, i, i, i),
    }
PC = {
 "br":    "(!t && %s)",
 "jal":   "(!t && %s)",
 "jalr":  "(!t && %s)",
 "trap":  "(t || i == 32'h3020_0073)",
 "other": "(!t && i != 32'h3020_0073 && !(%s) && !(%s) && !(%s))",
}
def pc_cond(cls):
    x = m("i")
    if cls == "br":   return "(!t && %s)" % x["BRX"]
    if cls == "jal":  return "(!t && %s)" % x["JALX"]
    if cls == "jalr": return "(!t && %s)" % x["JALRX"]
    if cls == "trap": return "(t || i == 32'h3020_0073)"
    return "(!t && i != 32'h3020_0073 && !%s && !%s && !%s)" % (x["BRX"], x["JALX"], x["JALRX"])
REG = {
 "c":   "(i[1:0] != 2'b11)",
 "ld":  "(i[1:0] == 2'b11 && i[6:0] == 7'b0000011)",
 "st":  "(i[1:0] == 2'b11 && i[6:0] == 7'b0100011)",
 "alu": "(i[1:0] == 2'b11 && ((i[6:0] == 7'b0110011 && i[31:25] != 7'b0000001) || i[6:0] == 7'b0010011 || i[6:0] == 7'b0110111 || i[6:0] == 7'b0010111))",
 "m":   "(i[1:0] == 2'b11 && i[6:0] == 7'b0110011 && i[31:25] == 7'b0000001)",
 "brj": "(i[1:0] == 2'b11 && (i[6:0] == 7'b1100011 || i[6:0] == 7'b1100111 || i[6:0] == 7'b1101111))",
 "sys": "(i[1:0] == 2'b11 && (i[6:0] == 7'b1110011 || i[6:0] == 7'b0001111))",
}
REG["oth"] = "(i[1:0] == 2'b11 && !%s && !%s && !%s && !%s && !%s && !%s)" % tuple(REG[k].replace("(i[1:0] == 2'b11 && ", "(", 1) if False else REG[k] for k in ("ld", "st", "alu", "m", "brj", "sys"))
src = "../../checks/"
def clone(name, kind, cls, cond, depth):
    base = open("checks/%s_ch0.sby" % kind).read()
    chk = open(src + "rvfi_%s_check.sv" % kind).read()
    mod = "rvfi_%s_split_check" % kind
    chk = chk.replace("rvfi_%s_check" % kind, mod)
    if kind == "pc_fwd":
        chk = chk.replace("reg expect_pc_valid = 0;", "reg expect_pc_valid = 0;\n\treg [31:0] prev_insn = 0; reg prev_trap = 0;")
        chk = chk.replace("expect_pc_valid = 1;", "expect_pc_valid = 1; prev_insn = rvfi_insn[channel_idx*32 +: 32]; prev_trap = rvfi_trap[channel_idx];")
        chk = chk.replace("assume(insn_order == rvfi_order[64*`RISCV_FORMAL_CHANNEL_IDX +: 64]);",
                          "assume(insn_order == rvfi_order[64*`RISCV_FORMAL_CHANNEL_IDX +: 64]);\n\t\t\t\tassume(!expect_pc_valid || `SPLIT_COND(prev_insn, prev_trap));")
    else:
        chk = chk.replace("assume(insn_order == rvfi_order[64*`RISCV_FORMAL_CHANNEL_IDX +: 64]);",
                          "assume(insn_order == rvfi_order[64*`RISCV_FORMAL_CHANNEL_IDX +: 64]);\n\t\t\t\tassume(`SPLIT_COND(rvfi_insn[`RISCV_FORMAL_CHANNEL_IDX*32 +: 32], 1'b0));")
    open(src + "rvfi_%s_%s_split.sv" % (kind, cls), "w").write(chk)
    s = base.replace("rvfi_%s_check" % kind, "rvfi_%s_%s_split" % (kind, cls)).replace("%s_ch0" % kind, name)
    s = s.replace("rvfi_%s_%s_split.sv" % (kind, cls), "rvfi_%s_%s_split.sv" % (kind, cls))
    s = s.replace("`define RISCV_FORMAL_CHECKER rvfi_%s_%s_split" % (kind, cls), "`define RISCV_FORMAL_CHECKER %s" % mod)
    s = re.sub(r"depth \d+", "depth %d" % (depth + 1), s, count=1)
    s = re.sub(r"skip \d+", "skip %d" % depth, s, count=1)
    s = re.sub(r"CHECK_CYCLE \d+", "CHECK_CYCLE %d" % depth, s)
    s = s.replace("`define RISCV_FORMAL_CHANNEL_IDX 0", "`define RISCV_FORMAL_CHANNEL_IDX 0\n`define SPLIT_COND(i, t) %s" % cond.replace("\n", " "))
    open("checks/%s.sby" % name, "w").write(s)
if pc_d:
    for cls in PC:
        c = pc_cond(cls).replace("i ", "i ").replace("(i[", "(i[")
        clone("split_pc_fwd_%s_ch0" % cls, "pc_fwd", cls, "(" + pc_cond(cls) + ")", pc_d)
if reg_d:
    for cls, c in REG.items():
        clone("split_reg_%s_ch0" % cls, "reg", cls, c, reg_d)
