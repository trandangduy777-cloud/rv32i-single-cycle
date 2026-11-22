#!/usr/bin/env python3
"""Mutation test cho cache va co che dong bang pipeline: moi dot bien phai bi bo kiem chung tuong ung bat duoc.

- Dot bien trong rv32_icache.v / rv32_dcache.v (ca bo dem ghi) / rv32_bus_arbiter.v: chay cache/tb_cache_random.v
  (5 cau hinh: anh xa truc tiep, 2 duong, 4 duong trong 1 tap; 3 seed moi cau hinh, do tre 1..6); testbench co mo
  hinh thay the doc lap nen bat ca dot bien chi lam sai chinh sach thay the (du lieu van dung). Phai co it nhat 1 lan bao FAIL hoac het thoi gian.
- Dot bien trong rv32im_pipeline.v (bat tay bo nho, dong bang, FENCE.I), 2 bo kiem chung:
  "cosim": cosim/run_cosim.py voi 2 cau hinh co cache tren bench va bench_m (co va khong co lenh nen);
  "rand":  verify/run_verify.py --pipem --cache (40 chuong trinh ngau nhien co CSR, trap, MRET... qua cache 2 x 2,
           bo nho tre 1..6), so voi ISS Python; testbench con kiem moi FENCE hoan tat thi bo nho da nhan moi store
           truoc no. Phai co it nhat 1 chuong trinh lech hoac treo.
  "ma":    nhu "rand" nhung voi --ma (MISALIGNED = 1, nhieu load/store lech dia chi, ISS cung khong trap).

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
     "if (val_r[s0 * WAYS + q] && tag_r[s0 * WAYS + q] == t0)", "if (val_r[s0 * WAYS + q])", "tb"),
    ("icache: bo qua tu thu hai khi addr[1] = 1", "rv32_icache.v",
     "assign ready = (state == IDLE) & hit0 & (~need1 | hit1);", "assign ready = (state == IDLE) & hit0;", "tb"),
    ("icache: cua so lenh nen lay sai nua tu", "rv32_icache.v",
     "assign data  = need1 ? {d1[15:0], d0[31:16]} : d0;", "assign data  = need1 ? {d0[15:0], d1[31:16]} : d0;", "tb"),
    ("icache: flush khi dang nap van danh dau valid", "rv32_icache.v",
     "<= ~(fill_kill | flush);", "<= 1'b1;", "tb"),
    ("icache: nap sai thu tu tu trong dong", "rv32_icache.v",
     "mem_r[(fill_set * WAYS + fill_way) * WORDS + fill_cnt] <= m_rdata;",
     "mem_r[(fill_set * WAYS + fill_way) * WORDS + ~fill_cnt] <= m_rdata;", "tb"),
    # ---- cache du lieu ----
    ("dcache: khong so tag", "rv32_dcache.v",
     "if (val_r[idx * WAYS + q] && tag_r[idx * WAYS + q] == tg)", "if (val_r[idx * WAYS + q])", "tb"),
    ("dcache: store trung cache khong cap nhat dong", "rv32_dcache.v",
     "if (hit) mem_r[(idx * WAYS + hway) * WORDS + w[WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);", ";", "tb"),
    ("dcache: store cap nhat ca tu, bo qua wstrb", "rv32_dcache.v",
     "if (hit) mem_r[(idx * WAYS + hway) * WORDS + w[WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);",
     "if (hit) mem_r[(idx * WAYS + hway) * WORDS + w[WB-1:0]] <= wdata;", "tb"),
    ("dcache: vung khong cacheable van luu cache", "rv32_dcache.v",
     "wire          cacheable = ((addr & CMASK) == CBASE);", "wire          cacheable = 1'b1;", "tb"),
    ("dcache: bus ghi khong theo wstrb", "rv32_dcache.v",
     "assign m_wstrb = (state == DRN) ? q_strb[q_head] : 4'b1111;", "assign m_wstrb = 4'b1111;", "tb"),
    # ---- set-associative va thay the pseudo-LRU (bat bang tb_cache_random.v: du lieu sai, hoac lech mo hinh thay the) ----
    ("icache: so tag cua duong 0 cho moi duong", "rv32_icache.v",
     "if (val_r[s0 * WAYS + q] && tag_r[s0 * WAYS + q] == t0)", "if (val_r[s0 * WAYS + q] && tag_r[s0 * WAYS] == t0)", "tb"),
    ("icache: nap vao duong 0 thay vi duong bi thay", "rv32_icache.v",
     "mem_r[(fill_set * WAYS + fill_way) * WORDS + fill_cnt] <= m_rdata;",
     "mem_r[(fill_set * WAYS) * WORDS + fill_cnt] <= m_rdata;", "tb"),
    ("icache: luon thay duong 0", "rv32_icache.v",
     "victim = plru_victim(plru_m);", "victim = {AB{1'b0}};", "tb"),
    ("icache: khong uu tien duong con trong", "rv32_icache.v",
     "if (!val_r[miss_set * WAYS + qv]) victim = qv;", "if (1'b0) victim = qv;", "tb"),
    ("icache: trung khong cap nhat LRU", "rv32_icache.v",
     "if (hit0) plru_r[s0] <= plru_touch(plru_r[s0], way0);", "if (1'b0) plru_r[s0] <= plru_touch(plru_r[s0], way0);", "tb"),
    ("icache: nan nhan khong tinh lan trung cua chinh chu ky", "rv32_icache.v",
     "if (hit0 && s0 == miss_set)          plru_m = plru_touch(plru_m, way0);", ";", "tb"),
    ("icache: cay LRU danh dau sai phia", "rv32_icache.v",
     "if (w < lo + half) begin plru_touch[node] = 1'b1;", "if (w < lo + half) begin plru_touch[node] = 1'b0;", "tb"),
    ("dcache: luon thay duong 0", "rv32_dcache.v",
     "victim = plru_victim(plru_r[idx]);", "victim = {AB{1'b0}};", "tb"),
    ("dcache: store trung khong cap nhat LRU", "rv32_dcache.v",
     "if (ld_hit | (push & hit)) plru_r[idx]", "if (ld_hit) plru_r[idx]", "tb"),
    ("dcache: store trung ghi vao duong 0", "rv32_dcache.v",
     "if (hit) mem_r[(idx * WAYS + hway) * WORDS + w[WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);",
     "if (hit) mem_r[(idx * WAYS) * WORDS + w[WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);", "tb"),
    ("dcache: load trung khong cap nhat LRU", "rv32_dcache.v",
     "if (ld_hit | (push & hit)) plru_r[idx]", "if (push & hit) plru_r[idx]", "tb"),
    ("dcache: bat dau nap xoa valid nham duong 0", "rv32_dcache.v",
     "val_r[idx * WAYS + victim] <= 1'b0;      // dong cu bi thay", "val_r[idx * WAYS] <= 1'b0;", "tb"),
    ("dcache: chon nan nhan theo cay nguoc chieu", "rv32_dcache.v",
     "node = b[node] ? 2 * node + 2 : 2 * node + 1;", "node = b[node] ? 2 * node + 1 : 2 * node + 2;", "tb"),
    # ---- bo dem ghi cua cache du lieu ----
    ("bo dem ghi: nap dong khong forward store dang treo", "rv32_dcache.v",
     "fill_data = (fill_data & ~fmask) | (q_data[fs] & fmask);", "fill_data = fill_data;", "tb"),
    ("bo dem ghi: forward theo thu tu moi -> cu", "rv32_dcache.v",
     "fs = q_head + j;", "fs = q_head + q_cnt - 1 - j;", "tb"),
    ("bo dem ghi: forward so dia chi theo dong thay vi theo tu", "rv32_dcache.v",
     "q_addr[fs] == fill_w)", "q_addr[fs][29:WB] == fill_w[29:WB])", "tb"),
    ("bo dem ghi: forward ca muc da ghi ra bo nho", "rv32_dcache.v",
     "if (j < q_cnt && q_addr[fs] == fill_w)", "if (q_addr[fs] == fill_w)", "tb"),
    ("bo dem ghi: load ngoai vung cacheable khong cho ghi het", "rv32_dcache.v",
     "end else if (q_next == 0)", "end else if (q_next == 0 | rd_miss)", "tb"),
    ("bo dem ghi: fence khong cho ghi het", "rv32_dcache.v",
     "(free & fence & wb_empty)", "(free & fence)", "tb"),
    ("bo dem ghi: ghi ra bus muc cuoi thay vi muc dau", "rv32_dcache.v",
     "(state == DRN)  ? {q_addr[q_head], 2'b00}", "(state == DRN)  ? {q_addr[q_tail], 2'b00}", "tb"),
    ("bo dem ghi: nhan store khi da day", "rv32_dcache.v",
     "wire push   = free & we & ~q_full;", "wire push   = free & we;", "tb"),
    ("bo dem ghi: nap xong ve IDLE du bo dem con du lieu", "rv32_dcache.v",
     "state <= wb_empty ? IDLE : DRN;", "state <= IDLE;", "tb"),
    ("bo dem ghi: khong dem lui khi ghi xong", "rv32_dcache.v",
     "wire pop    = (state == DRN) & m_ack;", "wire pop    = 1'b0;", "tb"),
    # ---- bo phan xu ----
    ("arbiter: khong giu quyen bus toi khi ack", "rv32_bus_arbiter.v",
     "wire sel_d = (own == OWN_D) | ((own == NONE) & d_req);", "wire sel_d = d_req;", "tb"),
    ("arbiter: uu tien cache lenh (store trong bo dem toi sau lan nap lenh)", "rv32_bus_arbiter.v",
     "wire sel_d = (own == OWN_D) | ((own == NONE) & d_req);\n    wire sel_i = (own == OWN_I) | ((own == NONE) & ~d_req & i_req);",
     "wire sel_d = (own == OWN_D) | ((own == NONE) & d_req & ~i_req);\n    wire sel_i = (own == OWN_I) | ((own == NONE) & i_req);",
     "tb"),
    # ---- pipeline: bat tay bo nho ----
    ("pipeline: khong dong bang khi load cho bo nho", "rv32im_pipeline.v",
     "assign frz        = (dmem_we | dmem_re | dmem_fence) & ~(dmem_ready & mem_last);",
     "assign frz        = (dmem_we | dmem_fence) & ~(dmem_ready & mem_last);", "cosim"),
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
    ("pipeline: FENCE khong cho bo dem ghi", "rv32im_pipeline.v",
     "assign frz        = (dmem_we | dmem_re | dmem_fence) & ~(dmem_ready & mem_last);",
     "assign frz        = (dmem_we | dmem_re) & ~(dmem_ready & mem_last);", "rand"),
    ("pipeline: FENCE khong duoc dua xuong MEM", "rv32im_pipeline.v",
     "exmem_fence     <= idex_fence_r & idex_valid & ~ex_stall & ~trap_ex;",
     "exmem_fence     <= 1'b0;", "rand"),
    # ---- load/store lech dia chi bang phan cung (MISALIGNED = 1): chuong trinh ngau nhien --ma qua cache ----
    ("lech: pha 1 khong sang tu ke tiep", "rv32im_pipeline.v",
     "{exmem_result[31:2] + 30'd1, 2'b00}", "{exmem_result[31:2], 2'b00}", "ma"),
    ("lech: khong giu tu thap cua pha 0", "rv32im_pipeline.v",
     "if (!ma_phase) ma_lo <= dmem_rdata;", ";", "ma"),
    ("lech: ghep 2 tu nguoc thu tu", "rv32im_pipeline.v",
     "ma_phase ? {dmem_rdata, ma_lo}", "ma_phase ? {ma_lo, dmem_rdata}", "ma"),
    ("lech: store pha 1 dung wstrb cua pha 0", "rv32im_pipeline.v",
     "wire [3:0]  st_strb = ma_phase ? st_strb8[7:4]  : st_strb8[3:0];",
     "wire [3:0]  st_strb = ma_phase ? st_strb8[3:0]  : st_strb8[3:0];", "ma"),
    ("lech: store pha 1 dung du lieu cua pha 0", "rv32im_pipeline.v",
     "wire [31:0] st_data = ma_phase ? st_wide[63:32] : st_wide[31:0];",
     "wire [31:0] st_data = ma_phase ? st_wide[31:0] : st_wide[31:0];", "ma"),
    ("lech: khong dong bang o pha 0", "rv32im_pipeline.v",
     "wire   mem_last   = ~ma_cross | ma_phase;", "wire   mem_last   = 1'b1;", "ma"),
    ("lech: chi tach word, half o byte 3 khong tach", "rv32im_pipeline.v",
     "(acc_strb8[7:4] != 4'b0000);", "(acc_strb8[7:4] != 4'b0000) & (exmem_funct3[1:0] == 2'b10);", "ma"),
    ("lech: pha khong ve 0 sau pha 1", "rv32im_pipeline.v",
     "ma_phase <= ~ma_phase;", "ma_phase <= 1'b1;", "ma"),
    ("lech: load lech van trap", "rv32im_pipeline.v",
     "wire ld_misal = (MISALIGNED == 0) & idex_load  &", "wire ld_misal = idex_load  &", "ma"),
    ("lech: store lech van trap", "rv32im_pipeline.v",
     "wire st_misal = (MISALIGNED == 0) & idex_store &", "wire st_misal = idex_store &", "ma"),
    # ---- FENCE.I (Zifencei): kiem bang cosim/tests/fencei.S (ma tu sua) ----
    ("FENCE.I khong xoa cache lenh", "rv32im_pipeline.v",
     "    assign icache_flush = fencei_ex;", "    assign icache_flush = 1'b0;", "cosim", "tests-"),
    ("FENCE.I khong nap lai lenh sau no", "rv32im_pipeline.v",
     "(trap_ex | mret_ex | jalr_miss | mispredict | fencei_ex) & ~frz;",
     "(trap_ex | mret_ex | jalr_miss | mispredict) & ~frz;", "cosim", "tests-"),
    ("pipeline: EX/MEM van chay khi dong bang", "rv32im_pipeline.v",
     "        end else if (!frz) begin\n            exmem_valid     <= idex_valid & ~ex_stall;",
     "        end else begin\n            exmem_valid     <= idex_valid & ~ex_stall;", "cosim"),
]

TB_CFGS = [["-DL=4", "-DW=2"], ["-DL=2", "-DW=8"], ["-DL=16", "-DW=4", "-DQ=2"], ["-DL=8", "-DW=2", "-DWY=2"],
           ["-DL=4", "-DW=2", "-DWY=4"]]


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


def run_cosim(rep, a, only="bench", core="cache"):
    try:
        r = subprocess.run([sys.executable, os.path.join(rep, "cosim", "run_cosim.py"), a.riscv_tests, "--spike",
                            a.spike, f"--only={only}", f"--core={core}", "--stop-on-fail"],
                           capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return True, "treo"
    out = r.stdout + r.stderr
    if "loi bien dich" in out or "Traceback" in out:
        return None, out.strip()[-200:]
    fail = next((l for l in out.splitlines() if l.startswith("FAIL")), None)
    return (True, fail) if r.returncode and fail else (False, "cosim PASS")


def run_rand(rep, extra=()):
    try:
        r = subprocess.run([sys.executable, os.path.join(rep, "verify", "run_verify.py"), "--pipem", "--cache",
                            "--n", "40", *extra], capture_output=True, text=True, timeout=1800)
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
    ap.add_argument("--kind", choices=["tb", "cosim", "rand", "ma", "all"], default="all", help="chi chay mot nhom dot bien")
    a = ap.parse_args()
    killed, bad = 0, 0
    muts = [m for m in MUTATIONS if a.kind in ("all", m[4])]
    for name, fn, old, new, how, *only in muts:
        src = open(os.path.join(ROOT, fn)).read()
        if src.count(old) != 1:
            print(f"  BO QUA  {name}: khong tim thay chuoi goc", flush=True)
            bad += 1
            continue
        tmp = tempfile.mkdtemp(prefix="mutc_")
        rep = os.path.join(tmp, "repo")
        shutil.copytree(ROOT, rep, ignore=shutil.ignore_patterns(".git", "results", "*.vcd", "*.vvp"))
        open(os.path.join(rep, fn), "w").write(src.replace(old, new))
        if how == "tb":
            caught, detail = run_tb(rep)
        elif how == "cosim":
            # FENCE.I: chay test tu sua ma tren moi loi pipeline RV32IM (co va khong co cache)
            caught, detail = run_cosim(rep, a, only[0], "RV32IM") if only else run_cosim(rep, a)
        elif how == "ma":
            caught, detail = run_rand(rep, ("--ma",))
        else:
            caught, detail = run_rand(rep)
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
