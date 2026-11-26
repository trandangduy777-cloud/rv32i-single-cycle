#!/usr/bin/env python3
"""Mutation test cho cac nhom assertion SVA (verilator/sva/*.sv): moi dot bien RTL phai bi DUNG nhom assertion du kien bat duoc
(kiem tra ten assertion trong thong bao, khong chi 'co that bai'). Dot bien chay tren ban sao RTL (RV_ROOT), file SVA lay tu repo.
Moi nhom (ARB_, DC_, IC_, PL_) co it nhat 1 dot bien, kem 1 dong doi chung khong dot bien (phai khong co assertion nao that bai).
Dung: python3 verilator/mutate_sva.py [--jobs 2] [--only ARB_]"""
import argparse, concurrent.futures as cf, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (nhom, ten, file, goc, thay, {assertion du kien}, workload run_sva.py)
C0, C1, C2, C3, C4 = "0", "1", "2", "3", "4"
CACHE_ALL = ["--groups", "cache", "--n", "3"]
M = [
    ("DOI CHUNG", "khong dot bien", "rv32_bus_arbiter.v", "module rv32_bus_arbiter", "module rv32_bus_arbiter", set(), ["--groups", "cache", "core", "irq", "--n", "2", "--cache-cfgs", "0", "2", "--core-cfgs", "4"]),
    ("ARB_", "uu tien cache lenh thay cache du lieu", "rv32_bus_arbiter.v",
     "wire sel_d = (own == OWN_D) | ((own == NONE) & d_req);\n    wire sel_i = (own == OWN_I) | ((own == NONE) & ~d_req & i_req);",
     "wire sel_d = (own == OWN_D) | ((own == NONE) & ~i_req & d_req);\n    wire sel_i = (own == OWN_I) | ((own == NONE) & i_req);",
     {"ARB_prio_d"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("ARB_", "i_ack khong cong voi quyen cap", "rv32_bus_arbiter.v", "assign i_ack   = sel_i & m_ack;", "assign i_ack   = i_req & m_ack;",
     {"ARB_one_ack", "ARB_addr_i", "ARB_addr_d"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("ARB_", "doi chu bus giua giao dich", "rv32_bus_arbiter.v", "else if (m_ack)        own <= NONE;",
     "else if (m_ack | (own == OWN_I & d_req)) own <= NONE;", {"ARB_hold_own", "ARB_hold_req"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("ARB_", "cache lenh khong bao gio duoc cap", "rv32_bus_arbiter.v", "((own == NONE) & ~d_req & i_req);", "((own == NONE) & ~d_req & i_req & 1'b0);",
     {"ARB_i_timeout"}, ["--groups", "cache", "--n", "1", "--cache-cfgs", "0"]),
    ("ARB_", "wstrb khong chon theo ben duoc cap", "rv32_bus_arbiter.v", "assign m_wstrb = sel_d ? d_wstrb : 4'b1111;", "assign m_wstrb = d_wstrb;",
     {"ARB_addr_i"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("ARB_", "dia chi bus doi sang cache du lieu giua chung", "rv32_bus_arbiter.v", "assign m_addr  = sel_d ? d_addr : i_addr;", "assign m_addr  = d_req ? d_addr : i_addr;",
     {"ARB_hold_req", "ARB_addr_i"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("DC_", "forward theo thu tu moi -> cu", "rv32_dcache.v", "for (j = 0; j < WBUF; j = j + 1) begin\n            fs = q_head + j;",
     "for (j = WBUF - 1; j >= 0; j = j - 1) begin\n            fs = q_head + j;", {"DC_fwd_data", "DC_load_data"}, ["--groups", "cache", "core", "--n", "6", "--cache-cfgs", "0", "2", "--core-cfgs", "5"]),
    ("DC_", "forward bo qua wstrb", "rv32_dcache.v", "fill_data = (fill_data & ~fmask) | (q_data[fs] & fmask);", "fill_data = q_data[fs];",
     {"DC_fwd_data", "DC_load_data"}, ["--groups", "cache", "core", "--n", "6", "--cache-cfgs", "0", "2", "--core-cfgs", "5"]),
    ("DC_", "bo dem ghi khong tien con tro dau", "rv32_dcache.v", "q_head  <= q_inc(q_head);", "q_head  <= q_head;",
     {"DC_wb_order", "DC_wb_count"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("DC_", "load bao ready khi khong trung", "rv32_dcache.v", "assign ready = push | ld_hit |", "assign ready = push | (free & re) |",
     {"DC_no_data_on_miss", "DC_load_data"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("DC_", "load trung tra sai tu trong dong", "rv32_dcache.v", "wire [31:0]   cdata = mem_r[(idx * WAYS + hway) * WORDS + w[WB-1:0]];",
     "wire [31:0]   cdata = mem_r[(idx * WAYS + hway) * WORDS + 0];", {"DC_load_data"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("DC_", "store trung bo qua wstrb", "rv32_dcache.v", "mem_r[(idx * WAYS + hway) * WORDS + w[WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);",
     "mem_r[(idx * WAYS + hway) * WORDS + w[WB-1:0]] <= wdata;", {"DC_load_data"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("DC_", "FENCE xong khi bo dem chua rong", "rv32_dcache.v", "(free & fence & wb_empty)", "(free & fence)",
     {"DC_fence_empty"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("DC_", "nhan store khi bo dem day", "rv32_dcache.v", "wire push   = free & we & ~q_full;", "wire push   = free & we;",
     {"DC_wb_nofull_push", "DC_wb_count"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "2"]),
    # (dot bien "bo ~wb_empty khoi nhanh IDLE" la TUONG DUONG: IDLE luon co bo dem rong nen khong dua vao day; da loai)
    ("DC_", "DRN roi di khi bo dem con du lieu", "rv32_dcache.v", "end else if (q_next == 0)", "end else if (1'b1)",
     {"DC_wb_busy"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("IC_", "lenh vat qua tu lay sai nua", "rv32_icache.v", "assign data  = need1 ? {d1[15:0], d0[31:16]} : d0;", "assign data  = need1 ? {d1[15:0], d0[15:0]} : d0;",
     {"IC_data_correct"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("IC_", "flush khong xoa valid", "rv32_icache.v", "            if (flush)\n                for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;",
     "            if (flush & 1'b0)\n                for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;", {"IC_flush_inval"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("IC_", "dong nap trong luc flush van hop le", "rv32_icache.v", "val_r[fill_set * WAYS + fill_way] <= ~(fill_kill | flush);",
     "val_r[fill_set * WAYS + fill_way] <= 1'b1;", {"IC_fill_killed", "IC_data_correct"}, ["--groups", "cache", "--n", "3", "--cache-cfgs", "0", "2"]),
    ("PL_", "ghi vao x0 o WB", "rv32im_pipeline.v", "wire        wb_we = memwb_valid & memwb_rd_we & (memwb_rd != 5'd0);",
     "wire        wb_we = memwb_valid & memwb_rd_we;", {"PL_no_wb_x0"}, ["--groups", "core", "--n", "4", "--core-cfgs", "3"]),
    ("PL_", "forward cho toan hang x0", "rv32im_pipeline.v", "assign id_fa_mem = idex_valid  & idex_rd_we  & (idex_rd  != 5'd0) & (idex_rd  == rs1);",
     "assign id_fa_mem = idex_valid  & idex_rd_we  & (idex_rd  == rs1);", {"PL_no_fwd_x0_a"}, ["--groups", "core", "--n", "6", "--core-cfgs", "3"]),
    ("PL_", "redirect khong huy lenh o IF/ID", "rv32im_pipeline.v", "pc         <= rt_trap ? trap_pc : redirect_pc_q;\n            ifid_valid <= 1'b0;                // huy lenh vua doc nham duong",
     "pc         <= rt_trap ? trap_pc : redirect_pc_q;\n            ifid_valid <= 1'b1;                // huy lenh vua doc nham duong", {"PL_redirect_kill_ifid"}, ["--groups", "core", "--n", "4", "--core-cfgs", "3"]),
    ("PL_", "lenh nham duong o EX khong bi huy", "rv32im_pipeline.v", "wire        idex_valid = idex_valid_r & ~redirect_q;",
     "wire        idex_valid = idex_valid_r;", {"PL_redirect_no_valid", "PL_redirect_kill_ex"}, ["--groups", "core", "--n", "4", "--core-cfgs", "3"]),
    ("PL_", "lenh gay trap van ghi bo nho", "rv32im_pipeline.v", "exmem_store     <= idex_store & ~ex_stall & ~trap_ex;",
     "exmem_store     <= idex_store & ~ex_stall;", {"PL_trap_no_side_effect"}, ["--groups", "core", "--n", "8", "--core-cfgs", "3"]),
    ("PL_", "ngat chi nhan duoc mot lan", "rv32im_pipeline.v", "wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~idex_wfi_r & ~frz & ~dwait;",
     "wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~idex_wfi_r & ~frz & ~dwait & ~mstatus_mpie;", {"PL_irq_not_lost"}, ["--groups", "irq"]),
    ("PL_", "nhan ngat nhung khong ghi trap", "rv32im_pipeline.v", "else        trap_q <= trap_ex & ~frz;", "else        trap_q <= trap_ex & ~frz & ~irq_take;",
     {"PL_irq_traps"}, ["--groups", "irq"]),
]


def one(m):
    grp, name, fn, old, new, expect, args = m
    tmp = tempfile.mkdtemp(prefix="mutsva_")
    for f in os.listdir(ROOT):
        if f.endswith(".v"):
            shutil.copy(os.path.join(ROOT, f), tmp)
    txt = open(os.path.join(tmp, fn)).read()
    if old not in txt:
        return grp, name, expect, None, f"KHONG TIM THAY chuoi goc ({fn})"
    open(os.path.join(tmp, fn), "w").write(txt.replace(old, new, 1))
    js = os.path.join(tmp, "r.json")
    r = subprocess.run([sys.executable, os.path.join(HERE, "run_sva.py"), "--stop-on-fail", "--json", js] + args,
                       capture_output=True, text=True, env=dict(os.environ, RV_ROOT=tmp, SVA_ONLY="1"))
    if r.returncode == 2:
        return grp, name, expect, None, "loi bien dich: " + (r.stdout + r.stderr)[-300:]
    got = set(json.load(open(js))["fails"]) if os.path.exists(js) else set()
    shutil.rmtree(tmp, ignore_errors=True)
    return grp, name, expect, got, ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    ms = [m for m in M if a.only in m[0] or m[0] == "DOI CHUNG" and not a.only]
    ok = 0
    groups = {}
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for grp, name, expect, got, err in ex.map(one, ms):
            if got is None:
                print(f"LOI CONG CU {grp} {name}: {err}")
                sys.exit(2)
            if grp == "DOI CHUNG":
                good = not got
                print(f"{'THOAT   ' if good else 'SAI     '} DOI CHUNG {name} (khong dot bien): assertion that bai = {sorted(got) or 'khong'}")
            else:
                good = bool(got & expect)
                groups.setdefault(grp, [0, 0])
                groups[grp][0] += good
                groups[grp][1] += 1
                print(f"{'BAT DUOC' if good else 'THOAT   '} {grp:<4} {name}  | assertion: {sorted(got) or 'khong'} (du kien {sorted(expect)})", flush=True)
            ok += good
    print("NHOM: " + ", ".join(f"{g} {v[0]}/{v[1]}" for g, v in sorted(groups.items())))
    tot = sum(v[1] for v in groups.values())
    caught = sum(v[0] for v in groups.values())
    print(f"DOT BIEN SVA: bat duoc {caught}/{tot}")
    sys.exit(0 if caught == tot and all(True for _ in ms) else 1)


if __name__ == "__main__":
    main()
