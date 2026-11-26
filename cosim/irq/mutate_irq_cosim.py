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
     "wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~idex_wfi_r & ~frz & ~dwait;",
     "wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~idex_wfi_r & ~dwait;"),
    ("lenh CSR bi ngat van ghi CSR",
     "wire csr_write = idex_csr & csr_we_req & ~irq_take & ~frz & ~ex_priv_ill;",
     "wire csr_write = idex_csr & csr_we_req & ~frz & ~ex_priv_ill;"),
    ("MPIE khong luu MIE khi vao trap",
     "            mstatus_mpie <= mstatus_mie;", "            mstatus_mpie <= 1'b1;"),
    ("ngat timer bao nham la ngat phan mem",
     "cm_mti ? 4'd7 : cm_sei", "cm_mti ? 4'd3 : cm_sei"),
    ("mtvec vectored: khong cong ma nguyen nhan",
     "wire [31:2] trap_base  = (rt_int & tvec_v) ? tvec_b + {26'd0, rt_cause[3:0]} : tvec_b;",
     "wire [31:2] trap_base  = tvec_b;"),
    ("mtvec vectored: exception cung nhay theo ma nguyen nhan",
     "wire [31:2] trap_base  = (rt_int & tvec_v) ? tvec_b + {26'd0, rt_cause[3:0]} : tvec_b;",
     "wire [31:2] trap_base  = tvec_v ? tvec_b + {26'd0, rt_cause[3:0]} : tvec_b;"),
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
    ("store kiem quyen R thay vi W", "~(ls_same & |(pmp_oh2 & okw_d))", "~(ls_same & |(pmp_oh2 & okr_d))"),
    ("fetch khong kiem nua sau lenh 32 bit",
     "wire        if_f2   = (ENABLE_C != 0) & ~idex_c & idex_pc[1] & ((|pmp_m1) ? ~|(pmp_oh1 & okx_i) : ~pm_i);",
     "wire        if_f2   = 1'b0;"),
    ("mtval cua fetch luon la pc", "assign pmp_itval  = if_f1 ? idex_pc : if_p2;", "assign pmp_itval  = idex_pc;"),
    ("fetch bi cam khong gay trap", "assign pmp_ifault = (PMP_N != 0) & idex_valid & ~irq_take & (if_f1 | if_f2);",
     "assign pmp_ifault = 1'b0;"),
    ("load bi cam bao nham ma store", "else if (pmp_lfault) trap_cause = 32'd5;",
     "else if (pmp_lfault) trap_cause = 32'd7;"),
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


