#!/usr/bin/env python3
"""Mutation test cho so vet voi Spike khi co ngat (cosim/irq/run_irq_cosim.py --quick): moi dot bien trong phan ngat /
trap cua rv32im_pipeline.v phai bi bat (lech Spike, chuong trinh tu bao loi, RTL bo doi ngat, hoac treo).
Gom 16 dot bien cua irq/mutate_irq.py (testbench rieng tb_irq.v) va cac dot bien them chi lo ra khi so voi Spike
(ngat / trap, bo dem, PMP).
Dung (tu thu muc goc repo): python3 cosim/irq/mutate_irq_cosim.py [--spike /opt/spike/bin/spike]
"""
import argparse, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irq"))
import mutate_irq                  # noqa: E402

F = "rv32im_pipeline.v"
EXTRA = [
    ("mepc mat bit 1 (lenh nen o dia chi le 2 byte)",
     "wire [31:0] mepc_v = {mepc_r[31:2], mepc_r[1] & (ENABLE_C != 0), 1'b0};",
     "wire [31:0] mepc_v = {mepc_r[31:2], 2'b00};"),
    ("ngat nhan ca khi pipeline dong bang cho bo nho",
     "wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~idex_wfi_r & ~frz;",
     "wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~idex_wfi_r;"),
    ("lenh CSR bi ngat van ghi CSR",
     "wire csr_write = idex_csr & csr_we_req & ~irq_take & ~frz;",
     "wire csr_write = idex_csr & csr_we_req & ~frz;"),
    ("MPIE khong luu MIE khi vao trap",
     "            mstatus_mpie <= mstatus_mie;", "            mstatus_mpie <= 1'b1;"),
    ("ngat timer bao nham la ngat phan mem",
     "trap_cause = irq_meip ? 32'h8000_000B : (irq_msip ? 32'h8000_0003 : 32'h8000_0007);",
     "trap_cause = irq_meip ? 32'h8000_000B : 32'h8000_0003;"),
    ("mtvec vectored: khong cong ma nguyen nhan",
     "wire [31:2] trap_base  = (irq_take & mtvec_vec) ? mtvec_r + {26'd0, trap_cause[3:0]} : mtvec_r;",
     "wire [31:2] trap_base  = mtvec_r;"),
    ("mtvec vectored: exception cung nhay theo ma nguyen nhan",
     "wire [31:2] trap_base  = (irq_take & mtvec_vec) ? mtvec_r + {26'd0, trap_cause[3:0]} : mtvec_r;",
     "wire [31:2] trap_base  = mtvec_vec ? mtvec_r + {26'd0, trap_cause[3:0]} : mtvec_r;"),
    # ---- bo dem Zicntr / Zihpm (cosim/irq/counters.S) ----
    ("minstret doc o EX quen lenh cu hon o MEM",
     "wire [1:0]  ir_old    = {1'b0, exmem_valid & ~exmem_trap & exmem_icnt} + {1'b0, ir_wb};",
     "wire [1:0]  ir_old    = {1'b0, ir_wb};"),
    ("ghi minstret: lenh cu hon o MEM van tang them (dem 2 lan)",
     "memwb_skip  <= cnt_wr_ir;", "memwb_skip  <= 1'b0;"),
    ("ghi minstret: bo qua lenh cu hon o MEM (khong dem)",
     "            if (cnt_wr_ir)                  minstret_r <= cnt_new;",
     "            if (cnt_wr_ir)                  minstret_r <= cnt_new - {63'd0, exmem_valid & ~exmem_trap & exmem_icnt};"),
    ("chon san minstret + 2 sai (MEM va WB cung dem)",
     "wire [63:0] ir_p2     = minstret_r + 64'd2;", "wire [63:0] ir_p2     = minstret_r + 64'd1;"),
    ("lenh ghi minstret van tu tang", "assign      cnt_icnt  = ~cnt_wr_ir & ~mcinh[2];",
     "assign      cnt_icnt  = ~mcinh[2];"),
    ("mcountinhibit.IR bi bo qua", "assign      cnt_icnt  = ~cnt_wr_ir & ~mcinh[2];",
     "assign      cnt_icnt  = ~cnt_wr_ir;"),
    ("lenh gay trap van duoc dem", "wire        rt_inc    = wb_commit & ~memwb_trap;",
     "wire        rt_inc    = wb_commit;"),
    ("minstret mat nho sang nua cao", "else if (ir_wb)                 minstret_r <= ir_p1;",
     "else if (rt_inc && memwb_icnt)  minstret_r <= {minstret_r[63:32], minstret_r[31:0] + 32'd1};"),
    ("mcountinhibit.CY bi bo qua", "else if (!mcinh[0])             mcycle_r <= mcycle_r + 64'd1;",
     "else                            mcycle_r <= mcycle_r + 64'd1;"),
    ("su kien nhanh dem ca lenh khong phai nhanh", "assign hpm_evt[7]  = ex_upd & idex_branch;",
     "assign hpm_evt[7]  = ex_upd;"),
    ("misa thieu M", "12'h301: csr_rdata = 32'h4000_1100 |", "12'h301: csr_rdata = 32'h4000_0100 |"),
]
# PMP (cosim/irq/pmp.S): chi chay chuong trinh pmp tren ca 6 cau hinh loi (co loi lech phan cung cho phan -DMA)
PMP = ["--only", "pmp", "--seeds", "1", "--tmax", "100000"]   # pmp.S chay < 5000 chu ky; dot bien lam vong trap thi dung som
EXTRA += [(n, o, w, PMP) for n, o, w in [
    ("muc khoa khong rang buoc che do M", "~{3{pmp_cfg[gk][7]}} | pmp_cfg[gk][2:0];", "3'b111 | pmp_cfg[gk][2:0];"),
    ("muc khong khoa van rang buoc che do M", "~{3{pmp_cfg[gk][7]}} | pmp_cfg[gk][2:0];", "pmp_cfg[gk][2:0];"),
    ("bo qua muc khop co so nho nhat", "assign pmp_oh_f[ga * PN +: PN] = mm & (~mm + 1'b1);",
     "assign pmp_oh_f[ga * PN +: PN] = mm ^ (mm & (~mm + 1'b1));"),
    ("so sanh TOR gom can tren, bo can duoi", "assign pmp_lt_f[ga * PN + gk] = W < pmp_addr[gk];",
     "assign pmp_lt_f[ga * PN + gk] = W <= pmp_addr[gk];"),
    ("TOR khong dung can duoi", "(lo_ok & pmp_lt_f[ga * PN + gk])", "(pmp_lt_f[ga * PN + gk])"),
    ("NAPOT hieu nhu NA4", "assign pmp_mk[gk] = pmp_cfg[gk][3] ? pmp_addr[gk] ^ (pmp_addr[gk] + 32'd1) : 32'd0;",
     "assign pmp_mk[gk] = 32'd0;"),
    ("NAPOT mat bit thap nhat cua mat na", "assign pmp_mk[gk] = pmp_cfg[gk][3] ? pmp_addr[gk] ^ (pmp_addr[gk] + 32'd1) : 32'd0;",
     "assign pmp_mk[gk] = pmp_cfg[gk][3] ? (pmp_addr[gk] ^ (pmp_addr[gk] + 32'd1)) >> 1 : 32'd0;"),
    ("NA4 dung mat na NAPOT", "assign pmp_mk[gk] = pmp_cfg[gk][3] ? pmp_addr[gk] ^ (pmp_addr[gk] + 32'd1) : 32'd0;",
     "assign pmp_mk[gk] = pmp_addr[gk] ^ (pmp_addr[gk] + 32'd1);"),
    ("khop mot phan van duoc phep", "wire        ls_same = (|pmp_m2) & (|pmp_m3) & (pmp_oh2 == pmp_oh3);",
     "wire        ls_same = 1'b1;"),
    ("load / store lech chi kiem tu dau", "wire [29:0] pmp_w3 = ls_end[31:2];", "wire [29:0] pmp_w3 = ea[31:2];"),
    ("store kiem quyen R thay vi W", "~(ls_same & |(pmp_oh2 & pmp_okw));", "~(ls_same & |(pmp_oh2 & pmp_okr));"),
    ("fetch khong kiem nua sau lenh 32 bit",
     "wire        if_f2   = (ENABLE_C != 0) & ~idex_c & idex_pc[1] & (|pmp_m1) & ~|(pmp_oh1 & pmp_okx);",
     "wire        if_f2   = 1'b0;"),
    ("mtval cua fetch luon la pc", "assign pmp_itval  = if_f1 ? idex_pc : if_p2;", "assign pmp_itval  = idex_pc;"),
    ("fetch bi cam khong gay trap", "assign pmp_ifault = (PMP_N != 0) & idex_valid & ~irq_take & (if_f1 | if_f2);",
     "assign pmp_ifault = 1'b0;"),
    ("load bi cam bao nham ma store", "else if (pmp_lfault)    begin trap_cause = 32'd5;",
     "else if (pmp_lfault)    begin trap_cause = 32'd7;"),
    ("khoa khong chan ghi pmpcfg", "if (csr_addr == 12'h3A0 + pw / 4 && !pmp_cfg[pw][7]) begin",
     "if (csr_addr == 12'h3A0 + pw / 4) begin"),
    ("khoa khong chan ghi pmpaddr", "if (csr_addr == 12'h3B0 + pw && !pmp_cfg[pw][7] &&",
     "if (csr_addr == 12'h3B0 + pw &&"),
    ("muc TOR khoa khong bao ve pmpaddr muc truoc", "!(pw + 1 < PMP_N && pmp_cfg[(pw + 1 < PMP_N) ? pw + 1 : pw][7] &&",
     "!(1'b0 && pmp_cfg[(pw + 1 < PMP_N) ? pw + 1 : pw][7] &&"),
    ("R = 0 khong xoa W", "if (!pmp_wcfg[0]) pmp_wcfg[1] = 1'b0;", "if (1'b0) pmp_wcfg[1] = 1'b0;"),
    ("bit 5-6 cua pmpcfg ghi duoc", "pmp_wcfg = csr_new[8 * (pw % 4) +: 8] & 8'h9F;",
     "pmp_wcfg = csr_new[8 * (pw % 4) +: 8];"),
]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    ap.add_argument("--pmp", action="store_true", help="chi chay cac dot bien PMP")
    ap.add_argument("--range", default="", help="a:b = chi chay dot bien thu a..b-1 (chia lan chay dai)")
    a = ap.parse_args()
    muts = list(mutate_irq.MUTATIONS) + EXTRA
    if a.pmp:
        muts = [m for m in muts if len(m) > 3 and m[3] is PMP]
    if a.range:
        lo, hi = (int(x) if x else None for x in a.range.split(":"))
        muts = muts[lo:hi]
    src = open(os.path.join(ROOT, F)).read()
    caught, t0 = 0, time.time()
    for k, (name, old, new, *args) in enumerate(muts):
        args = args[0] if args else ["--quick"]
        if src.count(old) != 1:
            print(f"  [{k + 1}/{len(muts)}] BO QUA {name}: khong tim thay chuoi goc", flush=True)
            continue
        tmp = tempfile.mkdtemp(prefix="mutirq_")
        for f in ("rv32i_core.v", "rv32c_decompress.v", "rv32_mtimer.v", "rv32_icache.v", "rv32_dcache.v",
                  "rv32_bus_arbiter.v"):
            shutil.copy(os.path.join(ROOT, f), tmp)
        open(os.path.join(tmp, F), "w").write(src.replace(old, new))
        try:
            r = subprocess.run([sys.executable, os.path.join(HERE, "run_irq_cosim.py"), "--spike", a.spike] + args + [
                                "--stop-on-fail", "--rtl-dir", tmp] + ([] if "--tmax" in args else ["--tmax", "3000000"]), capture_output=True, text=True, timeout=3000)
            out = r.stdout + r.stderr
            ok = r.returncode != 0
            why = next((l for l in out.splitlines() if "FAIL" in l), out.strip().splitlines()[-1] if out.strip() else "")
            if "Traceback" in out:
                ok, why = False, "loi script: " + out.strip().splitlines()[-1]
        except subprocess.TimeoutExpired:
            ok, why = True, "treo"
        caught += ok
        print(f"  [{k + 1}/{len(muts)}] {'BAT' if ok else 'SOT'}  {name}: {why[:150]} ({time.time() - t0:.0f} s)",
              flush=True)
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"bat duoc {caught}/{len(muts)} dot bien")
    sys.exit(0 if caught == len(muts) else 1)


if __name__ == "__main__":
    main()
