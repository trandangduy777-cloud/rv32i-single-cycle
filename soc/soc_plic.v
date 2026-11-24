// PLIC (Platform-Level Interrupt Controller) theo dac ta RISC-V PLIC, mot hart, mot context (M-mode, context 0).
// Nguon ngat 1..NSRC (nguon 0 danh rieng, khong dung), ngat theo muc, moi nguon co cong (gateway) chuyen muc thanh yeu cau:
// sau khi claim, nguon khong gui yeu cau moi cho toi khi complete; complete ma nguon van cao thi yeu cau moi sinh ra.
// Ban do thanh ghi (offset tu dia chi goc, cua so 4 MB nhu dac ta; thanh ghi ngoai danh sach doc ra 0, ghi bi bo):
//   0x000004 * i   PRIORITY[i]   R/W  [PRIO_W-1:0]; uu tien 0 = nguon khong bao gio ngat
//   0x001000       PENDING       R    bit i = nguon i dang cho (bit 0 = 0)
//   0x002000       ENABLE        R/W  bit i = cho phep nguon i cho context 0 (bit 0 = 0)
//   0x200000       THRESHOLD     R/W  [PRIO_W-1:0]; chi nguon co uu tien > threshold moi ngat
//   0x200004       CLAIM/COMPLETE R: ID nguon cho co uu tien cao nhat (hoa nhau: ID nho nhat), 0 neu khong co; doc la nhan (claim)
//                                W: complete, ghi ID nguon da xu ly xong (bo qua neu ID khong hop le / khong duoc enable / khong dang xu ly)
// eip = co it nhat mot nguon pending + enable + uu tien > threshold; dua vao irq_ext cua loi (mip.MEIP).
module soc_plic #(
    parameter NSRC   = 7,         // so nguon (1..NSRC), toi da 31
    parameter PRIO_W = 3          // do rong uu tien (uu tien 0..2^PRIO_W-1)
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              sel,
    input  wire [21:2]       addr,
    input  wire              we,
    input  wire              re,
    input  wire [3:0]        wstrb,
    input  wire [31:0]       wdata,
    output reg  [31:0]       rdata,
    input  wire [NSRC:1]     src,
    output wire              eip
);
    reg [PRIO_W-1:0] prio [1:NSRC];
    reg [NSRC:1]     pend, infl, en;
    reg [PRIO_W-1:0] thr;
    integer i, j;

    // chon nguon: uu tien cao nhat trong (pending & enable & prio > threshold), hoa -> ID nho nhat
    reg [4:0]        best_id;
    reg [PRIO_W-1:0] best_pr;
    always @* begin
        best_id = 5'd0; best_pr = {PRIO_W{1'b0}};
        for (j = 1; j <= NSRC; j = j + 1)
            if (pend[j] & en[j] & (prio[j] > thr) & (prio[j] > best_pr)) begin best_id = j; best_pr = prio[j]; end
    end
    assign eip = (best_id != 5'd0);

    wire [19:0] w = addr[21:2];
    wire a_prio = (w[19:10] == 10'd0) && (w[9:0] >= 10'd1) && (w[9:0] <= NSRC);
    wire a_pend = (w == 20'h00400);
    wire a_en   = (w == 20'h00800);
    wire a_thr  = (w == 20'h80000);
    wire a_cc   = (w == 20'h80001);
    wire [4:0] pidx = w[4:0];

    wire wr  = sel & we;
    wire claim = sel & re & a_cc;
    wire [7:0] cid = wdata[7:0];
    wire complete_ok = wr & a_cc & wstrb[0] & (cid >= 8'd1) & (cid <= NSRC) & en[cid[4:0]] & infl[cid[4:0]];

    always @* begin
        rdata = 32'd0;
        if (sel) begin
            if (a_prio)      rdata = {{(32-PRIO_W){1'b0}}, prio[pidx]};
            else if (a_pend) rdata = {{(31-NSRC){1'b0}}, pend, 1'b0};
            else if (a_en)   rdata = {{(31-NSRC){1'b0}}, en, 1'b0};
            else if (a_thr)  rdata = {{(32-PRIO_W){1'b0}}, thr};
            else if (a_cc)   rdata = {27'd0, best_id};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pend <= {NSRC{1'b0}}; infl <= {NSRC{1'b0}}; en <= {NSRC{1'b0}}; thr <= {PRIO_W{1'b0}};
            for (i = 1; i <= NSRC; i = i + 1) prio[i] <= {PRIO_W{1'b0}};
        end else begin
            // cong nguon: yeu cau moi khi nguon cao va chua co yeu cau dang di; claim thang
            for (i = 1; i <= NSRC; i = i + 1) begin
                if (claim && best_id == i) begin pend[i] <= 1'b0; infl[i] <= 1'b1; end
                else begin
                    if (src[i] & ~infl[i] & ~pend[i]) pend[i] <= 1'b1;
                    if (complete_ok && cid[4:0] == i) infl[i] <= 1'b0;
                end
            end
            if (wr & a_prio & wstrb[0]) prio[pidx] <= wdata[PRIO_W-1:0];
            if (wr & a_en) begin
                if (wstrb[0]) for (i = 1; i <= 7;  i = i + 1) if (i <= NSRC) en[i] <= wdata[i];
                if (wstrb[1]) for (i = 8; i <= 15; i = i + 1) if (i <= NSRC) en[i] <= wdata[i];
                if (wstrb[2]) for (i = 16; i <= 23; i = i + 1) if (i <= NSRC) en[i] <= wdata[i];
                if (wstrb[3]) for (i = 24; i <= 31; i = i + 1) if (i <= NSRC) en[i] <= wdata[i];
            end
            if (wr & a_thr & wstrb[0]) thr <= wdata[PRIO_W-1:0];
        end
    end
endmodule
