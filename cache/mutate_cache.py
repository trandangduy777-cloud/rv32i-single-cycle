#!/usr/bin/env python3
"""Mutation test cho cache va co che dong bang pipeline: moi dot bien phai bi bo kiem chung tuong ung bat duoc.

- Dot bien trong rv32_icache.v / rv32_dcache.v / rv32_bus_arbiter.v: chay cache/tb_cache_random.v (2 cau hinh cache,
  3 seed moi cau hinh, do tre 1..6). Phai co it nhat 1 lan bao FAIL hoac het thoi gian.
- Dot bien trong rv32im_pipeline.v (bat tay bo nho, dong bang), 2 bo kiem chung:
  "cosim": cosim/run_cosim.py voi 2 cau hinh co cache tren bench va bench_m (co va khong co lenh nen);
  "rand":  verify/run_verify.py --pipem --cache (40 chuong trinh ngau nhien co CSR, trap, MRET... qua cache 2 x 2,
           bo nho tre 1..6), so voi ISS Python. Phai co it nhat 1 chuong trinh lech hoac treo.

Moi dot bien chay tren mot ban sao cua repo trong thu muc tam.
Dung (tu thu muc goc repo): python3 cache/mutate_cache.py <thu_muc_riscv-tests> [--spike <duong dan spike>]
"""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (ten, file, chuoi goc, chuoi thay the, bo kiem chung)
MUTATIONS = [
    # ---- cache lenh ----
    ("icache: khong so tag", "rv32_icache.v",
     "wire hit0 = val_r[i0] & (tag_r[i0] == t0);", "wire hit0 = val_r[i0];", "tb"),
    ("icache: bo qua tu thu hai khi addr[1] = 1", "rv32_icache.v",
     "assign ready = (state == IDLE) & hit0 & (~need1 | hit1);", "assign ready = (state == IDLE) & hit0;", "tb"),
    ("icache: cua so lenh nen lay sai nua tu", "rv32_icache.v",
     "assign data  = need1 ? {d1[15:0], d0[31:16]} : d0;", "assign data  = need1 ? {d0[15:0], d1[31:16]} : d0;", "tb"),
    ("icache: flush khi dang nap van danh dau valid", "rv32_icache.v",
     "<= ~(fill_kill | flush);", "<= 1'b1;", "tb"),
    ("icache: nap sai thu tu tu trong dong", "rv32_icache.v",
     "mem_r[{fill_line[IB+WB-1:WB], fill_cnt}] <= m_rdata;",
     "mem_r[{fill_line[IB+WB-1:WB], ~fill_cnt}] <= m_rdata;", "tb"),
    # ---- cache du lieu ----
    ("dcache: khong so tag", "rv32_dcache.v",
     "wire          hit = cacheable & val_r[idx] & (tag_r[idx] == tg);",
     "wire          hit = cacheable & val_r[idx];", "tb"),
    ("dcache: store trung cache khong cap nhat dong", "rv32_dcache.v",
     "if (hit) mem_r[w[IB+WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);", ";", "tb"),
    ("dcache: store cap nhat ca tu, bo qua wstrb", "rv32_dcache.v",
     "if (hit) mem_r[w[IB+WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);",
     "if (hit) mem_r[w[IB+WB-1:0]] <= wdata;", "tb"),
    ("dcache: vung khong cacheable van luu cache", "rv32_dcache.v",
     "wire          cacheable = ((addr & CMASK) == CBASE);", "wire          cacheable = 1'b1;", "tb"),
    ("dcache: bus ghi khong theo wstrb", "rv32_dcache.v",
     "assign m_wstrb = (state == WR) ? wstrb : 4'b1111;", "assign m_wstrb = 4'b1111;", "tb"),
    # ---- bo phan xu ----
    ("arbiter: khong giu quyen bus toi khi ack", "rv32_bus_arbiter.v",
     "wire sel_d = (own == OWN_D) | ((own == NONE) & d_req);", "wire sel_d = d_req;", "tb"),
    # ---- pipeline: bat tay bo nho ----
    ("pipeline: khong dong bang khi load cho bo nho", "rv32im_pipeline.v",
     "assign frz        = (dmem_we | dmem_re) & ~dmem_ready;", "assign frz        = dmem_we & ~dmem_ready;", "cosim"),
    ("pipeline: bo qua imem_ready", "rv32im_pipeline.v",
     "end else if (!imem_ready) begin", "end else if (1'b0) begin", "cosim"),
    ("pipeline: wb_commit lap lai trong luc dong bang", "rv32im_pipeline.v",
     "        end else if (frz) begin\n            memwb_new   <= 1'b0;",
     "        end else if (frz) begin\n            memwb_new   <= memwb_new;", "cosim"),
    ("pipeline: IF/ID nhan lenh moi khi dong bang", "rv32im_pipeline.v",
     "        if (!(stall | ex_stall | frz)) begin\n            ifid_pc    <= pc;",
     "        if (!(stall | ex_stall)) begin\n            ifid_pc    <= pc;", "rand"),
    ("pipeline: truong du lieu ID/EX doi khi dong bang", "rv32im_pipeline.v",
     "    always @(posedge clk) begin\n        if (!(ex_stall | frz)) begin",
     "    always @(posedge clk) begin\n        if (!ex_stall) begin", "rand"),
    ("pipeline: ghi CSR ca khi dong bang", "rv32im_pipeline.v",
     "wire csr_write = idex_csr & csr_we_req & ~irq_take & ~frz;",
     "wire csr_write = idex_csr & csr_we_req & ~irq_take;", "rand"),
    ("pipeline: trap ghi mepc/mcause ca khi dong bang", "rv32im_pipeline.v",
     "        else        trap_q <= trap_ex & ~frz;", "        else        trap_q <= trap_ex;", "rand"),
    ("pipeline: MRET chay ca khi dong bang", "rv32im_pipeline.v",
     "wire mret_ex = idex_mret & ~irq_take & ~frz;", "wire mret_ex = idex_mret & ~irq_take;", "rand"),
    ("pipeline: EX/MEM van chay khi dong bang", "rv32im_pipeline.v",
     "        end else if (!frz) begin\n            exmem_valid     <= idex_valid & ~ex_stall;",
     "        end else begin\n            exmem_valid     <= idex_valid & ~ex_stall;", "cosim"),
]

