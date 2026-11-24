#!/usr/bin/env python3
"""Mutation test cho so vet voi Spike khi co ngat (cosim/irq/run_irq_cosim.py --quick): moi dot bien trong phan ngat /
trap cua rv32im_pipeline.v phai bi bat (lech Spike, chuong trinh tu bao loi, RTL bo doi ngat, hoac treo).
Gom 16 dot bien cua irq/mutate_irq.py (testbench rieng tb_irq.v) va cac dot bien them chi lo ra khi so voi Spike.
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
     "wire [1:0]  ir_old    = {1'b0, exmem_valid & ~exmem_trap & exmem_icnt} + {1'b0, rt_inc & memwb_icnt};",
     "wire [1:0]  ir_old    = {1'b0, rt_inc & memwb_icnt};"),
    ("ghi minstret khong tru lenh cu hon con trong pipeline",
     "minstret_r <= cnt_new - {63'd0, exmem_valid & ~exmem_trap & exmem_icnt};", "minstret_r <= cnt_new;"),
    ("lenh ghi minstret van tu tang", "assign      cnt_icnt  = ~cnt_wr_ir & ~mcinh[2];",
     "assign      cnt_icnt  = ~mcinh[2];"),
    ("mcountinhibit.IR bi bo qua", "assign      cnt_icnt  = ~cnt_wr_ir & ~mcinh[2];",
     "assign      cnt_icnt  = ~cnt_wr_ir;"),
    ("lenh gay trap van duoc dem", "wire        rt_inc    = wb_commit & ~memwb_trap;",
     "wire        rt_inc    = wb_commit;"),
    ("minstret mat nho sang nua cao", "else if (rt_inc && memwb_icnt)  minstret_r <= minstret_r + 64'd1;",
     "else if (rt_inc && memwb_icnt)  minstret_r <= {minstret_r[63:32], minstret_r[31:0] + 32'd1};"),
    ("mcountinhibit.CY bi bo qua", "else if (!mcinh[0])             mcycle_r <= mcycle_r + 64'd1;",
     "else                            mcycle_r <= mcycle_r + 64'd1;"),
    ("su kien nhanh dem ca lenh khong phai nhanh", "assign hpm_evt[7]  = ex_upd & idex_branch;",
     "assign hpm_evt[7]  = ex_upd;"),
    ("misa thieu M", "12'h301: csr_rdata = 32'h4000_1100 |", "12'h301: csr_rdata = 32'h4000_0100 |"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    a = ap.parse_args()
    muts = list(mutate_irq.MUTATIONS) + EXTRA
    src = open(os.path.join(ROOT, F)).read()
    caught, t0 = 0, time.time()
    for k, (name, old, new) in enumerate(muts):
        if src.count(old) != 1:
            print(f"  [{k + 1}/{len(muts)}] BO QUA {name}: khong tim thay chuoi goc", flush=True)
            continue
        tmp = tempfile.mkdtemp(prefix="mutirq_")
        for f in ("rv32i_core.v", "rv32c_decompress.v", "rv32_mtimer.v", "rv32_icache.v", "rv32_dcache.v",
                  "rv32_bus_arbiter.v"):
            shutil.copy(os.path.join(ROOT, f), tmp)
        open(os.path.join(tmp, F), "w").write(src.replace(old, new))
        try:
            r = subprocess.run([sys.executable, os.path.join(HERE, "run_irq_cosim.py"), "--spike", a.spike, "--quick",
                                "--stop-on-fail", "--tmax", "3000000", "--rtl-dir", tmp], capture_output=True, text=True, timeout=3000)
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