# Che do S / U (cosim/irq/su.S, riscv-tests rv32si / rv32mi): loi RV32IMC + S/U
SUM = ["--only", "su-,rv32si,rv32mi", "--core", "6", "--seeds", "1", "--tmax", "300000"]
EXTRA += [(n, o, w, SUM) for n, o, w in [
    ("ECALL luon bao ma 11", "trap_cause = {28'd0, 2'b10, priv};", "trap_cause = 32'd11;"),
    ("khong kiem cap CSR theo che do", "((csr_addr[9:8] > priv) | (cnt_user & ~cnt_en) |", "(1'b0 | (cnt_user & ~cnt_en) |"),
    ("mcounteren / scounteren bi bo qua", "((csr_addr[9:8] > priv) | (cnt_user & ~cnt_en) |", "((csr_addr[9:8] > priv) |"),
    ("scounteren bi bo qua o U", "((priv == 2'd1) | scounteren[csr_addr[4:0]])", "(1'b1)"),
    ("MRET duoc phep o S / U", "(idex_mret & (priv != 2'd3))", "(1'b0)"),
    ("TSR bi bo qua", "((priv == 2'd0) | ((priv == 2'd1) & st_tsr))", "((priv == 2'd0))"),
    ("WFI duoc phep o U", "(idex_wfi & ((priv == 2'd0) | ((priv != 2'd3) & st_tw)))", "(idex_wfi & (((priv != 2'd3) & st_tw)))"),
    ("TW bi bo qua", "(idex_wfi & ((priv == 2'd0) | ((priv != 2'd3) & st_tw)))", "(idex_wfi & ((priv == 2'd0)))"),
    ("medeleg bi bo qua", "wire exc_deleg = (rt_priv != 2'd3) & medeleg_v[rt_cause];", "wire exc_deleg = 1'b0;"),
    ("uy quyen ca exception xay ra o M", "wire exc_deleg = (rt_priv != 2'd3) & medeleg_v[rt_cause];",
     "wire exc_deleg = medeleg_v[rt_cause];"),
    ("ngat S uy quyen van ve M", "wire rt_s      = (SU != 0) & (rt_int ? ~rt_irqm : exc_deleg);",
     "wire rt_s      = (SU != 0) & (rt_int ? 1'b0 : exc_deleg);"),
    ("ngat M o U van can MIE", "wire m_en   = (priv != 2'd3) | mstatus_mie;", "wire m_en   = mstatus_mie;"),
    ("ngat S o U van can SIE", "wire s_en   = (priv == 2'd0) | ((priv == 2'd1) & st_sie);", "wire s_en   = (priv == 2'd1) & st_sie;"),
    ("ngat S uy quyen nhan ca o M khi SIE", "wire s_en   = (priv == 2'd0) | ((priv == 2'd1) & st_sie);",
     "wire s_en   = (priv == 2'd0) | st_sie;"),
    ("uu tien SSI truoc SEI", ": (cs_sei ? 4'd9 : cs_ssi ? 4'd1 : 4'd5);", ": (cs_ssi ? 4'd1 : cs_sei ? 4'd9 : 4'd5);"),
    ("stvec vectored bi bo qua", "wire        tvec_v     = rt_s ? stvec_vec : mtvec_vec;",
     "wire        tvec_v     = rt_s ? 1'b0 : mtvec_vec;"),
    ("trap ve S khong luu SPP", "st_spp       <= tpriv_q[0];", "st_spp       <= 1'b1;"),
    ("trap ve M khong luu MPP", "st_mpp       <= tpriv_q;", "st_mpp       <= 2'd3;"),
    ("SRET khong tra ve che do SPP", "priv_r       <= {1'b0, st_spp};", "priv_r       <= 2'd1;"),
    ("MRET khong dat MPP ve U", "st_mpp       <= 2'd0;                           // MPP ve", "st_mpp       <= st_mpp;  // MPP ve"),
    ("MRET ve U khong xoa MPRV", "if (st_mpp != 2'd3) st_mprv <= 1'b0;", "if (1'b0) st_mprv <= 1'b0;"),
    ("MPRV bi bo qua (PMP)", "wire        pm_d    = ((SU != 0) & st_mprv) ? (st_mpp == 2'd3) : pm_i;",
     "wire        pm_d    = pm_i;"),
    ("PMP: S / U khong khop muc nao van duoc fetch", "wire        if_f1   = (|pmp_m0) ? ~|(pmp_oh0 & okx_i) : ~pm_i;",
     "wire        if_f1   = (|pmp_m0) ? ~|(pmp_oh0 & okx_i) : 1'b0;"),
    ("PMP: muc khong khoa khong rang buoc U", "wire [PN-1:0] okr_d = pm_d ? pmp_okr : pmp_pr;",
     "wire [PN-1:0] okr_d = pmp_okr;"),
    ("MPP = 2 khong ve U", "(csr_new[12:11] == 2'd2) ? 2'd0 : csr_new[12:11]", "csr_new[12:11]"),
    ("SD khong theo FS", "wire        st_sd = (st_fs == 2'b11);", "wire        st_sd = 1'b0;"),
    ("sie ghi ca bit khong uy quyen", "if (mideleg_ssi) mie_ssie <= csr_new[1];", "mie_ssie <= csr_new[1];"),
    ("sip ghi SSIP khi khong uy quyen", "12'h144: if (mideleg_ssi) mip_ssip <= csr_new[1];", "12'h144: mip_ssip <= csr_new[1];"),
    ("medeleg bit 0 ghi duoc khi co C", "csr_new[0] & (ENABLE_C == 0)", "csr_new[0]"),
    ("misa thieu S / U", "((SU != 0) ? 32'h0014_0000 : 32'h0)", "((SU != 0) ? 32'h0 : 32'h0)"),
]]


