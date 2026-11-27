#!/usr/bin/env python3
"""Mutation testing cho Debug Module / DTM / hart debug / hook DBG trong pipeline: moi dot bien sua dung 1 cho (chuoi goc phai xuat
hien dung 1 lan), dung lai Verilator build rv32_dbg_top, chay bo test nhanh cua debug/run_dbg_test.py qua JTAG that; dot bien
phai lam it nhat 1 test that bai (hoac mo phong treo / loi build = bi bat). Dung:
  python3 debug/mutate_dbg.py [--jobs 2] [--only chuoi] [--check]      (--check: chi kiem chuoi goc, khong build)
Ket qua in ra results/debug/mutation.txt (neu co --write)."""
import argparse, concurrent.futures as cf, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import run_dbg_test as T

DM, DTM, HART, TOP, PIPE = "debug/rv32_dm.v", "debug/rv32_dtm.v", "debug/rv32_dbg_hart.v", "debug/rv32_dbg_top.v", "rv32im_pipeline.v"
FAST = "dmi_regs,dmi_busy_exc,idcode,regs_csrs,mem,ebreak,step_trap,reset,triggers,step_irq,illegal_dcsr,illegal_region,halt_wfi,step_spike,riscv_tests"

M = [
    # ---- Debug Module ----
    ("dmstatus: version sai", DM, "3'b000, 4'd2 /*version 0.13*/", "3'b000, 4'd3 /*version 0.13*/"),
    ("dmstatus: khong bao authenticated", DM, "halted & sel0, halted & sel0, 1'b1 /*authenticated*/", "halted & sel0, halted & sel0, 1'b0 /*authenticated*/"),
    ("hartinfo: nscratch sai", DM, "32'h0010_0000;                          // hartinfo", "32'h0020_0000;                          // hartinfo"),
    ("abstractcs: progbufsize sai", DM, "5'd8 /*progbufsize*/", "5'd7 /*progbufsize*/"),
    ("abstractcs: datacount sai", DM, "4'd2 /*datacount*/", "4'd1 /*datacount*/"),
    ("haltsum0 sai", DM, "7'h40: dmi_rdata = {31'd0, halted & sel0};", "7'h40: dmi_rdata = {31'd0, ~halted & sel0};"),
    ("resumereq khong bi haltreq chan", DM, "if (dmi_wdata[30] & ~dmi_wdata[31] & halted", "if (dmi_wdata[30] & halted"),
    ("resumereq cung ho tro khi dang chay (khong can halted)", DM, "if (dmi_wdata[30] & ~dmi_wdata[31] & halted & ~busy", "if (dmi_wdata[30] & ~dmi_wdata[31] & ~busy"),
    ("ackhavereset khong xoa", DM, "if (dmi_wdata[28]) havereset <= 1'b0;", "if (dmi_wdata[28]) havereset <= havereset;"),
    ("reset hart khong dat havereset", DM, "if (hart_reset_ack) begin havereset <= 1'b1;", "if (hart_reset_ack) begin havereset <= havereset;"),
    ("reset hart khong xoa busy", DM, "halted <= 1'b0; busy <= 1'b0; go_f <= 1'b0; resume_f <= 1'b0; end\n            // hop thu", "halted <= 1'b0; go_f <= 1'b0; resume_f <= 1'b0; end\n            // hop thu"),
    ("cmderr khong xoa duoc", DM, "cmderr <= cmderr & ~dmi_wdata[10:8];", "cmderr <= cmderr;"),
    ("exception progbuf bao cmderr 2", DM, "if (cmderr == 3'd0) cmderr <= 3'd3; end", "if (cmderr == 3'd0) cmderr <= 3'd2; end"),
    ("ghi data0 khi busy khong bao loi", DM, "7'h04: if (!busy) data0 <= dmi_wdata; else if (cmderr == 3'd0) cmderr <= 3'd1;", "7'h04: if (!busy) data0 <= dmi_wdata;"),
    ("ghi progbuf khi busy khong bao loi", DM, "if (!busy) pb[dmi_addr[2:0]] <= dmi_wdata; else if (cmderr == 3'd0) cmderr <= 3'd1;", "if (!busy) pb[dmi_addr[2:0]] <= dmi_wdata;"),
    ("doc data khi busy khong bao loi", DM, "if (dr & busy & (is_data | is_pb) & (cmderr == 3'd0)) cmderr <= 3'd1;", "if (1'b0) cmderr <= 3'd1;"),
    ("lenh khi hart dang chay khong bao cmderr 4", DM, "else if (!halted | resume_f) cmderr <= 3'd4;", "else if (1'b0) cmderr <= 3'd4;"),
    ("lenh khong ho tro khong bao cmderr 2", DM, "if (!cmd_ok) cmderr <= 3'd2;", "if (1'b0) cmderr <= 3'd2;"),
    ("lenh khi cmderr != 0 van chay", DM, "else if (cmderr == 3'd0) begin\n                    if (!cmd_ok)", "else begin\n                    if (!cmd_ok)"),
    ("dmactive = 0 khong xoa cmderr", DM, "hartsel <= 10'd0; cmderr <= 3'd0; resumeack <= 1'b0; end", "hartsel <= 10'd0; resumeack <= 1'b0; end"),
    ("dmactive = 0 van nhan ghi", DM, "if (dmi_valid & ~dmactive & ~(dw", "if (1'b0 & ~dmactive & ~(dw"),
    ("hartsel khac 0 van coi la hart 0", DM, "wire       sel0 = (hartsel == 10'd0);", "wire       sel0 = 1'b1;"),
    ("abstractauto: sai bit autoexecdata", DM, "auto_d <= dmi_wdata[1:0];", "auto_d <= dmi_wdata[2:1];"),
    ("abstractauto: khong chay lai lenh", DM, "wire [31:0] cmd     = auto_trig ? last_cmd : dmi_wdata;", "wire [31:0] cmd     = dmi_wdata;"),
    ("resumeack khong dat", DM, "3'd2: begin resume_f <= 1'b0; halted <= 1'b0; resumeack <= 1'b1; end", "3'd2: begin resume_f <= 1'b0; halted <= 1'b0; resumeack <= 1'b0; end"),
    ("hop thu HALTED khong dat halted", DM, "3'd0: halted <= 1'b1;", "3'd0: halted <= halted;"),
    ("co FLAGS resume / go dao nguoc", DM, "resume_f ? 32'd2 : (go_f ? 32'd1 : 32'd0)", "resume_f ? 32'd1 : (go_f ? 32'd2 : 32'd0)"),
    ("GPR doc dung lenh sw sai thanh ghi", DM, "else         a0 = enc_sw(c_reg[4:0]);", "else         a0 = enc_sw(5'd10);"),
    ("ghi x0 khong thanh NOP", DM, "a0 = (c_reg[4:0] == 5'd0) ? NOP : enc_lw(c_reg[4:0]);", "a0 = enc_lw(c_reg[4:0]);"),
    ("CSR: khong khoi phuc s0", DM, "a3 = enc_csrr(5'd8, 12'h7B3);", "a3 = NOP;"),
    ("abstract: postexec bi bo", DM, "ab[4] <= c_post ? NOP : EBREAK;", "ab[4] <= EBREAK;"),
    ("doc ROM sai tu", DM, "9'd5: h_idata = ROM_05;", "9'd5: h_idata = ROM_04;"),
    # ---- DTM ----
    ("dtmcs: abits sai", DTM, "6'd7 /*abits*/", "6'd6 /*abits*/"),
    ("dtmcs: version sai", DTM, "4'd1 /*version 0.13*/", "4'd0 /*version 0.13*/"),
    ("dmireset khong xoa sticky", DTM, "IR_DTMCS: if (dr[16]) sticky <= 2'd0;", "IR_DTMCS: if (dr[17]) sticky <= 2'd0;"),
    ("sticky busy khong dat khi DMI ban", DTM, "else if (busy) sticky <= 2'd3;", "else if (1'b0) sticky <= 2'd3;"),
    ("IDCODE sai thanh ghi IR", DTM, "ir <= IR_IDCODE; ir_sh <= 5'd0;", "ir <= IR_DTMCS; ir_sh <= 5'd0;"),
    # ---- hart debug ----
    ("dcsr: cause step = 3", HART, "w_halt ? 3'd3 : 3'd4;", "w_halt ? 3'd3 : 3'd3;"),
    ("dcsr: uu tien trigger thap hon ebreak", HART, "trig_dbg ? 3'd2 : w_ebreak ? 3'd1", "w_ebreak ? 3'd1 : trig_dbg ? 3'd2"),
    ("dpc luu pc + 2", HART, "dpc_r <= ex_pc[31:1]; step_halt", "dpc_r <= ex_pc[31:1] + 31'd2; step_halt"),
    ("ghi dpc sai bit", HART, "12'h7B1: dpc_r <= csr_wdata[31:1];", "12'h7B1: dpc_r <= {1'b0, csr_wdata[31:2]};"),
    ("ebreakm doc bit sai", HART, "ebreakm <= csr_wdata[15];", "ebreakm <= csr_wdata[14];"),
    ("step khong che ngat", HART, "assign step_mask = step_en & ~dbg_mode;", "assign step_mask = 1'b0;"),
    ("step dung ngay khong cho lenh xong", HART, "if (~dbg_mode & step_en & ex_done & ~take) step_halt <= 1'b1;", "if (~dbg_mode & step_en & ~take) step_halt <= 1'b1;"),
    ("halt khong cho lenh o EX co the chan", HART, "wire w_halt   = ex_can & halt_req;", "wire w_halt   = halt_req;", "halt_bubbles"),
    ("ebreak khong doi ebreakm", HART, "wire w_ebreak = ex_can & ex_ebreak & ebreakm;", "wire w_ebreak = ex_can & ex_ebreak;"),
    ("DRET khong thoat D-mode", HART, "end else if (ex_dret) begin\n                dbg_mode <= 1'b0;", "end else if (ex_dret) begin\n                dbg_mode <= dbg_mode;"),
    ("trigger kich ca trong D-mode", HART, "fire[i] = ex_can & ~dbg_mode & t_m[i] &", "fire[i] = ex_can & t_m[i] &"),
    ("trigger bo qua bit m", HART, "fire[i] = ex_can & ~dbg_mode & t_m[i] &", "fire[i] = ex_can & ~dbg_mode &"),
    ("trigger NAPOT sai mat na", HART, "mask   = t ^ (t + 32'd1);", "mask   = t ^ (t - 32'd1);"),
    ("trigger store khong can ex_store", HART, "(ex_store & t_st[i] & amatch", "(t_st[i] & amatch"),
    ("trigger load dung pc", HART, "(ex_load & t_ld[i] & amatch(ex_ea,", "(ex_load & t_ld[i] & amatch(ex_pc,"),
    ("hit khong dat", HART, "if (fire[k]) t_hit[k] <= 1'b1;", "if (fire[k]) t_hit[k] <= 1'b0;"),
    ("trigger dmode action bi bo qua", HART, "(csr_wdata[15:12] == 4'd1);", "(csr_wdata[15:12] == 4'd0);"),
    ("trigger exception cung o action 1", HART, "assign trig_exc = (|fire) & ~trig_dbg;", "assign trig_exc = (|fire);"),
    ("tselect cho phep >= NT", HART, "12'h7A0: if (csr_wdata < NT) tsel <= csr_wdata[0];", "12'h7A0: if (csr_wdata <= NT) tsel <= csr_wdata[0];"),
    ("CSR debug khong bao bat hop le ngoai D-mode", HART, "assign csr_ill = csr_acc & is_d & ~dbg_mode;", "assign csr_ill = 1'b0;"),
    ("trigger dmode ghi duoc ngoai D-mode", HART, "t_dmode[tsel] <= dbg_mode & csr_wdata[27];", "t_dmode[tsel] <= csr_wdata[27];"),
    ("tinfo sai", HART, "12'h7A4: csr_rdata = 32'h0000_0004;", "12'h7A4: csr_rdata = 32'h0000_0001;"),
    # ---- top ----
    ("vung debug truy cap duoc ngoai D-mode (lenh)", TOP, "wire in_dbg_i = dbg_mode & (imem_addr[31:11] == 21'h1FFFFF);", "wire in_dbg_i = (imem_addr[31:11] == 21'h1FFFFF);"),
    ("ndmreset khong reset loi", TOP, "wire        core_rst_n = rst_n & ~ndmreset;", "wire        core_rst_n = rst_n;"),
    ("boot khong halt", TOP, "if (!rst_n) boot_q <= boot_halt;", "if (!rst_n) boot_q <= 1'b0;"),
    ("IRQSW khong tao ngat", TOP, "else if (dmem_we && dmem_addr == IRQSW) irq_sw <= dmem_wdata[0];", "else if (dmem_we && dmem_addr == IRQSW) irq_sw <= 1'b0;"),
    # ---- hook DBG trong pipeline ----
    ("DRET hop le ngoai D-mode", PIPE, "(idex_dret & ~dbg_mode_w);", "(idex_dret & 1'b0);"),
    ("step khong che ngat (pipeline)", PIPE, "wire irq_take_p = irq_any & ex_can & ~dbg_mode_w & ~dbg_step_mask & ~dbg_take;", "wire irq_take_p = irq_any & ex_can & ~dbg_mode_w & ~dbg_take;"),
    ("ngat nhan duoc trong D-mode", PIPE, "wire irq_take_p = irq_any & ex_can & ~dbg_mode_w & ~dbg_step_mask & ~dbg_take;", "wire irq_take_p = irq_any & ex_can & ~dbg_step_mask & ~dbg_take;"),
    ("trap trong D-mode ghi mepc / mcause", PIPE, "trap_ex & ~frz & ~dbg_take & ~dbg_mode_w;", "trap_ex & ~frz & ~dbg_take;"),
    ("vao D-mode ghi mepc / mcause", PIPE, "trap_ex & ~frz & ~dbg_take & ~dbg_mode_w;", "trap_ex & ~frz & ~dbg_mode_w;"),
    ("ebreak / exception trong D-mode nhay sai", PIPE, "(DBG_ENTRY + (rt_ebrk ? 32'd4 : 32'd8))", "(DBG_ENTRY + (rt_ebrk ? 32'd8 : 32'd4))"),
    ("DRET ve sai dia chi", PIPE, "dret_ex ? dbg_dret_pc :", "dret_ex ? 32'd0 :"),
    ("WFI khong thuc day khi halt", PIPE, "assign wfi_wait = idex_wfi & ~irq_pend & ~dbg_wake & ~ex_priv_ill;", "assign wfi_wait = idex_wfi & ~irq_pend & ~ex_priv_ill;"),
    ("trigger exception sai nguyen nhan", PIPE, "else if (dbg_trig_exc)  begin trap_cause = 32'd3;", "else if (dbg_trig_exc)  begin trap_cause = 32'd4;"),
    ("trigger exception tval = pc", PIPE, "trap_tval = (idex_load | idex_store) ? ea : idex_pc; end   // trigger", "trap_tval = idex_pc; end   // trigger"),
    ("CSR trigger khong ton tai", PIPE, "if (id_csr_addr == 12'h7A0 || id_csr_addr == 12'h7A1 ||", "if (id_csr_addr == 12'h7A0 ||"),
    ("sau DRET lenh moi khong redirect", PIPE, "assign redirect    = (trap_ex | mret_ex | sret_ex | dret_ex |", "assign redirect    = (trap_ex | mret_ex | sret_ex |"),
]


