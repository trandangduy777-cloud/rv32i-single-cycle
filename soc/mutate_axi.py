#!/usr/bin/env python3
"""Mutation test cho bus AXI4 + DMA cua SoC: chen tung loi co y vao RTL (soc/axi/*.v) roi chay bo kiem chung cua SoC AXI4 (run_soc.run_suite voi axi=True: testbench
ngau nhien 3 master + bo kiem giao thuc + chuong trinh C tren SoC day du, gom t_dma). Moi dot bien phai bi it nhat mot buoc bat; in dot bien nao lot, khong ap dung hoac
khong bien dich, thoat ma 1 neu co. Dung: python3 soc/mutate_axi.py [--jobs N] [--only chuoi] [--check]   (--check: chi kiem old xuat hien dung 1 lan)
Can soc/sw/build_axi/*.hex (AXI=1 sh soc/sw/build.sh)."""
import os, sys, shutil, tempfile, argparse, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_soc

ROOT = run_soc.ROOT
M = []   # (id, file, old, new, mo ta, can chay bo kiem rieng cua interconnect)
def m(i, f, old, new, d): M.append((i, "axi/" + f, old, new, d))

X, MEM, DMA, BR, CI, TOP = "axi_xbar.v", "axi_mem.v", "axi_dma.v", "axi_periph_bridge.v", "axi_cache_if.v", "axi_soc_top.v"
# ---- interconnect ----
m("X1", X, "(wcnt[m] < MAXOUT) & ((wcnt[m] == 0) | (wslv[m] == s));", "(wcnt[m] < MAXOUT);", "xbar: ghi khong ep thu tu theo slave (B dao thu tu)")
m("X2", X, "(rcnt[m] < MAXOUT) & ((rcnt[m] == 0) | (rslv[m] == s));", "(rcnt[m] < MAXOUT);", "xbar: doc khong ep thu tu theo slave (R dao thu tu)")
m("X3", X, "rr_w[s*LNM +: LNM] <= w_win[s*LNM +: LNM];", "rr_w[s*LNM +: LNM] <= {LNM{1'b0}};", "xbar: phan xu ghi uu tien co dinh master 0")
m("X4", X, "if (r_win_v[s] & ~ar_lock[s]) rr_r[s*LNM +: LNM] <= r_win[s*LNM +: LNM];", "if (r_win_v[s] & ~ar_lock[s]) rr_r[s*LNM +: LNM] <= {LNM{1'b0}};", "xbar: phan xu doc uu tien co dinh master 0")
m("X5", X, "m = g_bid[s*SIDW + IDW +: LNM];", "m = {LNM{1'b0}};", "xbar: moi B gui ve master 0")
m("X6", X, "m = g_rid[s*SIDW + IDW +: LNM];", "m = {LNM{1'b0}};", "xbar: moi R gui ve master 0")
m("X7", X, "assign g_bresp[NS*2 +: 2]     = 2'b11;", "assign g_bresp[NS*2 +: 2]     = 2'b10;", "xbar: DECERR ghi tra SLVERR")
m("X8", X, "assign g_rlast[NS]   = e_rst & (e_rcnt == e_rlen);", "assign g_rlast[NS]   = e_rst & (e_rcnt == e_rlen + 8'd1);", "xbar: RLAST cua DECERR doc sai")
m("X9", X, "assign g_rdata[NS*32 +: 32]   = 32'd0;", "assign g_rdata[NS*32 +: 32]   = 32'hFFFF_FFFF;", "xbar: du lieu DECERR doc khac 0")
m("X10", X, "2'd1: if (f_wvalid[NS] & f_wlast[NS]) e_wst <= 2'd2;", "2'd1: if (f_wvalid[NS]) e_wst <= 2'd2;", "xbar: DECERR ghi nuot dung 1 beat W")
m("X11", X, "f_wstrb[s*4 +: 4]    = s_wstrb[m*4 +: 4];", "f_wstrb[s*4 +: 4]    = 4'hF;", "xbar: wstrb luon 1111")
m("X12", X, "f_awsize[s*3 +: 3]   = s_awsize[m*3 +: 3];", "f_awsize[s*3 +: 3]   = 3'd2;", "xbar: AWSIZE luon 2")
m("X13", X, "f_arburst[s*2 +: 2]   = s_arburst[m*2 +: 2];", "f_arburst[s*2 +: 2]   = 2'b01;", "xbar: ARBURST luon INCR")
m("X14", X, "f_awlen[s*8 +: 8]    = s_awlen[m*8 +: 8];", "f_awlen[s*8 +: 8]    = s_awlen[m*8 +: 8] & 8'h0F;", "xbar: AWLEN cat con 4 bit")
m("X15", X, "dec = NS;", "dec = 0;", "xbar: dia chi ngoai ban do toi slave 0 (khong DECERR)")
m("X16", X, "f_arid[s*SIDW +: SIDW] = {m[LNM-1:0], s_arid[m*IDW +: IDW]};", "f_arid[s*SIDW +: SIDW] = {{LNM{1'b0}}, s_arid[m*IDW +: IDW]};", "xbar: ID doc khong gan chi so master")
m("X17", X, "f_wlast[s]           = s_wlast[m];", "f_wlast[s]           = 1'b1;", "xbar: WLAST luon 1")
m("X18", X, "f_awvalid[s] = cur_v[s] & ~(own_v[s] & aw_done[s]) & s_awvalid[m];", "f_awvalid[s] = cur_v[s] & s_awvalid[m];", "xbar: AW dua lai cho slave sau khi da bat tay")
# ---- bo nho ----
m("M1", MEM, "2'b10: nxt = (a & ~(wrap - 32'd1)) | (inc & (wrap - 32'd1));", "2'b10: nxt = inc;", "mem: WRAP khong quay vong")
m("M2", MEM, "assign bresp   = w_err ? 2'b10 : 2'b00;", "assign bresp   = w_err ? 2'b11 : 2'b00;", "mem: ghi ROM tra DECERR thay vi SLVERR")
m("M3", MEM, "if (wstrb[2]) mem[widx][23:16] <= wdata[23:16];", "if (1'b1) mem[widx][23:16] <= wdata[23:16];", "mem: byte 2 ghi bat ke wstrb")
m("M4", MEM, "assign rlast   = (r_cnt == r_len);", "assign rlast   = (r_cnt == r_len) | (r_cnt == 8'd30);", "mem: RLAST som o beat 30")
# ---- DMA ----
m("D1", DMA, "bs = (32'd4096 - {20'd0, src[pick][11:0]}) >> 2; if (pn > bs) pn = bs;", "bs = 32'd1024; if (pn > bs) pn = bs;", "dma: burst nguon vuot ranh gioi 4 KB")
m("D2", DMA, "bd = (32'd4096 - {20'd0, dst[pick][11:0]}) >> 2; if (pn > bd) pn = bd;", "bd = 32'd1024; if (pn > bd) pn = bd;", "dma: burst dich vuot ranh gioi 4 KB")
m("D3", DMA, "pn = (rem[pick] > MAXB) ? MAXB : rem[pick];", "pn = (rem[pick] > MAXB + 1) ? MAXB + 1 : rem[pick];", "dma: manh 17 tu tran bo dem 16")
m("D4", DMA, "c = (rr + i) % NCH;", "c = i % NCH;", "dma: kenh 0 luon duoc chon truoc (khong luan phien)")
m("D5", DMA, "3'd5: if (!busy[ch]) ss[ch] <= wdata;", "3'd5: if (!busy[ch]) ds[ch] <= wdata;", "dma: ghi SSTRIDE thanh DSTRIDE")
m("D6", DMA, "(n == 1) ? ss[cur] : 32'd0);", "(n == 1) ? 32'd4 : 32'd0);", "dma: tung tu khong cong dung buoc nguon")
m("D7", DMA, "3'd1: begin if (wdata[1]) done[ch] <= 1'b0; if (wdata[2]) errf[ch] <= 1'b0; end", "3'd1: begin if (wdata[1]) done[ch] <= 1'b0; end", "dma: khong xoa duoc co ERR")
m("D8", DMA, "assign irq = ie & (done | errf);", "assign irq = (done | errf);", "dma: ngat bo qua bit IE")
m("D9", DMA, "if (rem[ch] == 0) begin done[ch] <= 1'b1; cyc[ch] <= 32'd0; end else busy[ch] <= 1'b1;", "busy[ch] <= 1'b1;", "dma: do dai 0 bi treo")
m("D10", DMA, "if (bresp != 2'b00) begin busy[cur] <= 1'b0; errf[cur] <= 1'b1; cyc[cur] <= cnt[cur]; end", "if (1'b0) begin busy[cur] <= 1'b0; errf[cur] <= 1'b1; cyc[cur] <= cnt[cur]; end", "dma: bo qua loi ghi (B)")
m("D11", DMA, "if (e_chunk || rresp != 2'b00) begin", "if (1'b0) begin", "dma: bo qua loi doc (R)")
m("D12", DMA, "assign arlen = n - 1; assign awlen = n - 1;", "assign arlen = n; assign awlen = n - 1;", "dma: ARLEN lech 1")
m("D13", DMA, "assign wlast = (wi == n - 1);", "assign wlast = (wi == n);", "dma: WLAST muon 1 beat")
m("D14", DMA, "assign wstrb_o = 4'b1111;", "assign wstrb_o = 4'b0111;", "dma: mat byte 3 khi ghi")
m("D15", DMA, "assign awburst = (n == 1 || !dfix) ? 2'b01 : 2'b00;", "assign awburst = 2'b01;", "dma: dich co dinh van burst INCR")
m("D16", DMA, "assign arburst = (n == 1 || !sfix) ? 2'b01 : 2'b00;", "assign arburst = 2'b01;", "dma: nguon co dinh van burst INCR")
m("D17", DMA, "src[cur] <= src[cur] + ((ss[cur] == 32'd4) ? {n, 2'b00}", "src[cur] <= src[cur] + ((ss[cur] == 32'd4) ? {n - 5'd1, 2'b00}", "dma: con tro nguon cong thieu 1 tu sau moi manh")
# ---- cau ngoai vi ----
m("B1", BR, "bresp = err_r ? 2'b11 : 2'b00;", "bresp = 2'b00;", "cau ngoai vi: ghi vao cua so khong co ngoai vi khong bao loi")
m("B2", BR, "assign l_we    = (st == WDATA) & wvalid;", "assign l_we    = (st == WDATA);", "cau ngoai vi: ghi ngoai vi khi chua co W")
m("B3", BR, "else begin a_r <= nxt(a_r, sz_r, bt_r, len_r); cnt <= cnt + 8'd1; st <= RACC; end", "else begin cnt <= cnt + 8'd1; st <= RACC; end", "cau ngoai vi: burst doc khong tang dia chi")
m("B4", BR, "a_r <= nxt(a_r, sz_r, bt_r, len_r); cnt <= cnt + 8'd1;\n                if (wlast) st <= WRESP;", "cnt <= cnt + 8'd1;\n                if (wlast) st <= WRESP;", "cau ngoai vi: burst ghi khong tang dia chi")
# ---- cau cache <-> AXI ----
m("C1", CI, "assign arlen = WORDS - 1;", "assign arlen = WORDS;", "icache master: ARLEN lech 1")
m("C2", CI, "fill_r <= m_fill & ~m_we;", "fill_r <= 1'b0;", "dcache master: nap dong chi 1 beat")
m("C3", CI, "& (rresp != 2'b00) & ~e_seen)", "& (rresp != 2'b00))", "dcache master: loi nap dong dem moi beat")
m("C4", CI, "IDLE: if (m_req && (m_we || m_fill || outst == 3'd0 || POSTED == 0)) begin", "IDLE: if (m_req) begin", "dcache master: doc thiet bi khong cho ghi truoc xong B")
m("C5", CI, "if (POSTED != 0) outst <= outst + {2'b00, wr_acked} - {2'b00, bvalid};", "if (POSTED != 0) outst <= outst + {2'b00, wr_acked};", "dcache master: dem ghi dang bay khong giam")
# ---- top ----
m("T1", TOP, "32'h4000_0000, 32'h1000_0000, 32'h0000_0000};", "32'h5000_0000, 32'h1000_0000, 32'h0000_0000};", "top: bi danh RAM sai dia chi")
m("T2", TOP, "32'hFFFE_0000, 32'hFFC0_0000", "32'hFFFF_0000, 32'hFFC0_0000", "top: vung ngoai vi khong toi duoc DMA")
m("T3", TOP, ".src({dma_irq, ext_irq, irq_gpio, irq_uart_tx, irq_uart_rx})", ".src({ext_irq, dma_irq, irq_gpio, irq_uart_tx, irq_uart_rx})", "top: nguon ngat DMA va ngoai bi doi cho")
m("T4", TOP, ".CMASK(32'hF000_0000), .CBASE(32'h1000_0000)", ".CMASK(32'h8000_0000), .CBASE(32'h0000_0000)", "top: cache du lieu cache ca ngoai vi")
m("T5", TOP, ".bus_err(dc_err)", ".bus_err(1'b0)", "top: SYSCON khong nhan loi bus")
m("T6", TOP, "assign sel_dma = (l_addr[31:12] == 20'h20010);", "assign sel_dma = (l_addr[31:12] == 20'h20011);", "top: thanh ghi DMA sai dia chi")
m("T7", TOP, "assign l_err   = (l_re | l_we) & ~(sel_clint | sel_uart | sel_gpio | sel_sys | sel_plic | sel_dma);", "assign l_err   = 1'b0;", "top: cua so ngoai vi trong khong bao DECERR")