# MMU Sv32 (cosim/irq/mmu.S, rv32si-dirty, rv32ui-v-*): loi RV32IMC + S/U + MMU (so 6); file rv32_mmu.v dung "M:" o dau ten
MMUA = ["--only", "mmu-,rv32si-dirty,rv32ui-v-add,rv32ui-v-lw,rv32ui-v-sw,rv32ui-v-jalr", "--core", "6", "--seeds", "1",
        "--tmax", "3000000"]
EXTRA += [(n, o, w, MMUA) for n, o, w in [
    ("trang lon tinh dia chi nhu trang 4 KiB (fetch)", "ipa = ipa | (t_sp[j] ? {t_ppn[j][21:10], i_va[21:0]} : {t_ppn[j], i_va[11:0]});",
     "ipa = ipa | {t_ppn[j], i_va[11:0]};"),
    ("trang lon tinh dia chi nhu trang 4 KiB (du lieu)", "dpa = dpa | (t_sp[j] ? {t_ppn[j][21:10], d_va[21:0]} : {t_ppn[j], d_va[11:0]});",
     "dpa = dpa | {t_ppn[j], d_va[11:0]};"),
    ("PTE tro bang co U / A / D van duoc", "if (table_ && st == S_L1 && !(pte[7] | pte[6] | pte[4])) begin",
     "if (table_ && st == S_L1) begin"),
    ("trang lon lech khong loi", "(st == S_L1 && pte[19:10] != 10'd0)", "(1'b0)"),
    ("PTE W khong R van duoc", "wire        bad_leaf  = ~pv | (pw & ~pr);", "wire        bad_leaf  = ~pv;"),
    ("PTE V = 0 van duoc", "wire        bad_leaf  = ~pv | (pw & ~pr);", "wire        bad_leaf  = (pw & ~pr);"),
    ("PMP khong kiem dia chi PTE", "wire        ad_ok = (m_addr[33:32] == 2'b00) & pte_ok;", "wire        ad_ok = (m_addr[33:32] == 2'b00);"),
    ("U doc duoc trang khong U", "((pd == 2'd1) ? (d_fl[3] & ~sum_v) : ~d_fl[3])", "((pd == 2'd1) ? (d_fl[3] & ~sum_v) : 1'b0)"),
    ("SUM bi bo qua", "((pd == 2'd1) ? (d_fl[3] & ~sum_v) : ~d_fl[3])", "((pd == 2'd1) ? (d_fl[3]) : ~d_fl[3])"),
    ("MXR bi bo qua", "~(d_fl[0] | (mxr_v & d_fl[2]))", "~(d_fl[0])"),
    ("A = 0 khong loi (du lieu)", "~d_fl[4] | (idex_store & ~d_fl[5])", "(idex_store & ~d_fl[5])"),
    ("store voi D = 0 khong loi", "~d_fl[4] | (idex_store & ~d_fl[5])", "~d_fl[4]"),
    ("store khong can W", "(idex_store ? ~d_fl[1] :", "(idex_store ? 1'b0 :"),
    ("S chay duoc trang U", "((priv == 2'd1) ? i_fl[3] : ~i_fl[3])", "((priv == 2'd1) ? 1'b0 : ~i_fl[3])"),
    ("fetch khong can X", "wire        i_bad  = ~i_fl[2] | ~i_fl[4] |", "wire        i_bad  = ~i_fl[4] |"),
    ("dia chi vat ly >= 2^32 khong loi (du lieu)", "(d_hit & ~d_bad & (d_pa[33:32] != 2'b00))", "(1'b0)"),
    ("loi nua sau lenh vat trang: mtval = pc", "trap_tval = idex_ipf2 ? idex_pc + 32'd2 : idex_pc; end",
     "trap_tval = idex_pc; end"),
    ("khong lay rieng nua sau lenh vat trang", "wire        spl_start = (ENABLE_C != 0) & (MMU != 0) & xi & ~spl_q & i_hit & ~if_tfault &",
     "wire        spl_start = 1'b0 & ~spl_q & i_hit & ~if_tfault &"),
    ("SFENCE.VMA khong xoa TLB", "assign mmu_flush = sfence_ex | satp_wr;", "assign mmu_flush = satp_wr;"),
    ("MPRV bi bo qua khi dich dia chi", "wire [1:0]  pd = ((SU != 0) & st_mprv) ? st_mpp : priv;", "wire [1:0]  pd = priv;"),
    ("medeleg khong uy quyen duoc loi trang", "medeleg_pf <= {csr_new[15], csr_new[13], csr_new[12]};", "medeleg_pf <= 3'b0;"),
    ("loi truy cap khi duyet bao thanh loi trang", "dfr_v <= 1'b1; dfr_va <= wk_va; dfr_af <= mmu_af;",
     "dfr_v <= 1'b1; dfr_va <= wk_va; dfr_af <= 1'b0;"),
    ("TVM bi bo qua (satp)", "((csr_addr == 12'h180) & (priv == 2'd1) & tvm_v)", "(1'b0)"),
    ("SFENCE.VMA duoc phep o U", "(idex_sfence & ((priv == 2'd0) | ((priv == 2'd1) & tvm_v)))",
     "(idex_sfence & (((priv == 2'd1) & tvm_v)))"),
    ("toan hang load / store khong chot khi cho duyet", "            idex_rs1_val <= op_a;\n            idex_rs2_val <= op_b;",
     "            idex_rs1_val <= idex_rs1_val;\n            idex_rs2_val <= idex_rs2_val;"),
]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    ap.add_argument("--pmp", action="store_true", help="chi chay cac dot bien PMP")
    ap.add_argument("--su", action="store_true", help="chi chay cac dot bien che do S / U")
    ap.add_argument("--mmu", action="store_true", help="chi chay cac dot bien MMU")
    ap.add_argument("--range", default="", help="a:b = chi chay dot bien thu a..b-1 (chia lan chay dai)")
    a = ap.parse_args()
    muts = list(mutate_irq.MUTATIONS) + EXTRA
    if a.pmp:
        muts = [m for m in muts if len(m) > 3 and m[3] is PMP]
    if a.su:
        muts = [m for m in muts if len(m) > 3 and m[3] is SUM]
    if a.mmu:
        muts = [m for m in muts if len(m) > 3 and m[3] is MMUA]
    if a.range:
        lo, hi = (int(x) if x else None for x in a.range.split(":"))
        muts = muts[lo:hi]
    srcs = {f: open(os.path.join(ROOT, f)).read() for f in (F, "rv32_mmu.v")}   # dot bien o pipeline hoac MMU
    caught, t0 = 0, time.time()
    for k, (name, old, new, *args) in enumerate(muts):
        args = args[0] if args else ["--quick"]
        tgt = [f for f, t in srcs.items() if t.count(old) == 1]
        if len(tgt) != 1:
            print(f"  [{k + 1}/{len(muts)}] BO QUA {name}: khong tim thay chuoi goc", flush=True)
            continue
        tmp = tempfile.mkdtemp(prefix="mutirq_")
        for f in ("rv32i_core.v", "rv32c_decompress.v", "rv32_mtimer.v", "rv32_icache.v", "rv32_dcache.v",
                  "rv32_bus_arbiter.v", F, "rv32_mmu.v"):
            shutil.copy(os.path.join(ROOT, f), tmp)
        open(os.path.join(tmp, tgt[0]), "w").write(srcs[tgt[0]].replace(old, new))
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
