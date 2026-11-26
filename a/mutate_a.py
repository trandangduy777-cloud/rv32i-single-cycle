#!/usr/bin/env python3
"""Mutation test cho mo rong A (LR.W, SC.W, AMO*.W) cua rv32im_pipeline.v: moi dot bien phai bi bat.

Moi dot bien sua 1 doan trong giai ma (ID), kiem tra lech dia chi (EX) hoac khoi MEM (AMO 2 pha, ALU AMO, dat cho) roi chay
verify/run_verify.py --pipem (so vet tung lenh voi ISS Python) tren ban sao cua repo trong thu muc tam. Cau hinh:
- "a":     --a --a-probe          (A bat, co ma gia cho lenh bat hop le)
- "stclr": --a --a-st-clr         (che do chat: store thuong / AMO vao tu dat cho cung xoa dat cho)
- "lat":   --a --cache --ma       (cache + bo dem ghi + bo nho tre + lech dia chi bang phan cung: AMO doc-sua-ghi qua cache)
- "off":   --a-probe              (A TAT: moi lenh A phai la lenh bat hop le, misa khong co bit A)
Dung (tu thu muc goc repo): python3 a/mutate_a.py [--only <chuoi trong ten>] [--n <so chuong trinh>] [--jobs 2]
"""
import argparse, os, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
F = "rv32im_pipeline.v"
CFG = {"a": ["--a", "--a-probe"], "stclr": ["--a", "--a-st-clr", "--a-probe"],
       "lat": ["--a", "--cache", "--ma"], "off": ["--a-probe"]}

M = []     # (ten, chuoi goc (dung 1 lan), chuoi thay, cau hinh)


def m(name, old, new, cfg="a"):
    M.append((name, old, new, cfg))


# ---- giai ma (ID) ----
m("giai ma: AMO bat khi A tat", "(funct3 == 3'b010) & (A_EXT != 0);", "(funct3 == 3'b010);", "off")
m("giai ma: bo kiem funct3 (moi funct3 deu la AMO)", "(opcode == 7'b0101111) & (funct3 == 3'b010)", "(opcode == 7'b0101111)")
m("giai ma: LR.W khong kiem rs2 = 0", "(id_amo_f5 == 5'b00010) & (rs2 == 5'd0);", "(id_amo_f5 == 5'b00010);")
m("giai ma: amomaxu bi coi la bat hop le", "id_amo_f5 == 5'b11100);", "1'b0);")
m("giai ma: amoswap bi coi la bat hop le", "id_amo_f5 == 5'b00001 | id_amo_f5 == 5'b00000 |", "id_amo_f5 == 5'b00000 |")
m("giai ma: funct5 = 00101 (khong co) duoc nhan nhu amoxor", "id_amo_f5 == 5'b00100 |", "(id_amo_f5[4:3] == 2'b00 & id_amo_f5[1] == 1'b0) |")
m("ID/EX: AMO coi nhu khong co hazard (bo idex_amo khoi ldlike)", "idex_load | idex_amo | (idex_store & idex_atom);", "idex_load | (idex_store & idex_atom);")
m("ID/EX: SC khong la lenh nhan ket qua muon (bo khoi ldlike)", "idex_load | idex_amo | (idex_store & idex_atom);", "idex_load | idex_amo;")
m("ID/EX: AMO khong chuyen co amo xuong EX", "idex_amo_r     <= legal_amo & ifid_valid;", "idex_amo_r     <= 1'b0;")
m("misa: khong co bit A", "| ((A_EXT != 0) ? 32'h1 : 32'h0) |", "| 32'h0 |")
# ---- lech dia chi (EX) ----
m("lech: LR / SC / AMO lech khong trap khi offset = 1 (chi xet ea[1])", "idex_atom & (ea_lo != 2'b00);", "idex_atom & (ea_lo[1] != 1'b0);")
m("lech: LR / SC / AMO lech khong trap khi offset = 2 (chi xet ea[0])", "idex_atom & (ea_lo != 2'b00);", "idex_atom & (ea_lo[0] != 1'b0);")
m("lech: LR lech khong trap (khi phan cung xu ly lech)", "(idex_load & at_misal);", "1'b0;", "lat")
m("lech: AMO lech khong trap", "((idex_store | idex_amo) & at_misal);", "(idex_store & at_misal);")
m("lech: SC lech khong trap (khi phan cung xu ly lech)", "((idex_store | idex_amo) & at_misal);", "(idex_amo & at_misal);", "lat")
# ---- AMO: ALU va 2 pha ----
m("amoswap: ghi gia tri cu", "5'b00001: amo_new = exmem_store_val; ", "5'b00001: amo_new = amo_old;")
m("amoadd: tru thay vi cong", "amo_new = amo_old + exmem_store_val;", "amo_new = amo_old - exmem_store_val;")
m("amoxor: thanh or", "amo_new = amo_old ^ exmem_store_val;", "amo_new = amo_old | exmem_store_val;")
m("amoand: thanh or", "amo_new = amo_old & exmem_store_val;", "amo_new = amo_old | exmem_store_val;")
m("amoor: thanh xor", "amo_new = amo_old | exmem_store_val;                        // amoor", "amo_new = amo_old ^ exmem_store_val;                        // amoor")
m("amomin: so sanh khong dau", "5'b10000: amo_new = amo_lt  ?", "5'b10000: amo_new = amo_ltu ?")
m("amomax: lay nho", "5'b10100: amo_new = amo_lt  ? exmem_store_val : amo_old;", "5'b10100: amo_new = amo_lt  ? amo_old : exmem_store_val;")
m("amominu: so sanh co dau", "5'b11000: amo_new = amo_ltu ?", "5'b11000: amo_new = amo_lt  ?")
m("amomaxu: so sanh co dau", "default:  amo_new = amo_ltu ? exmem_store_val : amo_old;", "default:  amo_new = amo_lt  ? exmem_store_val : amo_old;")
m("AMO khong ghi bo nho", "(exmem_amo & amo_phase));", "1'b0);")
m("AMO ghi 2 lan (ca pha doc)", "(exmem_amo & amo_phase));", "exmem_amo);")
m("AMO khong doc o pha 0", "(exmem_valid & (exmem_load | (exmem_amo & ~amo_phase)))", "(exmem_valid & exmem_load)")
m("AMO xong sau pha 0 (khong ghi pha 1)", "& (~exmem_amo | amo_phase);", "& 1'b1;")
m("AMO tra gia tri moi cho rd thay vi gia tri cu", "exmem_amo ? amo_old :", "exmem_amo ? amo_new :")
m("AMO: pha doi khi dmem_ready chua len (khong cho)", "else if (exmem_valid & exmem_amo & dmem_ready) amo_phase <= ~amo_phase;", "else if (exmem_valid & exmem_amo) amo_phase <= ~amo_phase;", "lat")
# ---- LR / SC va dat cho ----
m("SC: thanh cong khong xet dia chi", "wire        sc_ok    = res_v & (res_a == exmem_result[31:2]);", "wire        sc_ok    = res_v;")
m("SC: thanh cong khong xet con dat cho", "wire        sc_ok    = res_v & (res_a == exmem_result[31:2]);", "wire        sc_ok    = (res_a == exmem_result[31:2]);")
m("SC: rd dao (0 khi that bai, 1 khi thanh cong)", "m_is_sc ? {31'b0, sc_fail} :", "m_is_sc ? {31'b0, ~sc_fail} :")
m("SC: that bai tra 2", "m_is_sc ? {31'b0, sc_fail} :", "m_is_sc ? {30'b0, sc_fail, 1'b0} :")
m("SC that bai van ghi bo nho", "((exmem_store & ~sc_fail) |", "(exmem_store |")
m("SC khong xoa dat cho (thanh cong roi SC tiep van thanh cong)", "else if (mem_done & m_is_sc)                         res_v <= 1'b0;", "else if (mem_done & m_is_sc)                         res_v <= res_v;")
m("SC that bai khong xoa dat cho cua LR cu", "else if (mem_done & m_is_sc)                         res_v <= 1'b0;", "else if (mem_done & m_is_sc & sc_ok)                 res_v <= 1'b0;")
m("LR khong dat cho", "else if (mem_done & m_is_lr)                         begin", "else if (1'b0)                                        begin")
m("LR dat sai dia chi (tu ke)", "begin res_v <= 1'b1; res_a <= exmem_result[31:2]; end", "begin res_v <= 1'b1; res_a <= exmem_result[31:2] + 30'd1; end")
m("trap khong xoa dat cho", "if (trap_q)                                          res_v <= 1'b0;", "if (1'b0)                                            res_v <= 1'b0;")
m("che do chat: store thuong khong xoa dat cho", "(res_a == exmem_result[31:2])) res_v <= 1'b0;", "(res_a != exmem_result[31:2])) res_v <= 1'b0;", "stclr")
m("che do chat: AMO khong xoa dat cho", "((exmem_store & ~m_atom) | exmem_amo) &", "((exmem_store & ~m_atom)) &", "stclr")
m("che do mac dinh: store thuong cung xoa dat cho (khac Spike)", "else if (A_ST_CLR != 0 & mem_done &", "else if (mem_done &")
M[:] = [x for x in M if x]


