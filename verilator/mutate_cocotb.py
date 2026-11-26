#!/usr/bin/env python3
"""Mutation cho test cocotb: moi mutant sua 1 cho trong ban sao RTL (RV_ROOT tro toi ban sao, RTL goc khong dong toi);
test cocotb phai THAT BAI (scoreboard / assertion bat duoc). Chay KHONG co SVA (chi scoreboard cua testbench cocotb). Mutant song sot = diem yeu cua testbench. Dung: python3 verilator/mutate_cocotb.py [--only ten]"""
import argparse, glob, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
# (ten, file, cu, moi, test)
M = [
    ("dc_fwd_mask",   "rv32_dcache.v", "fill_data = (fill_data & ~fmask) | (q_data[fs] & fmask);", "fill_data = q_data[fs];", "dcache"),
    ("dc_no_fwd",     "rv32_dcache.v", "fill_data = (fill_data & ~fmask) | (q_data[fs] & fmask);", "fill_data = fill_data;", "dcache"),
    ("dc_hit_wmask",  "rv32_dcache.v", "<= (cdata & ~wmask) | (wdata & wmask);", "<= wdata;", "dcache"),
    ("dc_fence_wb",   "rv32_dcache.v", "(free & fence & wb_empty)", "(free & fence)", "dcache"),
    ("dc_drn_strb",   "rv32_dcache.v", "(state == DRN) ? q_strb[q_head] : 4'b1111", "4'b1111", "dcache"),
    ("dc_unc_rdata",  "rv32_dcache.v", "assign rdata = (state == UNC) ? m_rdata : cdata;", "assign rdata = cdata;", "dcache"),
    ("dc_q_order",    "rv32_dcache.v", "assign m_wdata = q_data[q_head];", "assign m_wdata = q_data[q_tail == 0 ? WBUF - 1 : q_tail - 1];", "dcache"),
    ("dc_fill_addr",  "rv32_dcache.v", "{w[29:WB], fill_cnt, 2'b00} :", "{w[29:WB], fill_cnt ^ {{(WB-1){1'b0}}, 1'b1}, 2'b00} :", "dcache"),
    ("arb_addr",      "rv32_bus_arbiter.v", "assign m_addr  = sel_d ? d_addr : i_addr;", "assign m_addr  = i_addr;", "bus"),
    ("arb_hold",      "rv32_bus_arbiter.v", "else if (m_ack)        own <= NONE;", "else if (m_ack & (own != OWN_I)) own <= NONE;", "bus"),
    ("ic_flush",      "rv32_icache.v", "            if (flush)\n", "            if (1'b0)\n", "bus"),
    ("ic_fillkill",   "rv32_icache.v", "val_r[fill_set * WAYS + fill_way] <= ~(fill_kill | flush);", "val_r[fill_set * WAYS + fill_way] <= 1'b1;", "bus"),
]


def run(name, f, old, new, test, tmp):
    d = os.path.join(tmp, name)
    os.makedirs(d)
    for v in glob.glob(os.path.join(REPO, "*.v")):
        shutil.copy(v, d)
    p = os.path.join(d, f)
    s = open(p).read()
    if old not in s:
        return "KHONG_TIM_THAY_CHO_SUA"
    open(p, "w").write(s.replace(old, new, 1))
    env = dict(os.environ, RV_ROOT=d, COCOTB_NO_SVA="1")
    r = subprocess.run([sys.executable, os.path.join(HERE, "run_cocotb.py"), "--tests", test, "--seeds", os.environ.get("MUT_SEEDS", "5"), "--nops", "1500", "--cfgs", "3" if test == "bus" else "2",
                        "--out", os.path.join(d, "out")], env=env, capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "COCOTB:" in out and r.returncode != 0:
        why = [l.strip() for l in out.splitlines() if "AssertionError" in l]
        return "BAT_DUOC: " + (why[0][:110] if why else "that bai")
    return "SONG_SOT" if r.returncode == 0 else "LOI_BUILD"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="mutcc_")
    bad = 0
    ctl = subprocess.run([sys.executable, os.path.join(HERE, "run_cocotb.py"), "--seeds", "1", "--nops", "800", "--cfgs", "2", "--out", os.path.join(tmp, "ctl")],
                         capture_output=True, text=True)
    print(f"{'DOI CHUNG (khong sua)':<16} {'dat' if ctl.returncode == 0 else 'LOI'}", flush=True)
    for name, f, old, new, test in M:
        if a.only and a.only != name:
            continue
        res = run(name, f, old, new, test, tmp)
        print(f"{name:<16} {res}", flush=True)
        if not res.startswith("BAT_DUOC"):
            bad += 1
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"COCOTB-MUTATION: {len(M) if not a.only else 1} mutant, {bad} khong bi bat")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
