#!/usr/bin/env python3
"""Mutation test cho bo du doan nhanh (BTB, RAS, gshare) cua rv32im_pipeline.v: moi dot bien phai bi bat.

Hai loai dot bien, hai bo kiem chung:
- "rand": dot bien lam SAI ket qua (duong sua o ID/EX bi hong). Bat bang verify/run_verify.py --pipem --bpstress
          (bo du doan nho, tag BTB 1 bit: BTB trung nham lien tuc nen cac duong sua thuc su chay), so voi ISS Python.
- "perf": dot bien chi lam CHAM (thiet ke bao dam doan sai khong doi ket qua, nen so ket qua khong bat duoc).
          Bat bang bpred/perf_bpred.py --check: so chu ky va so lan doan sai phai dung tung don vi.
Moi dot bien chay tren mot ban sao cua repo trong thu muc tam.
Dung (tu thu muc goc repo): python3 bpred/mutate_bpred.py [--kind rand|perf]
"""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
F = "rv32im_pipeline.v"

MUTATIONS = [
    # ---- lam sai ket qua ----
    ("EX khong so dich JALR voi dich du doan", "wire jalr_ok       = idex_jp_v & (idex_jp_t == jalr_target);",
     "wire jalr_ok       = idex_jp_v;", "rand"),
    ("ID khong sua khi dich BTB khac pc + imm",
     "wire id_fix_tgt = ifid_bp & (is_jal | legal_branch) & (ifid_bpt != id_target);", "wire id_fix_tgt = 1'b0;", "rand"),
    ("IF cong dich bang imm cua nhanh cho ca JAL",
     "ifid_tgt   <= pc + ((if_dec[6:0] == 7'b1101111) ? if_immj : if_immb);", "ifid_tgt   <= pc + if_immb;", "rand"),
    ("ID khong sua khi BTB trung nham lenh khong phai nhay", "wire id_fix_seq = ifid_bp & ~id_ctl;",
     "wire id_fix_seq = 1'b0;", "rand"),
    ("ID sua BTB trung nham ve dich thay vi lenh ke tiep", "wire [31:0] id_redir_pc = id_fix_seq ? id_seq :",
     "wire [31:0] id_redir_pc = id_fix_seq ? id_target :", "rand"),
    ("IF/ID quen co da nhay theo BTB", "ifid_bp    <= if_pred & ~if_tfault;", "ifid_bp    <= 1'b0;", "rand"),
    ("EX coi nhanh IF da nhay la doan khong nhay", "wire id_pred_taken = legal_branch & (ifid_bp | ifid_ctr);",
     "wire id_pred_taken = legal_branch & ifid_ctr;", "rand"),
    ("JAL khong nhay khi BTB truot", "wire id_late    = ~ifid_bp & (is_jal |", "wire id_late    = ~ifid_bp & (1'b0 |", "rand"),
    # dich du doan ghi xuong EX khac dich ma IF/ID da nhay theo: EX so nham dich, trung hop thi chay sai duong
    ("JALR ghi dich du doan khac dich da nhay theo (BTB / RAS dao nguon)",
     "wire [31:0] id_jp_t = ifid_bp ? ifid_bpt : ras_val;", "wire [31:0] id_jp_t = ifid_bp ? ras_val : ifid_bpt;", "rand"),
    # ---- chi lam cham ----
    ("BTB khong bao gio duoc ghi", "up_btb  <= ex_upd & (", "up_btb  <= 1'b0 & (", "perf"),
    ("RAS khong day khi goi ham", "up_push <= ex_upd & ex_push;", "up_push <= 1'b0;", "perf"),
    ("RAS khong lay ra khi tra ve", "up_pop  <= ex_upd & ex_pop;", "up_pop  <= 1'b0;", "perf"),
    ("RAS day dia chi lenh goi thay vi dia chi tra ve", "up_link <= pc_next[31:1];", "up_link <= idex_pc[31:1];", "perf"),
    ("BTB ghi lenh tra ve thanh JALR thuong", "(ex_pop ? T_RET : T_JALR)", "T_JALR", "perf"),
    ("IF bo qua bang dem voi muc nhanh (luon nhay)", "((if_typ != T_BR) | if_ctr)", "1'b1", "perf"),
    ("BTB khong so tag", "(btb_tag[if_bi] == if_bt)", "1'b1", "perf"),
    ("RAS suy doan khong chep lai tu ban kien truc khi EX redirect", "if (redirect_q) begin\n                    s_cnt <= a_cnt_n;",
     "if (1'b0) begin\n                    s_cnt <= a_cnt_n;", "perf"),
    ("RAS suy doan khong lay ra khi lenh tra ve roi ID", "wire s_pop   = id_go & id_ret;", "wire s_pop   = 1'b0;", "perf"),
    ("gshare: cap nhat bang dem theo pc thay vi chi so luc doan", "exmem_bidx   <= idex_pidx;",
     "exmem_bidx   <= idex_pc[PCB +: BHT_BITS];", "perf"),
    ("gshare: lich su khong cap nhat", "ghr <= {ghr, take_branch};", "ghr <= ghr;", "perf"),
]


def run(rep, how):
    if how == "rand":
        cmd = [sys.executable, os.path.join(rep, "verify", "run_verify.py"), "--pipem", "--bpstress", "--stop-on-fail", "--n", "40"]
    else:
        cmd = [sys.executable, os.path.join(rep, "bpred", "perf_bpred.py"), "--check"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return True, "treo"
    out = r.stdout + r.stderr
    if "Bien dich RTL that bai" in out or "Traceback" in out or "CalledProcessError" in out:
        return None, out.strip()[-200:]
    last = [l for l in out.splitlines() if l.strip()]
    detail = (last[0] if how == "rand" else next((l for l in last if "FAIL" in l or "PASS" in l), last[-1])) if last else ""
    if how == "perf" and r.returncode:
        detail = next((l.strip() for l in last if "mong doi" in l or "khong nhanh hon" in l), detail)
    return bool(r.returncode), detail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", choices=["rand", "perf", "all"], default="all")
    a = ap.parse_args()
    muts = [m for m in MUTATIONS if a.kind in ("all", m[3])]
    src = open(os.path.join(ROOT, F)).read()
    killed, bad = 0, 0
    for name, old, new, how in muts:
        if src.count(old) != 1:
            print(f"  BO QUA  {name}: khong tim thay chuoi goc", flush=True)
            bad += 1
            continue
        tmp = tempfile.mkdtemp(prefix="mutb_")
        rep = os.path.join(tmp, "repo")
        shutil.copytree(ROOT, rep, ignore=shutil.ignore_patterns(".git", "results", "*.vcd", "*.vvp"))
        open(os.path.join(rep, F), "w").write(src.replace(old, new))
        caught, detail = run(rep, how)
        if caught is None:
            bad += 1
            print(f"  LOI   [{how}] {name}: {detail}", flush=True)
        else:
            killed += caught
            print(f"  {'BAT' if caught else 'SOT'}  [{how}] {name}: {str(detail)[:150]}", flush=True)
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"bat duoc {killed}/{len(muts)} dot bien")
    sys.exit(0 if killed == len(muts) else 1)


if __name__ == "__main__":
    main()