def run(rep, cfg, n):
    cmd = [sys.executable, os.path.join(rep, "verify", "run_verify.py"), "--pipem"] + CFG[cfg] + ["--stop-on-fail", "--n", str(n)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return True, "treo"
    out = r.stdout + r.stderr
    if "Bien dich RTL that bai" in out or "Traceback" in out:
        return None, out.strip()[-300:]
    first = next((l for l in out.splitlines() if l.strip()), "")
    return bool(r.returncode), first


def one(args):
    name, old, new, cfg, src, n = args
    if src.count(old) != 1:
        return name, cfg, None, f"chuoi goc xuat hien {src.count(old)} lan (can dung 1)"
    tmp = tempfile.mkdtemp(prefix="muta_")
    try:
        rep = os.path.join(tmp, "repo")
        shutil.copytree(ROOT, rep, ignore=shutil.ignore_patterns(".git", "eembc", "__pycache__", "*.vvp", "build_*"))
        open(os.path.join(rep, F), "w").write(src.replace(old, new, 1))
        k, d = run(rep, cfg, n)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return name, cfg, k, d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--jobs", type=int, default=2)
    a = ap.parse_args()
    src = open(os.path.join(ROOT, F)).read()
    muts = [x for x in M if a.only.lower() in x[0].lower()]
    killed, bad = 0, 0
    with ThreadPoolExecutor(a.jobs) as ex:
        for name, cfg, k, d in ex.map(one, [(nm, o, nw, c, src, a.n) for nm, o, nw, c in muts]):
            if k is None:
                bad += 1
                print(f"  LOI / BO QUA  [{cfg}] {name}: {d}", flush=True)
            elif k:
                killed += 1
                print(f"  BAT DUOC  [{cfg}] {name}", flush=True)
            else:
                bad += 1
                print(f"  BO SOT    [{cfg}] {name}", flush=True)
    print(f"A mutation: bat duoc {killed}/{len(muts)}" + (f", {bad} bo sot / loi" if bad else ""))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
