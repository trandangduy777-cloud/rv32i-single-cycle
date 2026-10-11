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
             "add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]


def compile_rtl(rtl, out_vvp):
    cmd = ["iverilog", "-g2012", "-o", out_vvp, rtl, os.path.join(HERE, "tb_trace.v")]
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


def run_suite(rtl, n, length, seed0, tmp, verbose=True):
    vvp = os.path.join(tmp, "sim.vvp")
    compile_rtl(rtl, vvp)
    cov, fails, instr_total = {}, [], 0
    # chuong trinh dinh huong co san
    directed = load_hex(os.path.join(HERE, "..", "prog.hex"))
    res, c = check_one(vvp, directed, [0] * 1024, tmp, "directed")
    for k, v in c.items():
        cov[k] = cov.get(k, 0) + v
    if res[0] != "PASS":
        fails.append(("directed", res))
    # chuong trinh ngau nhien
    for s in range(seed0, seed0 + n):
        words, dmem = Gen(s, length).build()
        res, c = check_one(vvp, words, dmem, tmp, f"s{s}")
        for k, v in c.items():
            cov[k] = cov.get(k, 0) + v
        instr_total += len(words)
        if res[0] != "PASS":
            fails.append((f"seed {s}", res))
    return cov, fails


def report(cov, fails, n):
    print(f"Chuong trinh: {n} ngau nhien + 1 dinh huong, that bai: {len(fails)}")
    for name, (status, diff) in fails[:3]:
        print(f"  [{name}] {status}")
        if diff:
            i, a, b = diff
            print(f"    lenh thu {i}\n    RTL: {a}\n    ISS: {b}")
    missing = [x for x in ALL_INSTR if cov.get(x, 0) == 0]
    print("Phu lenh: %d/%d" % (len(ALL_INSTR) - len(missing), len(ALL_INSTR)),
          "| chua phu: " + ", ".join(missing) if missing else "| du 37/37 lenh")
    low = sorted((v, k) for k, v in cov.items() if k in ALL_INSTR)[:5]
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
]


def run_mutations(rtl, n, length, seed0, tmp):
    src = open(rtl).read()
    caught = 0
    for name, old, new in MUTATIONS:
        if old not in src:
            print(f"  [BO QUA] {name}: khong tim thay doan can doi trong RTL")
            continue
        mpath = os.path.join(tmp, "mut.v")
        open(mpath, "w").write(src.replace(old, new, 1))
        cov, fails = run_suite(mpath, n, length, seed0, tmp, verbose=False)
        ok = len(fails) > 0
        caught += ok
        print(f"  [{'BAT DUOC' if ok else 'BO SOT  '}] {name} ({len(fails)}/{n + 1} chuong trinh loi)")
    print(f"Bat duoc {caught}/{len(MUTATIONS)} loi chen co y")
    return caught == len(MUTATIONS)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", default=os.path.join(HERE, "..", "rv32i_core.v"))
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--len", type=int, default=300)
    ap.add_argument("--seed0", type=int, default=1)
    ap.add_argument("--mutate", action="store_true")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="rv32i_verify_")
    try:
        if a.mutate:
            ok = run_mutations(a.rtl, max(10, a.n // 10), a.len, a.seed0, tmp)
            sys.exit(0 if ok else 1)
        cov, fails = run_suite(a.rtl, a.n, a.len, a.seed0, tmp)
        report(cov, fails, a.n)
        sys.exit(1 if fails else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
