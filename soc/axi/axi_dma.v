// DMA AXI4 master 2 kenh (NCH), cau hinh qua bus ngoai vi cu (anh xa bo nho), tu viet. 1 cong AXI master dung chung, cac kenh luan phien theo tung manh (chunk).
// Thanh ghi moi kenh (cach nhau 0x20, chi truy cap ca tu 32 bit), co so DMA_BASE = 0x2001_0000, kenh c o DMA_BASE + 0x20 * c:
//   +0x00 CTRL    bit0 = START (ghi 1 de chay, bo qua khi dang ban), bit1 = IE (cho ngat); doc: {IE, BUSY}
//   +0x04 STATUS  bit0 BUSY, bit1 DONE, bit2 ERR (ghi 1 vao bit1 / bit2 de xoa)
//   +0x08 SRC     dia chi nguon (can tu), doc = con tro hien tai    +0x0C DST  dia chi dich
//   +0x10 LEN     so tu 32 bit, doc = so tu con lai                 +0x14 SSTRIDE / +0x18 DSTRIDE  buoc dia chi (byte) sau moi tu, mac dinh 4
//   +0x1C CYCLES  so chu ky tu START toi DONE cua lan chay gan nhat
// Stride 4 -> burst INCR, stride 0 -> burst FIXED (vi du doc / ghi FIFO UART), stride khac -> tung tu 1 giao dich dia chi += stride.
// Moi manh: toi da MAXB = 16 tu, khong vuot ranh gioi 4 KB; doc het manh vao bo dem roi ghi ra. Loi R / B (khac OKAY) -> ERR, dung kenh do.
// irq[c] = IE[c] & (DONE[c] | ERR[c]), muc cao, xoa bang ghi 1 vao STATUS.
module axi_dma #(
    parameter NCH = 2,
    parameter IDW = 4
) (
    input  wire clk, input wire rst_n,
    // cau hinh
    input  wire sel, input wire [4:0] addr, input wire we, input wire [3:0] wstrb, input wire [31:0] wdata, output reg [31:0] rdata,
    output wire [NCH-1:0] irq,
    // AXI master
    output wire [IDW-1:0] awid, output wire [31:0] awaddr, output wire [7:0] awlen, output wire [2:0] awsize, output wire [1:0] awburst, output wire awvalid, input wire awready,
    output wire [31:0] wdata_o, output wire [3:0] wstrb_o, output wire wlast, output wire wvalid, input wire wready,
    input  wire [IDW-1:0] bid, input wire [1:0] bresp, input wire bvalid, output wire bready,
    output wire [IDW-1:0] arid, output wire [31:0] araddr, output wire [7:0] arlen, output wire [2:0] arsize, output wire [1:0] arburst, output wire arvalid, input wire arready,
    input  wire [IDW-1:0] rid, input wire [31:0] rdata_i, input wire [1:0] rresp, input wire rlast, input wire rvalid, output wire rready
);
    localparam MAXB = 16;
    reg [NCH-1:0] ie, busy, done, errf;
    reg [31:0] src [0:NCH-1]; reg [31:0] dst [0:NCH-1]; reg [31:0] rem [0:NCH-1];
    reg [31:0] ss [0:NCH-1]; reg [31:0] ds [0:NCH-1]; reg [31:0] cyc [0:NCH-1]; reg [31:0] cnt [0:NCH-1];
    assign irq = ie & (done | errf);

    wire [1:0] ch = addr[4:3];
    wire [2:0] rg = addr[2:0];
    integer i;

    // ---------------- doc thanh ghi ----------------
    always @* begin
        rdata = 32'd0;
        if (sel && ch < NCH) case (rg)
            3'd0: rdata = {30'd0, ie[ch], busy[ch]};
            3'd1: rdata = {29'd0, errf[ch], done[ch], busy[ch]};
            3'd2: rdata = src[ch];
            3'd3: rdata = dst[ch];
            3'd4: rdata = rem[ch];
            3'd5: rdata = ss[ch];
            3'd6: rdata = ds[ch];
            3'd7: rdata = cyc[ch];
        endcase
    end

    // ---------------- dong co chuyen du lieu ----------------
    localparam [2:0] IDLE = 0, RAR = 1, RD = 2, WR = 3, WB = 4;
    reg [2:0] st; reg [1:0] cur, rr; reg [4:0] n, bi, wi; reg aw_d, e_chunk, rd_err;
    reg [31:0] dbuf [0:MAXB-1];
    reg [31:0] a_s, a_d; reg sfix, dfix;

    // chon kenh ke tiep (luan phien tu rr + 1)
    reg        pick_v; reg [1:0] pick;
    always @* begin
        pick_v = 1'b0; pick = 2'd0;
        for (i = NCH; i >= 1; i = i - 1) begin : sc
            integer c;
            c = (rr + i) % NCH;
            if (busy[c] && rem[c] != 0) begin pick_v = 1'b1; pick = c; end
        end
    end
    // do dai manh cho kenh pick
    reg [31:0] pn, bs, bd, rs_, rd_;
    always @* begin
        pn = (rem[pick] > MAXB) ? MAXB : rem[pick];
        if (!((ss[pick] == 32'd4 || ss[pick] == 32'd0) && (ds[pick] == 32'd4 || ds[pick] == 32'd0))) pn = 1;
        else begin
            if (ss[pick] == 32'd4) begin bs = (32'd4096 - {20'd0, src[pick][11:0]}) >> 2; if (pn > bs) pn = bs; end
            if (ds[pick] == 32'd4) begin bd = (32'd4096 - {20'd0, dst[pick][11:0]}) >> 2; if (pn > bd) pn = bd; end
        end
    end

    assign arid = {{(IDW-2){1'b0}}, cur}; assign awid = {{(IDW-2){1'b0}}, cur};
    assign araddr = a_s; assign awaddr = a_d;
    assign arlen = n - 1; assign awlen = n - 1; assign arsize = 3'd2; assign awsize = 3'd2;
    assign arburst = (n == 1 || !sfix) ? 2'b01 : 2'b00;
    assign awburst = (n == 1 || !dfix) ? 2'b01 : 2'b00;
    assign arvalid = (st == RAR);
    assign rready  = (st == RD);
    assign awvalid = (st == WR) & ~aw_d;
    assign wvalid  = (st == WR) & (wi < n);
    assign wdata_o = dbuf[wi[3:0]]; assign wstrb_o = 4'b1111; assign wlast = (wi == n - 1);
    assign bready  = (st == WB);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ie <= 0; busy <= 0; done <= 0; errf <= 0; st <= IDLE; cur <= 0; rr <= NCH - 1; n <= 0; bi <= 0; wi <= 0; aw_d <= 0; e_chunk <= 0; a_s <= 0; a_d <= 0; sfix <= 0; dfix <= 0;
            for (i = 0; i < NCH; i = i + 1) begin src[i] <= 0; dst[i] <= 0; rem[i] <= 0; ss[i] <= 4; ds[i] <= 4; cyc[i] <= 0; cnt[i] <= 0; end
        end else begin
            for (i = 0; i < NCH; i = i + 1) if (busy[i]) cnt[i] <= cnt[i] + 32'd1;
            // ghi thanh ghi (uu tien thap hon cap nhat cua dong co o cuoi khoi)
            if (sel && we && ch < NCH) case (rg)
                3'd0: begin
                    ie[ch] <= wdata[1];
                    if (wdata[0] && !busy[ch]) begin
                        done[ch] <= 1'b0; errf[ch] <= 1'b0; cnt[ch] <= 32'd1;
                        if (rem[ch] == 0) begin done[ch] <= 1'b1; cyc[ch] <= 32'd0; end else busy[ch] <= 1'b1;
                    end
                end
                3'd1: begin if (wdata[1]) done[ch] <= 1'b0; if (wdata[2]) errf[ch] <= 1'b0; end
                3'd2: if (!busy[ch]) src[ch] <= {wdata[31:2], 2'b00};
                3'd3: if (!busy[ch]) dst[ch] <= {wdata[31:2], 2'b00};
                3'd4: if (!busy[ch]) rem[ch] <= wdata;
                3'd5: if (!busy[ch]) ss[ch] <= wdata;
                3'd6: if (!busy[ch]) ds[ch] <= wdata;
                default: ;
            endcase
            case (st)
                IDLE: if (pick_v) begin
                    cur <= pick; n <= pn[4:0]; a_s <= src[pick]; a_d <= dst[pick]; sfix <= (ss[pick] == 32'd0); dfix <= (ds[pick] == 32'd0);
                    bi <= 0; wi <= 0; aw_d <= 1'b0; e_chunk <= 1'b0; st <= RAR;
                end
                RAR: if (arready) st <= RD;
                RD: if (rvalid) begin
                    dbuf[bi[3:0]] <= rdata_i; bi <= bi + 5'd1;
                    if (rresp != 2'b00) e_chunk <= 1'b1;
                    if (rlast) begin
                        if (e_chunk || rresp != 2'b00) begin       // loi doc: bo kenh nay, khong ghi
                            busy[cur] <= 1'b0; errf[cur] <= 1'b1; cyc[cur] <= cnt[cur]; rr <= cur; st <= IDLE;
                        end else st <= WR;
                    end
                end
                WR: begin
                    if (awvalid && awready) aw_d <= 1'b1;
                    if (wvalid && wready) wi <= wi + 5'd1;
                    if ((aw_d || (awvalid && awready)) && (wi == n || (wvalid && wready && wlast))) st <= WB;
                end
                WB: if (bvalid) begin
                    src[cur] <= src[cur] + ((ss[cur] == 32'd4) ? {n, 2'b00} : (n == 1) ? ss[cur] : 32'd0);
                    dst[cur] <= dst[cur] + ((ds[cur] == 32'd4) ? {n, 2'b00} : (n == 1) ? ds[cur] : 32'd0);
                    rem[cur] <= rem[cur] - n;
                    rr <= cur; st <= IDLE;
                    if (bresp != 2'b00) begin busy[cur] <= 1'b0; errf[cur] <= 1'b1; cyc[cur] <= cnt[cur]; end
                    else if (rem[cur] == n) begin busy[cur] <= 1'b0; done[cur] <= 1'b1; cyc[cur] <= cnt[cur]; end
                end
                default: st <= IDLE;
            endcase
        end
    end
endmodule