# dot bien song sot co chu y (da doc RTL): tuong duong ve hanh vi, hoac khong the kich hoat qua giao dien JTAG that
EQUIV = {
    "IDCODE sai thanh ghi IR": "tuong duong: trang thai Test-Logic-Reset nap lai IR = IDCODE ngay chu ky TCK dau (test idcode dua TAP ve TLR bang TMS)",
    "ghi x0 khong thanh NOP": "tuong duong: lw x0 bi phan cung bo (x0 luon 0)",
    "trigger exception cung o action 1": "tuong duong: dbg_take uu tien o redirect va chan trap_q, trig_exc dong thoi khong doi hanh vi",
    "dmireset khong xoa sticky": "khong the kich hoat: DMI ban xay ra khi DM tra loi cham hon 1 lan dich 41 bit, DM tra loi trong vai chu ky",
    "sticky busy khong dat khi DMI ban": "khong the kich hoat: nhu tren (can DM co y lam cham de thu)",
}


def check():
    bad = 0
    for name, f, old, new, *_ in M:
        n = open(os.path.join(ROOT, f)).read().count(old)
        if n != 1:
            print(f"LECH {name}: chuoi goc xuat hien {n} lan trong {f}")
            bad += 1
    print(f"{len(M)} dot bien, {bad} lech")
    return bad


