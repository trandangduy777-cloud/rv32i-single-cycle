#!/usr/bin/env python3
"""Mutation test cho phan ngat va WFI cua rv32im_pipeline.v: moi dot bien phai lam tb_irq.v bao FAIL (hoac het thoi gian).
Chay tu thu muc goc repo: python3 irq/mutate_irq.py"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")

# (ten, chuoi goc trong RTL, chuoi thay the)
MUTATIONS = [
    ("mepc tro lenh ke tiep (bo qua lenh bi ngat)",
     "tepc_q       <= idex_pc[31:1];", "tepc_q       <= idex_pc[31:1] + 31'd2;"),
    ("lenh bi ngat van ghi thanh ghi",
     "exmem_rd_we     <= idex_rd_we & ~ex_stall & ~trap_ex;",
     "exmem_rd_we     <= idex_rd_we & ~ex_stall & ~(trap_ex & ~irq_take);"),
    ("lenh bi ngat van ghi bo nho",
     "exmem_store     <= idex_store & ~ex_stall & ~trap_ex;",
     "exmem_store     <= idex_store & ~ex_stall & ~(trap_ex & ~irq_take);"),
    ("khong xoa MIE khi vao trap",
     "            mstatus_mie  <= 1'b0;\n        end else if (mret_ex)",
     "            mstatus_mie  <= mstatus_mie;\n        end else if (mret_ex)"),
    ("bo qua mstatus.MIE",
     "wire irq_any   = mstatus_mie & irq_pend;", "wire irq_any   = irq_pend;"),
    ("bo qua mie.MTIE",
     "wire irq_mtip  = mip_mtip & mie_mtie;", "wire irq_mtip  = mip_mtip;"),
    ("bo qua mie.MEIE",
     "wire irq_meip  = mip_meip & mie_meie;", "wire irq_meip  = mip_meip;"),
    ("bo qua mie.MSIE",
     "wire irq_msip  = mip_msip & mie_msie;", "wire irq_msip  = mip_msip;"),
    ("mcause thieu bit ngat",
     "mcause_r     <= {tint_q, 27'd0, tcause_q};", "mcause_r     <= {1'b0, 27'd0, tcause_q};"),
    ("dao uu tien ngoai / phan mem",
     "trap_cause = irq_meip ? 32'h8000_000B : (irq_msip ? 32'h8000_0003 : 32'h8000_0007);",
     "trap_cause = irq_msip ? 32'h8000_0003 : (irq_meip ? 32'h8000_000B : 32'h8000_0007);"),
    ("dao uu tien phan mem / timer",
     "trap_cause = irq_meip ? 32'h8000_000B : (irq_msip ? 32'h8000_0003 : 32'h8000_0007);",
     "trap_cause = irq_meip ? 32'h8000_000B : (irq_mtip ? 32'h8000_0007 : 32'h8000_0003);"),
    ("nhan ngat ca khi EX khong co lenh hop le",
     "wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~idex_wfi_r & ~frz;",
     "wire irq_take  = irq_any & ~idex_mext_r & ~idex_wfi_r & ~frz;"),
    ("MRET khong khoi phuc MIE",
     "mstatus_mie  <= mstatus_mpie;", "mstatus_mie  <= 1'b0;"),
    ("WFI khong dung (chay nhu NOP)",
     "assign wfi_wait = idex_wfi & ~irq_pend;", "assign wfi_wait = 1'b0;"),
    ("WFI thuc day khi co ngat dang cho du bi che boi mie",
     "assign wfi_wait = idex_wfi & ~irq_pend;", "assign wfi_wait = idex_wfi & ~(mip_mtip | mip_msip | mip_meip);"),
    ("ngat nhan tren chinh lenh WFI (mepc = WFI)",
     "wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~idex_wfi_r & ~frz;",
     "wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~frz;"),
]


def run(rtl_path, tmp):
    vvp = os.path.join(tmp, "irq.vvp")
    r = subprocess.run(["iverilog", "-g2012", "-o", vvp, os.path.join(HERE, "tb_irq.v"), rtl_path,
                        os.path.join(ROOT, "rv32i_core.v"), os.path.join(ROOT, "rv32_mtimer.v")],
                       capture_output=True, text=True)
    if r.returncode:
        return "LOI BIEN DICH"
    out = subprocess.run(["vvp", "-n", vvp, "+prog=" + os.path.join(HERE, "irq_test.hex")],
                         capture_output=True, text=True, timeout=300).stdout
    line = [l for l in out.splitlines() if l.startswith("[IRQ]")]
    return line[-1] if line else "KHONG CO KET QUA"


def main():
    src = open(os.path.join(ROOT, "rv32im_pipeline.v")).read()
    with tempfile.TemporaryDirectory() as tmp:
        base = run(os.path.join(ROOT, "rv32im_pipeline.v"), tmp)
        print("goc:", base)
        if "PASS" not in base:
            sys.exit(1)
        killed = 0
        for name, a, b in MUTATIONS:
            if src.count(a) != 1:
                print(f"  BO QUA  {name} (khong tim thay chuoi goc)")
                continue
            p = os.path.join(tmp, "rv32im_pipeline.v")
            open(p, "w").write(src.replace(a, b))
            res = run(p, tmp)
            ok = "PASS" not in res
            killed += ok
            print(f"  {'BAT' if ok else 'SOT'}  {name}: {res}")
        print(f"bat duoc {killed}/{len(MUTATIONS)} dot bien")
        sys.exit(0 if killed == len(MUTATIONS) else 1)


if __name__ == "__main__":
    main()
