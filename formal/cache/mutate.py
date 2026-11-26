# Doi chung am cho cache: chen loi vao ban sao RTL, chung minh (k-quy nap) phai KHONG con PASS (FAIL = co phan vi du, UNKNOWN = bat bien quy nap khong dong duoc)
import subprocess, sys, os, shutil, re
W, ROOT, HERE, which = sys.argv[1:5]
IC = [  # (ten, tep, doan goc (1 lan), doan thay, sby, tac vu)
 ("i_tag_thieu_bit", "rv32_icache.v", "tag_r[s0 * WAYS + q] == t0", "tag_r[s0 * WAYS + q][TB-2:0] == t0[TB-2:0]", "icache.sby", "w2"),
 ("i_kill_bo_qua", "rv32_icache.v", "val_r[fill_set * WAYS + fill_way] <= ~(fill_kill | flush);", "val_r[fill_set * WAYS + fill_way] <= 1'b1;", "icache.sby", "w2"),
 ("i_kill_thieu_flush_cuoi", "rv32_icache.v", "val_r[fill_set * WAYS + fill_way] <= ~(fill_kill | flush);", "val_r[fill_set * WAYS + fill_way] <= ~fill_kill;", "icache.sby", "w2"),
 ("i_chi_so_tu_nap", "rv32_icache.v", "mem_r[(fill_set * WAYS + fill_way) * WORDS + fill_cnt] <= m_rdata;", "mem_r[(fill_set * WAYS + fill_way) * WORDS + (fill_cnt ^ {{(WB-1){1'b0}}, 1'b1})] <= m_rdata;", "icache.sby", "w2"),
 ("i_ghep_cua_so", "rv32_icache.v", "{d1[15:0], d0[31:16]}", "{d1[31:16], d0[31:16]}", "icache.sby", "w2"),
 ("i_thieu_hit1", "rv32_icache.v", "(~need1 | hit1)", "1'b1", "icache.sby", "w2"),
 ("i_flush_khong_xoa", "rv32_icache.v", "            if (flush)\n                for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;", "            if (1'b0)\n                for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;", "icache.sby", "w2"),
 ("i_dia_chi_nap", "rv32_icache.v", "assign m_addr = {fill_line, fill_cnt, 2'b00};", "assign m_addr = {fill_line, ~fill_cnt, 2'b00};", "icache.sby", "w2"),
]
DC = [
 ("d_store_hit_sin_cap_nhat", "rv32_dcache.v", "if (hit) mem_r[(idx * WAYS + hway) * WORDS + w[WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);", "if (1'b0) mem_r[(idx * WAYS + hway) * WORDS + w[WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);", "dcache.sby", "w2"),
 ("d_store_bo_qua_wstrb", "rv32_dcache.v", "<= (cdata & ~wmask) | (wdata & wmask);", "<= wdata;", "dcache.sby", "w2"),
 ("d_khong_forward", "rv32_dcache.v", "if (j < q_cnt && q_addr[fs] == fill_w) begin", "if (j < q_cnt && q_addr[fs] == fill_w && 1'b0) begin", "dcache.sby", "w2"),
 ("d_forward_khong_tron", "rv32_dcache.v", "fill_data = (fill_data & ~fmask) | (q_data[fs] & fmask);", "fill_data = q_data[fs];", "dcache.sby", "w2"),
 ("d_fence_som", "rv32_dcache.v", "(free & fence & wb_empty)", "(free & fence)", "dcache.sby", "w2"),
 ("d_ghi_sai_muc", "rv32_dcache.v", "(state == DRN)  ? {q_addr[q_head], 2'b00}", "(state == DRN)  ? {q_addr[q_tail], 2'b00}", "dcache.sby", "w2"),
 ("d_drn_som", "rv32_dcache.v", "end else if (q_next == 0)", "end else if (q_next <= 1)", "dcache.sby", "u2"),
 ("d_tag_sai", "rv32_dcache.v", "tag_r[idx * WAYS + fill_way] <= tg;", "tag_r[idx * WAYS + fill_way] <= tg ^ {{(TB-1){1'b0}}, 1'b1};", "dcache.sby", "w2"),
 ("d_moi_dia_chi_cacheable", "rv32_dcache.v", "wire          cacheable = ((addr & CMASK) == CBASE);", "wire          cacheable = 1'b1;", "dcache.sby", "u2"),
 ("d_buffer_tran", "rv32_dcache.v", "wire push   = free & we & ~q_full;", "wire push   = free & we;", "dcache.sby", "w2"),
]
muts = (IC if which in ("all", "i") else []) + (DC if which in ("all", "d") else [])
rc = 0
for name, f, old, new, sby, task in muts:
    d = os.path.join(W, "m_" + name)
    shutil.copytree(os.path.join(W, "main"), d)
    p = os.path.join(d, f); s = open(p).read()
    if s.count(old) != 1:
        print("%s: KHONG TIM THAY doan goc (%d)" % (name, s.count(old))); rc = 1; continue
    open(p, "w").write(s.replace(old, new))
    out = subprocess.run("cd %s && sby -f %s %s > m.log 2>&1; grep -E 'DONE \\(' m.log | sed 's/.*DONE/DONE/'" % (d, sby, task), shell=True, capture_output=True, text=True).stdout.strip()
    print("dot bien %s: %s" % (name, out))
    if "PASS" in out: rc = 1
sys.exit(rc)