def one(idx, port_base):
    name, f, old, new = M[idx][:4]
    extra = M[idx][4] if len(M[idx]) > 4 else ""
    tmp = tempfile.mkdtemp(prefix=f"mdbg{idx}_")
    try:
        for g in T.FILES:
            os.makedirs(os.path.dirname(os.path.join(tmp, g)), exist_ok=True)
            shutil.copy(os.path.join(ROOT, g), os.path.join(tmp, g))
        p = os.path.join(tmp, f)
        s = open(p).read()
        open(p, "w").write(s.replace(old, new, 1))
        out = os.path.join(tmp, "obj")
        r = subprocess.run(["verilator", "--cc", "--exe", "--build", "--no-timing", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-BLKLOOPINIT",
                            "-O1", "-j", "1", "-DDBG", "--top-module", "rv32_dbg_top", "-Mdir", out, "-o", "Vdbg"] +
                           [os.path.join(tmp, g) for g in T.FILES] + [os.path.join(HERE, "tb_main.cpp")], capture_output=True, text=True)
        if r.returncode:
            return idx, "BAT (loi build)", "-"
        env = dict(os.environ, VDBG=os.path.join(out, "Vdbg"), DBG_PORT_BASE=str(port_base), DBG_NO_PKILL="1", DBG_STEPS="150")
        r = subprocess.run([sys.executable, os.path.join(HERE, "run_dbg_test.py"), "--only", FAST + ("," + extra if extra else ""), "--failfast"], capture_output=True, text=True, env=env, timeout=900)
        fails = [l.split()[1] for l in r.stdout.splitlines() if l.startswith("FAIL")]
        return idx, ("BAT" if fails or r.returncode else "SONG"), ",".join(fails) or ("loi chay" if r.returncode else "-")
    except subprocess.TimeoutExpired:
        return idx, "BAT (treo)", "timeout"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--only", default="")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--write", default="")
    a = ap.parse_args()
    bad = check()
    if bad or a.check:
        sys.exit(1 if bad else 0)
    idx = [i for i, m in enumerate(M) if a.only in m[0]]
    res = {}
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        futs = [ex.submit(one, i, 20000 + 100 * k) for k, i in enumerate(idx)]
        for fu in cf.as_completed(futs):
            i, st, by = fu.result()
            res[i] = (st, by)
            print(f"{st:14s} {M[i][0]}  [{by}]", flush=True)
    alive = [M[i][0] for i in idx if res[i][0] == "SONG"]
    surv = [n for n in alive if n not in EQUIV]
    eq = [n for n in alive if n in EQUIV]
    line = (f"{len(idx) - len(alive)}/{len(idx)} dot bien bi bat" + (f", {len(eq)} song sot co chu y ({'; '.join(f'{n}: {EQUIV[n]}' for n in eq)})" if eq else "") +
            (f"; SONG SOT CHUA GIAI THICH: {'; '.join(surv)}" if surv else ""))
    print(line)
    if a.write:
        os.makedirs(os.path.dirname(a.write), exist_ok=True)
        with open(a.write, "w") as f:
            f.write(line + "\n")
            for i in idx:
                f.write(f"{res[i][0]:14s} {M[i][0]}  [{res[i][1]}]" + (f"  <- {EQUIV[M[i][0]]}" if res[i][0] == "SONG" and M[i][0] in EQUIV else "") + "\n")
    sys.exit(1 if surv else 0)


if __name__ == "__main__":
    main()
