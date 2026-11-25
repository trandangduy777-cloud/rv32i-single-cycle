// Interconnect AXI4 NM master x NS slave, 32 bit du lieu / dia chi, tu viet. 5 kenh, ID, burst FIXED / INCR / WRAP (di xuyen, khong cat nho), byte strobe.
// Khong co: LOCK, CACHE, PROT, QOS, REGION, USER (xem README, muc AXI4 + DMA).
// - Giai ma dia chi theo NR vung: vung i trung khi (addr & R_MASK[i]) == R_BASE[i], tro toi slave R_SLV[i]; khong vung nao trung -> slave noi bo tra DECERR
//   (ghi: nuot het W roi tra B; doc: tra du len + 1 beat du lieu 0, RLAST dung).
// - ID phia slave = {chi so master, ID cua master}; B va R duoc dinh tuyen nguoc theo chi so do.
// - Phan xu cong bang: moi slave co 1 bo phan xu vong tron rieng cho AW va cho AR; da cap thi giu (sticky) cho toi khi slave nhan, nen VALID khong tu ha.
// - Ghi: W di theo chu tu AW. Moi slave chi cho 1 giao dich o pha W cung luc (chu so huu `own`); cap AW la quyet dinh trong chu ky dau, W duoc chuyen tiep ngay
//   (khong cho AWREADY), nen slave doi ca AW lan W moi nhan van khong bi deadlock. Mot master chi co 1 giao dich o pha W; sau WLAST giao dich tiep theo
//   (cua bat ky master nao) co the vao trong khi B truoc con cho.
// - Thu tu: mot master co toi da MAXOUT giao dich chua xong, TAT CA toi cung 1 slave (ghi va doc tinh rieng); muon doi slave phai cho het. Nho do phan hoi
//   cua moi master luon den tu 1 slave, dung thu tu, nen khong can bo sap xep lai theo ID.
// - Khong co duong tu doc sang ghi (kenh doc va ghi doc lap), moi slave nhan W khong can doi gi cua master khac -> khong deadlock khi doc ghi dong thoi.
module axi_xbar #(
    parameter NM = 2,
    parameter NS = 2,
    parameter IDW = 4,
    parameter NR = 2,
    parameter [NR*32-1:0] R_BASE = 0,
    parameter [NR*32-1:0] R_MASK = 0,
    parameter [NR*8-1:0]  R_SLV  = 0,
    parameter MAXOUT = 4
) (
    input  wire clk,
    input  wire rst_n,
    // ---- cong phia master (xbar la slave), chi so m ----
    input  wire [NM*IDW-1:0] s_awid,    input  wire [NM*32-1:0] s_awaddr, input  wire [NM*8-1:0] s_awlen,
    input  wire [NM*3-1:0]   s_awsize,  input  wire [NM*2-1:0]  s_awburst, input wire [NM-1:0] s_awvalid, output wire [NM-1:0] s_awready,
    input  wire [NM*32-1:0]  s_wdata,   input  wire [NM*4-1:0]  s_wstrb,   input  wire [NM-1:0] s_wlast, input wire [NM-1:0] s_wvalid, output wire [NM-1:0] s_wready,
    output wire [NM*IDW-1:0] s_bid,     output wire [NM*2-1:0]  s_bresp,   output wire [NM-1:0] s_bvalid, input wire [NM-1:0] s_bready,
    input  wire [NM*IDW-1:0] s_arid,    input  wire [NM*32-1:0] s_araddr, input  wire [NM*8-1:0] s_arlen,
    input  wire [NM*3-1:0]   s_arsize,  input  wire [NM*2-1:0]  s_arburst, input wire [NM-1:0] s_arvalid, output wire [NM-1:0] s_arready,
    output wire [NM*IDW-1:0] s_rid,     output wire [NM*32-1:0] s_rdata,   output wire [NM*2-1:0] s_rresp, output wire [NM-1:0] s_rlast,
    output wire [NM-1:0]     s_rvalid,  input  wire [NM-1:0]    s_rready,
    // ---- cong phia slave (xbar la master), chi so s, ID rong IDW + clog2(NM) ----
    output wire [NS*(IDW+$clog2(NM))-1:0] m_awid,  output wire [NS*32-1:0] m_awaddr, output wire [NS*8-1:0] m_awlen,
    output wire [NS*3-1:0]   m_awsize,  output wire [NS*2-1:0]  m_awburst, output wire [NS-1:0] m_awvalid, input wire [NS-1:0] m_awready,
    output wire [NS*32-1:0]  m_wdata,   output wire [NS*4-1:0]  m_wstrb,   output wire [NS-1:0] m_wlast, output wire [NS-1:0] m_wvalid, input wire [NS-1:0] m_wready,
    input  wire [NS*(IDW+$clog2(NM))-1:0] m_bid,   input  wire [NS*2-1:0] m_bresp, input wire [NS-1:0] m_bvalid, output wire [NS-1:0] m_bready,
    output wire [NS*(IDW+$clog2(NM))-1:0] m_arid,  output wire [NS*32-1:0] m_araddr, output wire [NS*8-1:0] m_arlen,
    output wire [NS*3-1:0]   m_arsize,  output wire [NS*2-1:0]  m_arburst, output wire [NS-1:0] m_arvalid, input wire [NS-1:0] m_arready,
    input  wire [NS*(IDW+$clog2(NM))-1:0] m_rid,   input  wire [NS*32-1:0] m_rdata, input wire [NS*2-1:0] m_rresp, input wire [NS-1:0] m_rlast,
    input  wire [NS-1:0]     m_rvalid,  output wire [NS-1:0]    m_rready
);
    localparam LNM  = $clog2(NM);
    localparam SIDW = IDW + LNM;
    localparam NSX  = NS + 1;                 // them slave DECERR noi bo (chi so NS)
    localparam CW   = $clog2(MAXOUT + 1);     // do rong bo dem giao dich chua xong

    // ---------------- giai ma ----------------
    function [7:0] dec(input [31:0] a);
        integer i;
        begin
            dec = NS;
            for (i = 0; i < NR; i = i + 1)
                if ((a & R_MASK[i*32 +: 32]) == R_BASE[i*32 +: 32]) dec = R_SLV[i*8 +: 8];
        end
    endfunction

    // ---------------- vector noi bo phia slave (NSX muc) ----------------
    reg  [NSX*SIDW-1:0] f_awid;   reg [NSX*32-1:0] f_awaddr; reg [NSX*8-1:0] f_awlen; reg [NSX*3-1:0] f_awsize; reg [NSX*2-1:0] f_awburst;
    reg  [NSX-1:0]      f_awvalid;
    wire [NSX-1:0]      f_awready;
    reg  [NSX*32-1:0]   f_wdata;  reg [NSX*4-1:0] f_wstrb; reg [NSX-1:0] f_wlast, f_wvalid;
    wire [NSX-1:0]      f_wready;
    wire [NSX*SIDW-1:0] g_bid;    wire [NSX*2-1:0] g_bresp; wire [NSX-1:0] g_bvalid;
    reg  [NSX-1:0]      g_bready;
    reg  [NSX*SIDW-1:0] f_arid;   reg [NSX*32-1:0] f_araddr; reg [NSX*8-1:0] f_arlen; reg [NSX*3-1:0] f_arsize; reg [NSX*2-1:0] f_arburst;
    reg  [NSX-1:0]      f_arvalid;
    wire [NSX-1:0]      f_arready;
    wire [NSX*SIDW-1:0] g_rid;    wire [NSX*32-1:0] g_rdata; wire [NSX*2-1:0] g_rresp; wire [NSX-1:0] g_rlast, g_rvalid;
    reg  [NSX-1:0]      g_rready;

    assign f_awready[NS-1:0] = m_awready;
    assign f_wready[NS-1:0]  = m_wready;
    assign g_bid[NS*SIDW-1:0] = m_bid;  assign g_bresp[NS*2-1:0] = m_bresp; assign g_bvalid[NS-1:0] = m_bvalid;
    assign f_arready[NS-1:0] = m_arready;
    assign g_rid[NS*SIDW-1:0] = m_rid;  assign g_rdata[NS*32-1:0] = m_rdata; assign g_rresp[NS*2-1:0] = m_rresp;
    assign g_rlast[NS-1:0] = m_rlast;   assign g_rvalid[NS-1:0] = m_rvalid;

    assign m_awid = f_awid[NS*SIDW-1:0];   assign m_awaddr = f_awaddr[NS*32-1:0]; assign m_awlen = f_awlen[NS*8-1:0];
    assign m_awsize = f_awsize[NS*3-1:0];  assign m_awburst = f_awburst[NS*2-1:0]; assign m_awvalid = f_awvalid[NS-1:0];
    assign m_wdata = f_wdata[NS*32-1:0];   assign m_wstrb = f_wstrb[NS*4-1:0];    assign m_wlast = f_wlast[NS-1:0]; assign m_wvalid = f_wvalid[NS-1:0];
    assign m_bready = g_bready[NS-1:0];
    assign m_arid = f_arid[NS*SIDW-1:0];   assign m_araddr = f_araddr[NS*32-1:0]; assign m_arlen = f_arlen[NS*8-1:0];
    assign m_arsize = f_arsize[NS*3-1:0];  assign m_arburst = f_arburst[NS*2-1:0]; assign m_arvalid = f_arvalid[NS-1:0];
    assign m_rready = g_rready[NS-1:0];

    // ---------------- slave DECERR noi bo (chi so NS) ----------------
    reg [1:0]      e_wst;  reg [SIDW-1:0] e_wid;
    reg            e_rst;  reg [SIDW-1:0] e_rid;  reg [7:0] e_rlen, e_rcnt;
    assign f_awready[NS] = (e_wst == 2'd0);
    assign f_wready[NS]  = (e_wst == 2'd1);
    assign g_bvalid[NS]  = (e_wst == 2'd2);
    assign g_bid[NS*SIDW +: SIDW] = e_wid;
    assign g_bresp[NS*2 +: 2]     = 2'b11;
    assign f_arready[NS] = ~e_rst;
    assign g_rvalid[NS]  = e_rst;
    assign g_rid[NS*SIDW +: SIDW] = e_rid;
    assign g_rdata[NS*32 +: 32]   = 32'd0;
    assign g_rresp[NS*2 +: 2]     = 2'b11;
    assign g_rlast[NS]   = e_rst & (e_rcnt == e_rlen);
    always @(posedge clk or negedge rst_n) begin : blk1
        integer m, s, k, idx;
        if (!rst_n) begin e_wst <= 2'd0; e_wid <= {SIDW{1'b0}}; e_rst <= 1'b0; e_rid <= {SIDW{1'b0}}; e_rlen <= 8'd0; e_rcnt <= 8'd0; end
        else begin
            case (e_wst)
                2'd0: if (f_awvalid[NS] & f_awready[NS]) begin e_wid <= f_awid[NS*SIDW +: SIDW]; e_wst <= 2'd1; end
                2'd1: if (f_wvalid[NS] & f_wlast[NS]) e_wst <= 2'd2;
                2'd2: if (g_bready[NS]) e_wst <= 2'd0;
                default: e_wst <= 2'd0;
            endcase
            if (!e_rst) begin
                if (f_arvalid[NS]) begin e_rst <= 1'b1; e_rid <= f_arid[NS*SIDW +: SIDW]; e_rlen <= f_arlen[NS*8 +: 8]; e_rcnt <= 8'd0; end
            end else if (g_rready[NS]) begin
                if (e_rcnt == e_rlen) e_rst <= 1'b0; else e_rcnt <= e_rcnt + 8'd1;
            end
        end
    end

    // ================= KENH GHI =================
    reg  [CW-1:0]  wcnt [0:NM-1];             // so giao dich ghi chua co B
    reg  [7:0]     wslv [0:NM-1];             // slave cua cac giao dich do
    reg  [NSX-1:0] own_v, aw_done, w_done;    // moi slave: dang co chu so huu pha ghi
    reg  [NSX*LNM-1:0] owner;                 // master so huu (LNM >= 1)
    reg  [NSX*LNM-1:0] rr_w;                  // con tro vong tron
    wire [NM-1:0]  busy_w;                    // master dang la chu so huu o mot slave nao do
    reg  [NM-1:0]  busy_w_r;
    assign busy_w = busy_w_r;

    // yeu cau cua master m toi slave s
    reg [NM*8-1:0] wsel;
    reg [NM*NSX-1:0] wreq;
    always @* begin : blk2
        integer m, s, k, idx;
        for (m = 0; m < NM; m = m + 1) begin
            wsel[m*8 +: 8] = dec(s_awaddr[m*32 +: 32]);
            for (s = 0; s < NSX; s = s + 1)
                wreq[m*NSX + s] = s_awvalid[m] & ~busy_w[m] & (wsel[m*8 +: 8] == s) &
                                  (wcnt[m] < MAXOUT) & ((wcnt[m] == 0) | (wslv[m] == s));
        end
    end

    // bo phan xu moi slave
    reg [NSX-1:0]      w_win_v;
    reg [NSX*LNM-1:0]  w_win;
    reg [NSX-1:0]      cur_v;
    reg [NSX*LNM-1:0]  cur_m;
    reg [LNM-1:0]      tm;
    always @* begin : blk3
        integer m, s, k, idx;
        for (s = 0; s < NSX; s = s + 1) begin
            w_win_v[s] = 1'b0; w_win[s*LNM +: LNM] = {LNM{1'b0}};
            for (k = NM; k >= 1; k = k - 1) begin          // k lon truoc -> k nho ghi de sau: uu tien ung vien ngay sau con tro
                idx = rr_w[s*LNM +: LNM] + k;
                idx = idx % NM;
                if (wreq[idx*NSX + s]) begin w_win_v[s] = 1'b1; w_win[s*LNM +: LNM] = idx; end
            end
            cur_v[s] = own_v[s] | w_win_v[s];
            cur_m[s*LNM +: LNM] = own_v[s] ? owner[s*LNM +: LNM] : w_win[s*LNM +: LNM];
        end
    end

    // dua AW / W toi tung slave
    reg [NSX-1:0] aw_hs, w_hs, wl_hs;
    always @* begin : blk4
        integer m, s, k, idx;
        f_awvalid = {NSX{1'b0}}; f_wvalid = {NSX{1'b0}};
        f_awid = {NSX*SIDW{1'b0}}; f_awaddr = {NSX*32{1'b0}}; f_awlen = {NSX*8{1'b0}}; f_awsize = {NSX*3{1'b0}}; f_awburst = {NSX*2{1'b0}};
        f_wdata = {NSX*32{1'b0}}; f_wstrb = {NSX*4{1'b0}}; f_wlast = {NSX{1'b0}};
        for (s = 0; s < NSX; s = s + 1) begin
            m = cur_m[s*LNM +: LNM];
            f_awvalid[s] = cur_v[s] & ~(own_v[s] & aw_done[s]) & s_awvalid[m];
            f_awid[s*SIDW +: SIDW] = {m[LNM-1:0], s_awid[m*IDW +: IDW]};
            f_awaddr[s*32 +: 32] = s_awaddr[m*32 +: 32];
            f_awlen[s*8 +: 8]    = s_awlen[m*8 +: 8];
            f_awsize[s*3 +: 3]   = s_awsize[m*3 +: 3];
            f_awburst[s*2 +: 2]  = s_awburst[m*2 +: 2];
            f_wvalid[s] = cur_v[s] & ~(own_v[s] & w_done[s]) & s_wvalid[m];
            f_wdata[s*32 +: 32]  = s_wdata[m*32 +: 32];
            f_wstrb[s*4 +: 4]    = s_wstrb[m*4 +: 4];
            f_wlast[s]           = s_wlast[m];
            aw_hs[s] = f_awvalid[s] & f_awready[s];
            w_hs[s]  = f_wvalid[s] & f_wready[s];
            wl_hs[s] = w_hs[s] & s_wlast[m];
        end
    end

    // ready tra ve master
    reg [NM-1:0] awr, wr;
    always @* begin : blk5
        integer m, s, k, idx;
        awr = {NM{1'b0}}; wr = {NM{1'b0}};
        for (s = 0; s < NSX; s = s + 1) begin
            m = cur_m[s*LNM +: LNM];
            // chi cap AW cho master DUNG la master duoc chon va giai ma toi slave nay (da bao dam boi wreq / own)
            if (cur_v[s] & ~(own_v[s] & aw_done[s]) & f_awready[s]) awr[m] = 1'b1;
            if (cur_v[s] & ~(own_v[s] & w_done[s]) & f_wready[s])   wr[m]  = 1'b1;
        end
    end
    assign s_awready = awr;
    assign s_wready  = wr;

    // B: dinh tuyen theo chi so master o phan cao cua ID
    reg [NM*IDW-1:0] bid_r; reg [NM*2-1:0] bresp_r; reg [NM-1:0] bvalid_r;
    always @* begin : blk6
        integer m, s, k, idx;
        bid_r = {NM*IDW{1'b0}}; bresp_r = {NM*2{1'b0}}; bvalid_r = {NM{1'b0}}; g_bready = {NSX{1'b0}};
        for (s = 0; s < NSX; s = s + 1) begin
            m = g_bid[s*SIDW + IDW +: LNM];
            if (g_bvalid[s]) begin
                bvalid_r[m] = 1'b1; bid_r[m*IDW +: IDW] = g_bid[s*SIDW +: IDW]; bresp_r[m*2 +: 2] = g_bresp[s*2 +: 2];
                g_bready[s] = s_bready[m];
            end
        end
    end
    assign s_bid = bid_r; assign s_bresp = bresp_r; assign s_bvalid = bvalid_r;

    // cap nhat trang thai ghi
    reg [NM-1:0] gr_p;                        // master duoc cap trong chu ky nay
    reg [NM*8-1:0] gr_s;
    always @* begin : blk7
        integer m, s, k, idx;
        gr_p = {NM{1'b0}}; gr_s = {NM*8{1'b0}};
        for (s = 0; s < NSX; s = s + 1)
            if (~own_v[s] & w_win_v[s]) begin gr_p[w_win[s*LNM +: LNM]] = 1'b1; gr_s[w_win[s*LNM +: LNM]*8 +: 8] = s; end
    end
    always @(posedge clk or negedge rst_n) begin : blk8
        integer m, s, k, idx;
        if (!rst_n) begin
            own_v <= {NSX{1'b0}}; aw_done <= {NSX{1'b0}}; w_done <= {NSX{1'b0}}; owner <= {NSX*LNM{1'b0}}; rr_w <= {NSX*LNM{1'b0}};
            busy_w_r <= {NM{1'b0}};
            for (m = 0; m < NM; m = m + 1) begin wcnt[m] <= {CW{1'b0}}; wslv[m] <= 8'd0; end
        end else begin
            for (s = 0; s < NSX; s = s + 1) begin
                if (~own_v[s]) begin
                    if (w_win_v[s]) begin
                        rr_w[s*LNM +: LNM] <= w_win[s*LNM +: LNM];
                        if (!((aw_hs[s]) && wl_hs[s])) begin
                            own_v[s] <= 1'b1; owner[s*LNM +: LNM] <= w_win[s*LNM +: LNM];
                            aw_done[s] <= aw_hs[s]; w_done[s] <= wl_hs[s];
                            busy_w_r[w_win[s*LNM +: LNM]] <= 1'b1;
                        end
                    end
                end else begin
                    if (aw_hs[s]) aw_done[s] <= 1'b1;
                    if (wl_hs[s]) w_done[s]  <= 1'b1;
                    if ((aw_done[s] | aw_hs[s]) & (w_done[s] | wl_hs[s])) begin
                        own_v[s] <= 1'b0; aw_done[s] <= 1'b0; w_done[s] <= 1'b0;
                        busy_w_r[owner[s*LNM +: LNM]] <= 1'b0;
                    end
                end
            end
            for (m = 0; m < NM; m = m + 1) begin
                if (gr_p[m] & ~(s_bvalid[m] & s_bready[m])) wcnt[m] <= wcnt[m] + 1'b1;
                else if (~gr_p[m] & (s_bvalid[m] & s_bready[m])) wcnt[m] <= wcnt[m] - 1'b1;
                if (gr_p[m]) wslv[m] <= gr_s[m*8 +: 8];
            end
        end
    end

    // ================= KENH DOC =================
    reg  [CW-1:0]  rcnt [0:NM-1];
    reg  [7:0]     rslv [0:NM-1];
    reg  [NSX-1:0] ar_lock;
    reg  [NSX*LNM-1:0] ar_owner, rr_r;
    reg  [NM*8-1:0] rsel;
    reg  [NM*NSX-1:0] rreq;
    always @* begin : blk9
        integer m, s, k, idx;
        for (m = 0; m < NM; m = m + 1) begin
            rsel[m*8 +: 8] = dec(s_araddr[m*32 +: 32]);
            for (s = 0; s < NSX; s = s + 1)
                rreq[m*NSX + s] = s_arvalid[m] & (rsel[m*8 +: 8] == s) & (rcnt[m] < MAXOUT) & ((rcnt[m] == 0) | (rslv[m] == s));
        end
    end
    reg [NSX-1:0] r_win_v, rcur_v;
    reg [NSX*LNM-1:0] r_win, rcur_m;
    always @* begin : blk10
        integer m, s, k, idx;
        for (s = 0; s < NSX; s = s + 1) begin
            r_win_v[s] = 1'b0; r_win[s*LNM +: LNM] = {LNM{1'b0}};
            for (k = NM; k >= 1; k = k - 1) begin
                idx = rr_r[s*LNM +: LNM] + k;
                idx = idx % NM;
                if (rreq[idx*NSX + s]) begin r_win_v[s] = 1'b1; r_win[s*LNM +: LNM] = idx; end
            end
            rcur_v[s] = ar_lock[s] | r_win_v[s];
            rcur_m[s*LNM +: LNM] = ar_lock[s] ? ar_owner[s*LNM +: LNM] : r_win[s*LNM +: LNM];
        end
    end
    reg [NSX-1:0] ar_hs;
    reg [NM-1:0]  arr;
    always @* begin : blk11
        integer m, s, k, idx;
        f_arvalid = {NSX{1'b0}}; f_arid = {NSX*SIDW{1'b0}}; f_araddr = {NSX*32{1'b0}}; f_arlen = {NSX*8{1'b0}}; f_arsize = {NSX*3{1'b0}}; f_arburst = {NSX*2{1'b0}};
        arr = {NM{1'b0}};
        for (s = 0; s < NSX; s = s + 1) begin
            m = rcur_m[s*LNM +: LNM];
            f_arvalid[s] = rcur_v[s] & s_arvalid[m];
            f_arid[s*SIDW +: SIDW] = {m[LNM-1:0], s_arid[m*IDW +: IDW]};
            f_araddr[s*32 +: 32]  = s_araddr[m*32 +: 32];
            f_arlen[s*8 +: 8]     = s_arlen[m*8 +: 8];
            f_arsize[s*3 +: 3]    = s_arsize[m*3 +: 3];
            f_arburst[s*2 +: 2]   = s_arburst[m*2 +: 2];
            ar_hs[s] = f_arvalid[s] & f_arready[s];
            if (rcur_v[s] & f_arready[s]) arr[m] = 1'b1;
        end
    end
    assign s_arready = arr;

    // R: dinh tuyen theo chi so master
    reg [NM*IDW-1:0] rid_r; reg [NM*32-1:0] rdata_r; reg [NM*2-1:0] rresp_r; reg [NM-1:0] rlast_r, rvalid_r;
    always @* begin : blk12
        integer m, s, k, idx;
        rid_r = {NM*IDW{1'b0}}; rdata_r = {NM*32{1'b0}}; rresp_r = {NM*2{1'b0}}; rlast_r = {NM{1'b0}}; rvalid_r = {NM{1'b0}}; g_rready = {NSX{1'b0}};
        for (s = 0; s < NSX; s = s + 1) begin
            m = g_rid[s*SIDW + IDW +: LNM];
            if (g_rvalid[s]) begin
                rvalid_r[m] = 1'b1; rid_r[m*IDW +: IDW] = g_rid[s*SIDW +: IDW]; rdata_r[m*32 +: 32] = g_rdata[s*32 +: 32];
                rresp_r[m*2 +: 2] = g_rresp[s*2 +: 2]; rlast_r[m] = g_rlast[s];
                g_rready[s] = s_rready[m];
            end
        end
    end
    assign s_rid = rid_r; assign s_rdata = rdata_r; assign s_rresp = rresp_r; assign s_rlast = rlast_r; assign s_rvalid = rvalid_r;

    reg [NM-1:0] rd_hs_p, r_last_hs;          // AR duoc nhan / beat cuoi cua R hoan tat
    reg [NM*8-1:0] rd_hs_s;
    always @* begin : blk13
        integer m, s, k, idx;
        rd_hs_p = {NM{1'b0}}; rd_hs_s = {NM*8{1'b0}}; r_last_hs = {NM{1'b0}};
        for (s = 0; s < NSX; s = s + 1) begin
            m = rcur_m[s*LNM +: LNM];
            if (ar_hs[s]) begin rd_hs_p[m] = 1'b1; rd_hs_s[m*8 +: 8] = s; end
        end
        for (m = 0; m < NM; m = m + 1) r_last_hs[m] = s_rvalid[m] & s_rready[m] & s_rlast[m];
    end
    always @(posedge clk or negedge rst_n) begin : blk14
        integer m, s, k, idx;
        if (!rst_n) begin
            ar_lock <= {NSX{1'b0}}; ar_owner <= {NSX*LNM{1'b0}}; rr_r <= {NSX*LNM{1'b0}};
            for (m = 0; m < NM; m = m + 1) begin rcnt[m] <= {CW{1'b0}}; rslv[m] <= 8'd0; end
        end else begin
            for (s = 0; s < NSX; s = s + 1) begin
                if (r_win_v[s] & ~ar_lock[s]) rr_r[s*LNM +: LNM] <= r_win[s*LNM +: LNM];
                if (ar_hs[s]) ar_lock[s] <= 1'b0;
                else if (r_win_v[s] & ~ar_lock[s]) begin ar_lock[s] <= 1'b1; ar_owner[s*LNM +: LNM] <= r_win[s*LNM +: LNM]; end
            end
            for (m = 0; m < NM; m = m + 1) begin
                if (rd_hs_p[m] & ~r_last_hs[m]) rcnt[m] <= rcnt[m] + 1'b1;
                else if (~rd_hs_p[m] & r_last_hs[m]) rcnt[m] <= rcnt[m] - 1'b1;
                if (rd_hs_p[m]) rslv[m] <= rd_hs_s[m*8 +: 8];
            end
        end
    end
endmodule