TB_CFGS = [["-DL=4", "-DW=2"], ["-DL=2", "-DW=8"]]


def run_tb(rep):
    for cfg in TB_CFGS:
        vvp = os.path.join(rep, "cr.vvp")
        r = subprocess.run(["iverilog", "-g2012"] + cfg + ["-o", vvp, os.path.join(rep, "cache", "tb_cache_random.v")] +
                           [os.path.join(rep, f) for f in ("rv32_icache.v", "rv32_dcache.v", "rv32_bus_arbiter.v")],
                           capture_output=True, text=True)
        if r.returncode:
            return None, "loi bien dich"
        for seed in (1, 2, 3):
            try:
                out = subprocess.run(["vvp", "-n", vvp, f"+seed={seed}", "+n=5000", "+lat=6"],
                                     capture_output=True, text=True, timeout=300).stdout
            except subprocess.TimeoutExpired:
                return True, f"treo ({' '.join(cfg)}, seed {seed})"
            line = next((l for l in out.splitlines() if l.startswith("[CACHE]")), "khong co ket qua")
            if "PASS" not in line:
                return True, f"{' '.join(cfg)} seed {seed}: {line}"
    return False, "tb_cache_random PASS"


def run_cosim(rep, a):
    try:
        r = subprocess.run([sys.executable, os.path.join(rep, "cosim", "run_cosim.py"), a.riscv_tests, "--spike",
                            a.spike, "--only=bench", "--core=cache", "--stop-on-fail"],
                           capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return True, "treo"
    out = r.stdout + r.stderr
    if "loi bien dich" in out or "Traceback" in out:
        return None, out.strip()[-200:]
    fail = next((l for l in out.splitlines() if l.startswith("FAIL")), None)
    return (True, fail) if r.returncode and fail else (False, "cosim PASS")


def run_rand(rep):
    try:
        r = subprocess.run([sys.executable, os.path.join(rep, "verify", "run_verify.py"), "--pipem", "--cache",
                            "--n", "40"], capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return True, "treo"
    out = r.stdout + r.stderr
    if "Bien dich RTL that bai" in out or "Traceback" in out:
        return None, out.strip()[-200:]
    first = out.splitlines()[0] if out else ""
    return (True, first) if r.returncode else (False, first)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("riscv_tests")
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    ap.add_argument("--kind", choices=["tb", "cosim", "rand", "all"], default="all", help="chi chay mot nhom dot bien")
    a = ap.parse_args()
    killed, bad = 0, 0
    muts = [m for m in MUTATIONS if a.kind in ("all", m[4])]
    for name, fn, old, new, how in muts:
        src = open(os.path.join(ROOT, fn)).read()
        if src.count(old) != 1:
            print(f"  BO QUA  {name}: khong tim thay chuoi goc", flush=True)
            bad += 1
            continue
        tmp = tempfile.mkdtemp(prefix="mutc_")
        rep = os.path.join(tmp, "repo")
        shutil.copytree(ROOT, rep, ignore=shutil.ignore_patterns(".git", "results", "*.vcd", "*.vvp"))
        open(os.path.join(rep, fn), "w").write(src.replace(old, new))
        caught, detail = run_tb(rep) if how == "tb" else (run_cosim(rep, a) if how == "cosim" else run_rand(rep))
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
