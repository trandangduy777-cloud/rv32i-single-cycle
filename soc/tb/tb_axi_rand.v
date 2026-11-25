`timescale 1ns/1ps
// Testbench ngau nhien 3 master x 3 slave (RAM0, RAM1, ROM + vung DECERR) cho axi_xbar + axi_mem, co mo hinh bo nho tham chieu va axi_checker o moi cong.
// Moi master: tien trinh A (ghi burst vao cua so rieng 0x400 byte cua minh roi doc lai kiem du lieu, ghi ROM phai SLVERR, ghi vung trong phai DECERR) va
// tien trinh B (doc burst ngau nhien vao cua so cua master khac - khong kiem du lieu vi dang bi ghi -, ROM va vung trong - kiem du lieu). Doc nhieu giao dich cung luc (toi da NSLOT).
// Tham so dong lenh: +ops=<so thao tac A moi master> +rd=<so lan doc B moi master> +seed=<hat>
module tb_axi_rand;
    localparam NM = 3, NS = 3, IDW = 4, SIDW = 6, NSLOT = 8;
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;
    integer NOPS = 300, NRD = 500, SEED = 1;
    integer errs = 0;
    reg hog = 1'b0, hog_run = 1'b0;      // pha kiem tra cong bang: moi master tranh 1 slave lien tuc

    // ---------------- sinh so ngau nhien (xorshift32), moi luong 1 trang thai ----------------
    reg [31:0] rs [0:8];
    function [31:0] rnd(input integer k);
        reg [31:0] x;
        begin x = rs[k]; x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5); rs[k] = x; rnd = x; end
    endfunction

    // ---------------- cong master (reg theo mang) ----------------
    reg [IDW-1:0] awid_r [0:NM-1]; reg [31:0] awaddr_r [0:NM-1]; reg [7:0] awlen_r [0:NM-1]; reg [2:0] awsize_r [0:NM-1]; reg [1:0] awburst_r [0:NM-1]; reg awvalid_r [0:NM-1];
    reg [31:0] wdata_r [0:NM-1]; reg [3:0] wstrb_r [0:NM-1]; reg wlast_r [0:NM-1]; reg wvalid_r [0:NM-1]; reg bready_r [0:NM-1];
    reg [IDW-1:0] arid_r [0:NM-1]; reg [31:0] araddr_r [0:NM-1]; reg [7:0] arlen_r [0:NM-1]; reg [2:0] arsize_r [0:NM-1]; reg [1:0] arburst_r [0:NM-1]; reg arvalid_r [0:NM-1]; reg rready_r [0:NM-1];
    wire [NM-1:0] s_awready, s_wready, s_bvalid, s_arready, s_rlast, s_rvalid;
    wire [NM*IDW-1:0] s_bid, s_rid; wire [NM*2-1:0] s_bresp, s_rresp; wire [NM*32-1:0] s_rdata;
    wire [NM*IDW-1:0] f_awid = {awid_r[2], awid_r[1], awid_r[0]};
    wire [NM*32-1:0]  f_awaddr = {awaddr_r[2], awaddr_r[1], awaddr_r[0]};
    wire [NM*8-1:0]   f_awlen = {awlen_r[2], awlen_r[1], awlen_r[0]};
    wire [NM*3-1:0]   f_awsize = {awsize_r[2], awsize_r[1], awsize_r[0]};
    wire [NM*2-1:0]   f_awburst = {awburst_r[2], awburst_r[1], awburst_r[0]};
    wire [NM-1:0]     f_awvalid = {awvalid_r[2], awvalid_r[1], awvalid_r[0]};
    wire [NM*32-1:0]  f_wdata = {wdata_r[2], wdata_r[1], wdata_r[0]};
    wire [NM*4-1:0]   f_wstrb = {wstrb_r[2], wstrb_r[1], wstrb_r[0]};
    wire [NM-1:0]     f_wlast = {wlast_r[2], wlast_r[1], wlast_r[0]};
    wire [NM-1:0]     f_wvalid = {wvalid_r[2], wvalid_r[1], wvalid_r[0]};
    wire [NM-1:0]     f_bready = {bready_r[2], bready_r[1], bready_r[0]};
    wire [NM*IDW-1:0] f_arid = {arid_r[2], arid_r[1], arid_r[0]};
    wire [NM*32-1:0]  f_araddr = {araddr_r[2], araddr_r[1], araddr_r[0]};
    wire [NM*8-1:0]   f_arlen = {arlen_r[2], arlen_r[1], arlen_r[0]};
    wire [NM*3-1:0]   f_arsize = {arsize_r[2], arsize_r[1], arsize_r[0]};
    wire [NM*2-1:0]   f_arburst = {arburst_r[2], arburst_r[1], arburst_r[0]};
    wire [NM-1:0]     f_arvalid = {arvalid_r[2], arvalid_r[1], arvalid_r[0]};
    wire [NM-1:0]     f_rready = {rready_r[2], rready_r[1], rready_r[0]};

    // ---------------- cong slave ----------------
    wire [NS*SIDW-1:0] m_awid, m_bid, m_arid, m_rid; wire [NS*32-1:0] m_awaddr, m_wdata, m_araddr, m_rdata; wire [NS*8-1:0] m_awlen, m_arlen;
    wire [NS*3-1:0] m_awsize, m_arsize; wire [NS*2-1:0] m_awburst, m_arburst, m_bresp, m_rresp; wire [NS*4-1:0] m_wstrb;
    wire [NS-1:0] m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;

    axi_xbar #(.NM(NM), .NS(NS), .IDW(IDW), .NR(3),
        .R_BASE({32'h0000_0000, 32'h3000_0000, 32'h1000_0000}), .R_MASK({32'hFFFF_F000, 32'hFFFF_F000, 32'hFFFF_F000}), .R_SLV({8'd2, 8'd1, 8'd0}), .MAXOUT(4)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_awid(f_awid), .s_awaddr(f_awaddr), .s_awlen(f_awlen), .s_awsize(f_awsize), .s_awburst(f_awburst), .s_awvalid(f_awvalid), .s_awready(s_awready),
        .s_wdata(f_wdata), .s_wstrb(f_wstrb), .s_wlast(f_wlast), .s_wvalid(f_wvalid), .s_wready(s_wready),
        .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(f_bready),
        .s_arid(f_arid), .s_araddr(f_araddr), .s_arlen(f_arlen), .s_arsize(f_arsize), .s_arburst(f_arburst), .s_arvalid(f_arvalid), .s_arready(s_arready),
        .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(f_rready),
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready));

    `define SLV(S, P, ROMV, RL, ST, BD, SD) axi_mem #(.WORDS(1024), .ROM(ROMV), .IDW(SIDW), .RLAT(RL), .STALL(ST), .BDLY(BD), .SEED(SD)) P ( \
        .clk(clk), .rst_n(rst_n), \
        .awid(m_awid[S*SIDW +: SIDW]), .awaddr(m_awaddr[S*32 +: 32]), .awlen(m_awlen[S*8 +: 8]), .awsize(m_awsize[S*3 +: 3]), .awburst(m_awburst[S*2 +: 2]), .awvalid(m_awvalid[S]), .awready(m_awready[S]), \
        .wdata(m_wdata[S*32 +: 32]), .wstrb(m_wstrb[S*4 +: 4]), .wlast(m_wlast[S]), .wvalid(m_wvalid[S]), .wready(m_wready[S]), \
        .bid(m_bid[S*SIDW +: SIDW]), .bresp(m_bresp[S*2 +: 2]), .bvalid(m_bvalid[S]), .bready(m_bready[S]), \
        .arid(m_arid[S*SIDW +: SIDW]), .araddr(m_araddr[S*32 +: 32]), .arlen(m_arlen[S*8 +: 8]), .arsize(m_arsize[S*3 +: 3]), .arburst(m_arburst[S*2 +: 2]), .arvalid(m_arvalid[S]), .arready(m_arready[S]), \
        .rid(m_rid[S*SIDW +: SIDW]), .rdata(m_rdata[S*32 +: 32]), .rresp(m_rresp[S*2 +: 2]), .rlast(m_rlast[S]), .rvalid(m_rvalid[S]), .rready(m_rready[S]));
    `SLV(0, ram0, 0, 0, 4, 0, 16'hACE1)
    `SLV(1, ram1, 0, 3, 8, 14, 16'h1D2B)
    `SLV(2, rom0, 1, 1, 0, 3, 16'h77A3)

    // ---------------- bo kiem giao thuc o 3 cong master va 3 cong slave ----------------
    genvar gi;
    generate
        for (gi = 0; gi < NM; gi = gi + 1) begin : gm
            axi_checker #(.NAME(gi == 0 ? "M0" : gi == 1 ? "M1" : "M2"), .IDW(IDW)) chk (.clk(clk), .rst_n(rst_n),
                .awid(f_awid[gi*IDW +: IDW]), .awaddr(f_awaddr[gi*32 +: 32]), .awlen(f_awlen[gi*8 +: 8]), .awsize(f_awsize[gi*3 +: 3]), .awburst(f_awburst[gi*2 +: 2]), .awvalid(f_awvalid[gi]), .awready(s_awready[gi]),
                .wdata(f_wdata[gi*32 +: 32]), .wstrb(f_wstrb[gi*4 +: 4]), .wlast(f_wlast[gi]), .wvalid(f_wvalid[gi]), .wready(s_wready[gi]),
                .bid(s_bid[gi*IDW +: IDW]), .bresp(s_bresp[gi*2 +: 2]), .bvalid(s_bvalid[gi]), .bready(f_bready[gi]),
                .arid(f_arid[gi*IDW +: IDW]), .araddr(f_araddr[gi*32 +: 32]), .arlen(f_arlen[gi*8 +: 8]), .arsize(f_arsize[gi*3 +: 3]), .arburst(f_arburst[gi*2 +: 2]), .arvalid(f_arvalid[gi]), .arready(s_arready[gi]),
                .rid(s_rid[gi*IDW +: IDW]), .rdata(s_rdata[gi*32 +: 32]), .rresp(s_rresp[gi*2 +: 2]), .rlast(s_rlast[gi]), .rvalid(s_rvalid[gi]), .rready(f_rready[gi]));
        end
        for (gi = 0; gi < NS; gi = gi + 1) begin : gs
            axi_checker #(.NAME(gi == 0 ? "S0" : gi == 1 ? "S1" : "S2"), .IDW(SIDW)) chk (.clk(clk), .rst_n(rst_n),
                .awid(m_awid[gi*SIDW +: SIDW]), .awaddr(m_awaddr[gi*32 +: 32]), .awlen(m_awlen[gi*8 +: 8]), .awsize(m_awsize[gi*3 +: 3]), .awburst(m_awburst[gi*2 +: 2]), .awvalid(m_awvalid[gi]), .awready(m_awready[gi]),
                .wdata(m_wdata[gi*32 +: 32]), .wstrb(m_wstrb[gi*4 +: 4]), .wlast(m_wlast[gi]), .wvalid(m_wvalid[gi]), .wready(m_wready[gi]),
                .bid(m_bid[gi*SIDW +: SIDW]), .bresp(m_bresp[gi*2 +: 2]), .bvalid(m_bvalid[gi]), .bready(m_bready[gi]),
                .arid(m_arid[gi*SIDW +: SIDW]), .araddr(m_araddr[gi*32 +: 32]), .arlen(m_arlen[gi*8 +: 8]), .arsize(m_arsize[gi*3 +: 3]), .arburst(m_arburst[gi*2 +: 2]), .arvalid(m_arvalid[gi]), .arready(m_arready[gi]),
                .rid(m_rid[gi*SIDW +: SIDW]), .rdata(m_rdata[gi*32 +: 32]), .rresp(m_rresp[gi*2 +: 2]), .rlast(m_rlast[gi]), .rvalid(m_rvalid[gi]), .rready(m_rready[gi]));
        end
    endgenerate

    // ---------------- mo hinh tham chieu: 3 vung 4 KB (RAM0, RAM1, ROM) theo byte ----------------
    reg [7:0] refm [0:3*4096-1];
    function integer sel(input [31:0] a);
        begin
            case (a[31:12])
                20'h10000: sel = 0;
                20'h30000: sel = 1;
                20'h00000: sel = 2;
                default:   sel = -1;
            endcase
        end
    endfunction
    function [31:0] nxtaddr(input [31:0] a, input [2:0] sz, input [1:0] bt, input [7:0] ln);
        reg [31:0] step, wrap, inc;
        begin
            step = 32'd1 << sz; inc = (a & ~(step - 32'd1)) + step; wrap = ({24'd0, ln} + 32'd1) << sz;
            case (bt) 2'b00: nxtaddr = a; 2'b10: nxtaddr = (a & ~(wrap - 32'd1)) | (inc & (wrap - 32'd1)); default: nxtaddr = inc; endcase
        end
    endfunction
    function [3:0] lmask(input [31:0] a, input [2:0] sz, input first);
        integer lo, hi, i, szb, cb;
        begin
            szb = 1 << sz; cb = (a & ~(szb - 1)) & 3; lo = first ? (a & 3) : cb; hi = cb + szb; lmask = 4'd0;
            for (i = lo; i < hi; i = i + 1) lmask[i] = 1'b1;
        end
    endfunction

    // ---------------- hang doi doc moi master ----------------
    reg [1:0]  s_state [0:NM*NSLOT-1];    // 0 trong, 1 cho phat AR, 2 da phat AR (cho R), 3 xong (tien trinh A se giai phong)
    reg        s_own   [0:NM*NSLOT-1];
    reg        s_chk   [0:NM*NSLOT-1];
    reg [IDW-1:0] s_id [0:NM*NSLOT-1]; reg [31:0] s_addr [0:NM*NSLOT-1]; reg [7:0] s_len [0:NM*NSLOT-1]; reg [2:0] s_size [0:NM*NSLOT-1]; reg [1:0] s_burst [0:NM*NSLOT-1];
    reg [1:0]  s_exr   [0:NM*NSLOT-1];
    integer    s_got   [0:NM*NSLOT-1];
    reg [31:0] s_exd [0:NM*NSLOT*64-1]; reg [31:0] s_msk [0:NM*NSLOT*64-1];
    integer tailp [0:NM-1], headp [0:NM-1], rp [0:NM-1];
    reg [31:0] wd_m [0:NM*64-1]; reg [3:0] ws_m [0:NM*64-1];
    integer nrd_done = 0, nwr_done = 0, fin = 0;

    // sinh 1 burst hop le trong cua so [base, base + wsize)
    task automatic gen_burst(input integer k, input [31:0] base, input integer wsize, output [31:0] a, output [7:0] ln, output [2:0] sz, output [1:0] bt);
        reg [31:0] r; integer bytes, off, szb, c;
        begin
            r = rnd(k); sz = r[9:8] % 3; szb = 1 << sz;
            case (r[2:0])
                3'd0: bt = 2'b00;
                3'd1, 3'd2: bt = 2'b10;
                default: bt = 2'b01;
            endcase
            r = rnd(k);
            case (bt)
                2'b00: begin ln = r[3:0]; off = (rnd(k) % wsize) & ~(szb - 1); end
                2'b10: begin c = r[1:0]; ln = (c == 0) ? 1 : (c == 1) ? 3 : (c == 2) ? 7 : 15; off = (rnd(k) % wsize) & ~(szb - 1); end
                default: begin
                    ln = r[4:0]; bytes = (ln + 1) << sz; if (bytes > wsize) begin ln = 0; bytes = szb; end
                    off = rnd(k) % (wsize - bytes + 1);
                end
            endcase
            a = base + off;
        end
    endtask

    // tinh du lieu / mat na mong doi cho 1 giao dich doc kiem tra
    task automatic fill_exp(input integer idx, input [31:0] a, input [7:0] ln, input [2:0] sz, input [1:0] bt);
        integer b, sl, bi; reg [31:0] ba, w, mk; reg [3:0] lm;
        begin
            sl = sel(a); ba = a;
            s_exr[idx] = (sl < 0) ? 2'b11 : 2'b00;
            for (b = 0; b <= ln; b = b + 1) begin
                lm = (sl < 0) ? 4'hF : lmask(ba, sz, b == 0);
                mk = {{8{lm[3]}}, {8{lm[2]}}, {8{lm[1]}}, {8{lm[0]}}};
                if (sl < 0) w = 32'd0;
                else begin bi = sl * 4096 + (ba[11:0] & 12'hFFC); w = {refm[bi+3], refm[bi+2], refm[bi+1], refm[bi]}; end
                s_exd[idx*64 + b] = w; s_msk[idx*64 + b] = mk;
                ba = nxtaddr(ba, sz, bt, ln);
            end
        end
    endtask

    // dat 1 giao dich doc vao hang doi (khong tre neu con cho trong)
    task automatic enq(input integer m, input [31:0] a, input [7:0] ln, input [2:0] sz, input [1:0] bt, input [IDW-1:0] id, input chk, input own, output integer idx);
        begin
            while (s_state[m*NSLOT + (tailp[m] % NSLOT)] != 2'd0) @(posedge clk);
            idx = m*NSLOT + (tailp[m] % NSLOT); tailp[m] = tailp[m] + 1;
            s_id[idx] = id; s_addr[idx] = a; s_len[idx] = ln; s_size[idx] = sz; s_burst[idx] = bt; s_chk[idx] = chk; s_own[idx] = own; s_got[idx] = 0;
            if (chk) fill_exp(idx, a, ln, sz, bt);
            s_state[idx] = 2'd1;
        end
    endtask

    // hang doi B mong doi cua moi master (thu tu phat), toi da 4 giao dich ghi dang bay
    reg [IDW-1:0] exb_id [0:NM*8-1]; reg [1:0] exb_r [0:NM*8-1]; reg [31:0] exb_a [0:NM*8-1]; integer exb_h [0:NM-1], exb_t [0:NM-1];

    // phat 1 burst ghi (AW va W chay song song, thu tu va do tre ngau nhien), cap nhat mo hinh tham chieu, xep B mong doi vao hang doi; khong cho B
    task automatic wr_issue(input integer m, input [31:0] a, input [7:0] ln, input [2:0] sz, input [1:0] bt, input [IDW-1:0] id);
        integer b, sl, k; reg [31:0] ba; reg [3:0] lm; reg [1:0] exr; reg [31:0] r;
        begin
            sl = sel(a); exr = (sl < 0) ? 2'b11 : (sl == 2) ? 2'b10 : 2'b00; ba = a;
            for (b = 0; b <= ln; b = b + 1) begin
                lm = lmask(ba, sz, b == 0); r = rnd(m);
                wd_m[m*64 + b] = rnd(m); ws_m[m*64 + b] = r[3:0] & lm;
                if (sl == 0 || sl == 1)
                    for (k = 0; k < 4; k = k + 1) if (ws_m[m*64 + b][k]) refm[sl*4096 + (ba[11:0] & 12'hFFC) + k] = wd_m[m*64 + b][8*k +: 8];
                ba = nxtaddr(ba, sz, bt, ln);
            end
            exb_id[m*8 + (exb_t[m] % 8)] = id; exb_r[m*8 + (exb_t[m] % 8)] = exr; exb_a[m*8 + (exb_t[m] % 8)] = a; exb_t[m] = exb_t[m] + 1;
            fork
                begin : thr_aw
                    repeat (rnd(m) % 5) @(posedge clk);
                    awid_r[m] <= id; awaddr_r[m] <= a; awlen_r[m] <= ln; awsize_r[m] <= sz; awburst_r[m] <= bt; awvalid_r[m] <= 1'b1;
                    @(posedge clk); while (!s_awready[m]) @(posedge clk);
                    awvalid_r[m] <= 1'b0;
                end
                begin : thr_w
                    integer bb, gap;
                    repeat (rnd(m) % 5) @(posedge clk);
                    for (bb = 0; bb <= ln; bb = bb + 1) begin
                        wdata_r[m] <= wd_m[m*64 + bb]; wstrb_r[m] <= ws_m[m*64 + bb]; wlast_r[m] <= (bb == ln); wvalid_r[m] <= 1'b1;
                        @(posedge clk); while (!s_wready[m]) @(posedge clk);
                        gap = (rnd(m) % 4 == 0) ? (rnd(m) % 3) : 0;
                        if (bb == ln || gap > 0) wvalid_r[m] <= 1'b0;
                        repeat (gap) @(posedge clk);
                    end
                    wvalid_r[m] <= 1'b0;
                end
            join
        end
    endtask

    // cho moi B da phat deu da ve (nhan B do bo thu B rieng, doc lap voi viec phat AW / W)
    task automatic wr_collect_all(input integer m);
        begin
            while (exb_h[m] != exb_t[m]) @(posedge clk);
        end
    endtask

    // bo thu B: bready ngau nhien, doc lap voi AW / W; moi B so voi hang doi mong doi cua master
    integer bm, bh;
    always @(posedge clk) if (rst_n && !hog) begin : bmon
        for (bm = 0; bm < NM; bm = bm + 1) begin
            if (s_bvalid[bm] && bready_r[bm]) begin
                if (exb_h[bm] == exb_t[bm]) begin errs = errs + 1; $display("[TB] M%0d B: nhan B khi khong co giao dich ghi nao dang cho", bm); end
                else begin
                    bh = bm*8 + (exb_h[bm] % 8);
                    if (s_bid[bm*IDW +: IDW] !== exb_id[bh]) begin errs = errs + 1; $display("[TB] M%0d B: BID %0d khac %0d (sai thu tu B?)", bm, s_bid[bm*IDW +: IDW], exb_id[bh]); end
                    if (s_bresp[bm*2 +: 2] !== exb_r[bh]) begin errs = errs + 1; $display("[TB] M%0d B: BRESP %0d khac mong doi %0d (dia chi %h)", bm, s_bresp[bm*2 +: 2], exb_r[bh], exb_a[bh]); end
                    exb_h[bm] = exb_h[bm] + 1; nwr_done = nwr_done + 1;
                end
            end
            bready_r[bm] <= (rnd(6 + bm) % 4) != 0;
        end
    end
    // ---------------- tien trinh A moi master ----------------
    task automatic proc_a(input integer m);
        integer i, g, ng, sidx, idx, j; reg [31:0] a, ra; reg [7:0] ln, rln; reg [2:0] sz, rsz; reg [1:0] bt, rbt; reg [31:0] r; reg [31:0] base;
        reg [31:0] ga [0:3]; reg [7:0] gl [0:3]; reg [2:0] gs [0:3]; reg [1:0] gb [0:3]; integer gk [0:3];
        begin
            for (i = 0; i < NOPS; i = i + 1) begin
                r = rnd(m); ng = 1 + (r[5:4] % 3);                    // 1..3 giao dich ghi lien tiep (toi cac slave khac nhau), roi cho het B
                for (g = 0; g < ng; g = g + 1) begin
                    sidx = rnd(m) & 7; gk[g] = sidx;
                    if (sidx <= 3) base = 32'h1000_0000 + m*32'h400;
                    else if (sidx <= 5) base = 32'h3000_0000 + m*32'h400;
                    else if (sidx == 6) base = 32'h0;
                    else base = 32'h5000_0000;
                    gen_burst(m, base, (sidx == 6) ? 4096 : 1024, a, ln, sz, bt);
                    ga[g] = a; gl[g] = ln; gs[g] = sz; gb[g] = bt;
                    wr_issue(m, a, ln, sz, bt, rnd(m));
                end
                wr_collect_all(m);
                // doc kiem tra lai: moi giao dich vua ghi (dung vung do), ROM va vung trong
                for (g = 0; g < ng; g = g + 1) begin
                    enq(m, ga[g], gl[g], gs[g], gb[g], rnd(m), 1'b1, 1'b1, idx);
                    while (s_state[idx] != 2'd3) @(posedge clk);
                    s_state[idx] = 2'd0;
                end
                // them 1 doc ngau nhien trong cua so cua minh (du lieu da on dinh)
                sidx = rnd(m) & 1; base = (sidx ? 32'h3000_0000 : 32'h1000_0000) + m*32'h400;
                gen_burst(m, base, 1024, ra, rln, rsz, rbt);
                enq(m, ra, rln, rsz, rbt, rnd(m), 1'b1, 1'b1, idx);
                while (s_state[idx] != 2'd3) @(posedge clk);
                s_state[idx] = 2'd0;
            end
            fin = fin + 1;
        end
    endtask

    // ---------------- tien trinh B moi master ----------------
    task automatic proc_b(input integer m);
        integer i, idx, k; reg [31:0] a, r, base; reg [7:0] ln; reg [2:0] sz; reg [1:0] bt;
        begin
            for (i = 0; i < NRD; i = i + 1) begin
                r = rnd(3 + m); k = r[1:0];
                case (k)
                    0: begin base = 32'h1000_0000 + (rnd(3+m) % 3)*32'h400; gen_burst(3 + m, base, 1024, a, ln, sz, bt); enq(m, a, ln, sz, bt, rnd(3+m), 1'b0, 1'b0, idx); end
                    1: begin base = 32'h3000_0000 + (rnd(3+m) % 3)*32'h400; gen_burst(3 + m, base, 1024, a, ln, sz, bt); enq(m, a, ln, sz, bt, rnd(3+m), 1'b0, 1'b0, idx); end
                    2: begin gen_burst(3 + m, 32'h0, 4096, a, ln, sz, bt); enq(m, a, ln, sz, bt, rnd(3+m), 1'b1, 1'b0, idx); end
                    default: begin gen_burst(3 + m, 32'h5000_0000, 1024, a, ln, sz, bt); enq(m, a, ln, sz, bt, rnd(3+m), 1'b1, 1'b0, idx); end
                endcase
                repeat (rnd(3+m) % 6) @(posedge clk);
            end
            fin = fin + 1;
        end
    endtask

    // ---------------- phat AR cho tung master ----------------
    task automatic proc_ar(input integer m);
        integer idx;
        begin
            forever begin
                idx = m*NSLOT + (headp[m] % NSLOT);
                while (s_state[idx] != 2'd1) @(posedge clk);
                repeat (rnd(6+m) % 4) @(posedge clk);
                arid_r[m] <= s_id[idx]; araddr_r[m] <= s_addr[idx]; arlen_r[m] <= s_len[idx]; arsize_r[m] <= s_size[idx]; arburst_r[m] <= s_burst[idx]; arvalid_r[m] <= 1'b1;
                @(posedge clk); while (!s_arready[m]) @(posedge clk);
                arvalid_r[m] <= 1'b0; s_state[idx] = 2'd2; headp[m] = headp[m] + 1;
            end
        end
    endtask

    // ---------------- nhan R va kiem tra ----------------
    integer rm, ridx, rb;
    always @(posedge clk) if (rst_n && !hog) begin : rmon
        for (rm = 0; rm < NM; rm = rm + 1) begin
            if (s_rvalid[rm] && rready_r[rm]) begin
                ridx = rm*NSLOT + (rp[rm] % NSLOT); rb = s_got[ridx];
                if (s_state[ridx] != 2'd2) begin errs = errs + 1; $display("[TB] M%0d R: beat khi khong co AR dang cho", rm); end
                else begin
                    if (s_rid[rm*IDW +: IDW] !== s_id[ridx]) begin errs = errs + 1; $display("[TB] M%0d R: RID %0d khac %0d (sai thu tu?)", rm, s_rid[rm*IDW +: IDW], s_id[ridx]); end
                    if (s_chk[ridx] && s_rresp[rm*2 +: 2] !== s_exr[ridx]) begin errs = errs + 1; $display("[TB] M%0d R: RRESP %0d khac %0d (dia chi %h beat %0d)", rm, s_rresp[rm*2 +: 2], s_exr[ridx], s_addr[ridx], rb); end
                    if (s_rlast[rm] !== (rb == s_len[ridx])) begin errs = errs + 1; $display("[TB] M%0d R: RLAST sai beat %0d / len %0d", rm, rb, s_len[ridx]); end
                    if (s_chk[ridx] && ((s_rdata[rm*32 +: 32] ^ s_exd[ridx*64 + rb]) & s_msk[ridx*64 + rb]) != 0) begin
                        errs = errs + 1; $display("[TB] M%0d R: du lieu %h khac mong doi %h (dia chi %h beat %0d mask %h)", rm, s_rdata[rm*32 +: 32], s_exd[ridx*64 + rb], s_addr[ridx], rb, s_msk[ridx*64 + rb]);
                    end
                    s_got[ridx] = rb + 1;
                    if (rb == s_len[ridx]) begin
                        s_state[ridx] = s_own[ridx] ? 2'd3 : 2'd0; rp[rm] = rp[rm] + 1; nrd_done = nrd_done + 1;
                    end
                end
            end
            rready_r[rm] <= (rnd(6 + rm) % 4) != 0;
        end
    end


    // ---------------- pha cong bang: 3 master cung doc / ghi burst 4 beat vao RAM1 lien tuc, so giao dich duoc cap cua tung master phai gan bang nhau ----------------
    integer ar_c [0:NM-1], aw_c [0:NM-1], w_c [0:NM-1];
    integer hm, nb;
    always @(posedge clk) if (hog) begin : hogdrv
        for (hm = 0; hm < NM; hm = hm + 1) begin
            if (arvalid_r[hm] && s_arready[hm]) begin ar_c[hm] = ar_c[hm] + 1; if (!hog_run) arvalid_r[hm] <= 1'b0; end
            if (awvalid_r[hm] && s_awready[hm]) begin aw_c[hm] = aw_c[hm] + 1; if (!hog_run) awvalid_r[hm] <= 1'b0; end
            nb = w_c[hm] + ((wvalid_r[hm] && s_wready[hm]) ? 1 : 0); w_c[hm] = nb;
            wlast_r[hm] <= ((nb % 4) == 3); wvalid_r[hm] <= hog_run || (nb < 4 * aw_c[hm]) || (wvalid_r[hm] && !s_wready[hm]);
            rready_r[hm] <= 1'b1; bready_r[hm] <= 1'b1;
        end
    end
    task fair_phase;
        integer m, mxr, mnr, mxw, mnw;
        begin
            for (m = 0; m < NM; m = m + 1) begin
                ar_c[m] = 0; aw_c[m] = 0; w_c[m] = 0;
                arid_r[m] <= m; araddr_r[m] <= 32'h3000_0000 + m*32'h400; arlen_r[m] <= 8'd3; arsize_r[m] <= 3'd2; arburst_r[m] <= 2'b01; arvalid_r[m] <= 1'b1;
                awid_r[m] <= m; awaddr_r[m] <= 32'h3000_0000 + m*32'h400; awlen_r[m] <= 8'd3; awsize_r[m] <= 3'd2; awburst_r[m] <= 2'b01; awvalid_r[m] <= 1'b1;
                wdata_r[m] <= 32'd0; wstrb_r[m] <= 4'd0; wlast_r[m] <= 1'b0; wvalid_r[m] <= 1'b1;
            end
            hog = 1'b1; hog_run = 1'b1;
            repeat (3000) @(posedge clk);
            hog_run = 1'b0;
            repeat (400) @(posedge clk);
            hog = 1'b0;
            mxr = ar_c[0]; mnr = ar_c[0]; mxw = aw_c[0]; mnw = aw_c[0];
            for (m = 1; m < NM; m = m + 1) begin
                if (ar_c[m] > mxr) mxr = ar_c[m]; if (ar_c[m] < mnr) mnr = ar_c[m];
                if (aw_c[m] > mxw) mxw = aw_c[m]; if (aw_c[m] < mnw) mnw = aw_c[m];
            end
            $display("[TB] cong bang: doc %0d/%0d/%0d, ghi %0d/%0d/%0d (AR / AW duoc cap cua master 0/1/2 trong 3000 chu ky tranh chap)", ar_c[0], ar_c[1], ar_c[2], aw_c[0], aw_c[1], aw_c[2]);
            if (mxr - mnr > 2 || mnr < 20) begin errs = errs + 1; $display("[TB] LOI cong bang kenh doc: lech %0d (min %0d)", mxr - mnr, mnr); end
            if (mxw - mnw > 2 || mnw < 20) begin errs = errs + 1; $display("[TB] LOI cong bang kenh ghi: lech %0d (min %0d)", mxw - mnw, mnw); end
        end
    endtask

    // ---------------- dieu phoi ----------------
    integer i0, cyc = 0, tot, w, j, errc, bad;
    reg [31:0] rw;
    always @(posedge clk) begin cyc <= cyc + 1; if (cyc > 300000) begin $display("[TB] HET GIO (nghi deadlock): fin=%0d wr=%0d rd=%0d", fin, nwr_done, nrd_done); $display("[AXI_RAND] FAIL"); $finish; end end
    initial begin
        if (!$value$plusargs("ops=%d", NOPS)) NOPS = 300;
        if (!$value$plusargs("rd=%d", NRD)) NRD = 500;
        if (!$value$plusargs("seed=%d", SEED)) SEED = 1;
        for (i0 = 0; i0 < 9; i0 = i0 + 1) rs[i0] = 32'h9E3779B9 * (i0 + 1) + SEED * 32'h85EBCA6B + 32'd12345;
        for (i0 = 0; i0 < 9; i0 = i0 + 1) begin rnd(i0); rnd(i0); end
        for (i0 = 0; i0 < NM; i0 = i0 + 1) begin
            awvalid_r[i0] = 0; wvalid_r[i0] = 0; bready_r[i0] = 0; arvalid_r[i0] = 0; rready_r[i0] = 0;
            awid_r[i0] = 0; awaddr_r[i0] = 0; awlen_r[i0] = 0; awsize_r[i0] = 0; awburst_r[i0] = 0; wdata_r[i0] = 0; wstrb_r[i0] = 0; wlast_r[i0] = 0;
            arid_r[i0] = 0; araddr_r[i0] = 0; arlen_r[i0] = 0; arsize_r[i0] = 0; arburst_r[i0] = 0; tailp[i0] = 0; headp[i0] = 0; rp[i0] = 0; exb_h[i0] = 0; exb_t[i0] = 0;
        end
        for (i0 = 0; i0 < NM*NSLOT; i0 = i0 + 1) begin s_state[i0] = 0; s_got[i0] = 0; end
        for (i0 = 0; i0 < 1024; i0 = i0 + 1) begin
            ram0.mem[i0] = 32'd0; ram1.mem[i0] = 32'd0;
            rw = 32'hA5C3_0000 ^ (i0 * 32'h0101_0193) ^ (i0 << 7); rom0.mem[i0] = rw;
            refm[8192 + 4*i0] = rw[7:0]; refm[8192 + 4*i0 + 1] = rw[15:8]; refm[8192 + 4*i0 + 2] = rw[23:16]; refm[8192 + 4*i0 + 3] = rw[31:24];
        end
        for (i0 = 0; i0 < 8192; i0 = i0 + 1) refm[i0] = 8'd0;
        repeat (5) @(posedge clk); rst_n = 1'b1; @(posedge clk);
        fork
            proc_a(0); proc_a(1); proc_a(2); proc_b(0); proc_b(1); proc_b(2);
            proc_ar(0); proc_ar(1); proc_ar(2);
        join
    end
    // ket thuc: dung khoi rieng de tranh `disable` len fork
    initial begin : fork_end
        wait (rst_n);
        forever @(posedge clk) if (fin >= 2*NM && nrd_done >= tailp[0] + tailp[1] + tailp[2] && cyc > 100) begin
            repeat (30) @(posedge clk);
            fair_phase;
            // so sanh toan bo bo nho RAM voi tham chieu (kiem byte strobe, burst, WRAP)
            bad = 0;
            for (w = 0; w < 1024; w = w + 1) begin
                if (ram0.mem[w] !== {refm[4*w+3], refm[4*w+2], refm[4*w+1], refm[4*w]}) begin bad = bad + 1; if (bad < 5) $display("[TB] RAM0[%0d] = %h khac tham chieu %h", w, ram0.mem[w], {refm[4*w+3], refm[4*w+2], refm[4*w+1], refm[4*w]}); end
                if (ram1.mem[w] !== {refm[4096+4*w+3], refm[4096+4*w+2], refm[4096+4*w+1], refm[4096+4*w]}) begin bad = bad + 1; if (bad < 5) $display("[TB] RAM1[%0d] = %h khac tham chieu", w, ram1.mem[w]); end
                if (rom0.mem[w] !== {refm[8192+4*w+3], refm[8192+4*w+2], refm[8192+4*w+1], refm[8192+4*w]}) begin bad = bad + 1; if (bad < 5) $display("[TB] ROM[%0d] bi doi", w); end
            end
            errs = errs + bad;
            gm[0].chk.final_check; gm[1].chk.final_check; gm[2].chk.final_check; gs[0].chk.final_check; gs[1].chk.final_check; gs[2].chk.final_check;
            errc = gm[0].chk.errors + gm[1].chk.errors + gm[2].chk.errors + gs[0].chk.errors + gs[1].chk.errors + gs[2].chk.errors;
            $display("[TB] %0d ghi, %0d doc xong, %0d chu ky | master: AW %0d W %0d AR %0d R %0d | loi TB %0d, loi checker %0d", nwr_done, nrd_done, cyc,
                     gm[0].chk.n_aw + gm[1].chk.n_aw + gm[2].chk.n_aw, gm[0].chk.n_w + gm[1].chk.n_w + gm[2].chk.n_w,
                     gm[0].chk.n_ar + gm[1].chk.n_ar + gm[2].chk.n_ar, gm[0].chk.n_r + gm[1].chk.n_r + gm[2].chk.n_r, errs, errc);
            if (errs + errc == 0) $display("[AXI_RAND] PASS %0d ghi, %0d doc, %0d chu ky, 0 loi", nwr_done, nrd_done, cyc); else $display("[AXI_RAND] FAIL");
            $finish;
        end
    end
endmodule