def apply(tmp, mut):
    i, f, old, new, d = mut
    path = os.path.join(tmp, "soc", f)
    s = open(path).read()
    if s.count(old) != 1:
        return "old xuat hien %d lan" % s.count(old)
    open(path, "w").write(s.replace(old, new))
    return None


def run_one(mut, sw):
    tmp = tempfile.mkdtemp(prefix="mutaxi_")
    try:
        shutil.copytree(os.path.join(ROOT, "soc"), os.path.join(tmp, "soc"), ignore=shutil.ignore_patterns("sw", "__pycache__", "freertos", "synth"))
        for f in run_soc.CORE_AXI:
            shutil.copy(os.path.join(ROOT, f), tmp)
        err = apply(tmp, mut)
        if err:
            return (mut, "LOI", err)
        only_soc = mut[1] not in ("axi/axi_xbar.v", "axi/axi_mem.v", "axi/axi_periph_bridge.v")      # DMA / cache / top khong co trong cac testbench rieng
        res = run_soc.run_suite(tmp, sw, tmp, stop_first=True, verbose=False, axi=True, axi_units=not only_soc)
        bad = [r for r in res if not r[1]]
        if not bad:
            return (mut, "LOT", "")
        if "bien dich" in bad[0][0] or "loi bien dich" in bad[0][2]:
            return (mut, "LOI", "khong bien dich: " + bad[0][2])
        return (mut, "BAT", bad[0][0])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--only", default="")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    sw = os.path.join(run_soc.HERE, "sw", "build_axi")
    muts = [x for x in M if a.only in x[0] or a.only in x[4]]
    if a.check:
        bad = 0
        for mut in muts:
            s = open(os.path.join(ROOT, "soc", mut[1])).read()
            n = s.count(mut[2])
            if n != 1:
                bad += 1; print("[mutate-axi] %s: old xuat hien %d lan" % (mut[0], n))
        print("[mutate-axi] kiem %d dot bien: %s" % (len(muts), "tat ca ap dung duoc" if not bad else "%d loi" % bad))
        sys.exit(1 if bad else 0)
    print("[mutate-axi] %d dot bien, %d luong" % (len(muts), a.jobs), flush=True)
    caught, missed, errors, by = 0, [], [], {}
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for k, (mut, st, info) in enumerate(ex.map(lambda x: run_one(x, sw), muts), 1):
            i, f, old, new, d = mut
            if st == "BAT":
                caught += 1; by[info] = by.get(info, 0) + 1
            elif st == "LOT":
                missed.append((i, d))
            else:
                errors.append((i, info))
            print("[%3d/%d] %-4s %-52s %s %s" % (k, len(muts), i, d[:52], st, info), flush=True)
    print("[mutate-axi] bat %d / %d dot bien" % (caught, len(muts)))
    print("[mutate-axi] bat boi:", ", ".join("%s %d" % kv for kv in sorted(by.items(), key=lambda kv: -kv[1])))
    for i, d in missed:
        print("[mutate-axi] LOT:", i, d)
    for i, e in errors:
        print("[mutate-axi] LOI:", i, e)
    sys.exit(0 if not missed and not errors else 1)


if __name__ == "__main__":
    main()
