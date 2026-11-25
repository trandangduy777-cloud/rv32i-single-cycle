// Bo kiem tra giao thuc AXI4 (chi dung trong testbench / mo phong), tu viet. Gan vao 1 giao dien AXI (cac tin hieu chi doc). Moi vi pham in "[AXI] <NAME> ..." va tang `errors`.
// Kiem tra:
//  1. Moi kenh: VALID da len phai giu toi khi READY, va payload (ID, dia chi, len, size, burst / du lieu, strobe, last / id, resp / id, du lieu, resp, last) khong doi trong luc cho.
//  2. WLAST dung o beat cuoi (so beat W = AWLEN + 1) cho tung giao dich, khop theo thu tu AW (W duoc phep den truoc AW).
//  3. B chi tra sau khi giao dich ghi tuong ung xong ca AW lan W (WLAST); BID phai la ID dang cho, dung thu tu trong cung ID.
//  4. R: RID phai la ID dang cho, dung thu tu trong cung ID, RLAST dung o beat ARLEN + 1; khong beat nao truoc AR.
//  5. Luat burst: size <= 2 (bus 32 bit), burst != 3, WRAP chi len 1/3/7/15 va dia chi can theo size, FIXED len <= 15, INCR khong vuot ranh gioi 4 KB.
//  6. Sau reset VALID / READY khong duoc X; moi VALID bi treo qua TMO chu ky ma khong co READY la loi (nghi deadlock).
module axi_checker #(
    parameter NAME = "axi",
    parameter IDW  = 4,
    parameter TMO  = 4000,
    parameter QD   = 32
) (
    input wire clk, input wire rst_n,
    input wire [IDW-1:0] awid, input wire [31:0] awaddr, input wire [7:0] awlen, input wire [2:0] awsize, input wire [1:0] awburst, input wire awvalid, input wire awready,
    input wire [31:0] wdata, input wire [3:0] wstrb, input wire wlast, input wire wvalid, input wire wready,
    input wire [IDW-1:0] bid, input wire [1:0] bresp, input wire bvalid, input wire bready,
    input wire [IDW-1:0] arid, input wire [31:0] araddr, input wire [7:0] arlen, input wire [2:0] arsize, input wire [1:0] arburst, input wire arvalid, input wire arready,
    input wire [IDW-1:0] rid, input wire [31:0] rdata, input wire [1:0] rresp, input wire rlast, input wire rvalid, input wire rready
);
    integer errors = 0;
    integer n_aw = 0, n_w = 0, n_b = 0, n_ar = 0, n_r = 0;      // thong ke: so giao dich / beat
    task fail(input [8*48-1:0] msg);
        begin errors = errors + 1; $display("[AXI] %0s LOI @%0t: %0s", NAME, $time, msg); end
    endtask

    // ---- 1. VALID giu, payload on dinh, va X ----
    reg aw_p, w_p, b_p, ar_p, r_p;
    reg [IDW+32+8+3+2-1:0] aw_q, ar_q; reg [32+4+1-1:0] w_q; reg [IDW+2-1:0] b_q; reg [IDW+32+2+1-1:0] r_q;
    wire [IDW+32+8+3+2-1:0] aw_now = {awid, awaddr, awlen, awsize, awburst};
    wire [IDW+32+8+3+2-1:0] ar_now = {arid, araddr, arlen, arsize, arburst};
    wire [32+4+1-1:0] w_now = {wdata, wstrb, wlast};
    wire [IDW+2-1:0]  b_now = {bid, bresp};
    wire [IDW+32+2+1-1:0] r_now = {rid, rdata, rresp, rlast};
    integer t_aw = 0, t_w = 0, t_b = 0, t_ar = 0, t_r = 0;
    reg started = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin aw_p <= 0; w_p <= 0; b_p <= 0; ar_p <= 0; r_p <= 0; t_aw = 0; t_w = 0; t_b = 0; t_ar = 0; t_r = 0; started <= 1'b0; end
        else begin
            started <= 1'b1;
            if (aw_p && !(awvalid && aw_now === aw_q)) fail("AW: VALID roi hoac payload doi truoc READY");
            if (w_p  && !(wvalid  && (wvalid && (w_now[0] === w_q[0]) && (w_now === w_q)))) fail("W: VALID roi hoac payload doi truoc READY");
            if (b_p  && !(bvalid  && b_now === b_q)) fail("B: VALID roi hoac payload doi truoc READY");
            if (ar_p && !(arvalid && ar_now === ar_q)) fail("AR: VALID roi hoac payload doi truoc READY");
            if (r_p  && !(rvalid  && r_now === r_q)) fail("R: VALID roi hoac payload doi truoc READY");
            aw_p <= awvalid & ~awready; w_p <= wvalid & ~wready; b_p <= bvalid & ~bready; ar_p <= arvalid & ~arready; r_p <= rvalid & ~rready;
            aw_q <= aw_now; w_q <= w_now; b_q <= b_now; ar_q <= ar_now; r_q <= r_now;
            if ((^{awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready}) === 1'bx) fail("VALID/READY la X sau reset");
            t_aw = (awvalid & ~awready) ? t_aw + 1 : 0; if (t_aw > TMO) begin fail("AW treo qua TMO chu ky (deadlock?)"); t_aw = 0; end
            t_w  = (wvalid  & ~wready)  ? t_w  + 1 : 0; if (t_w  > TMO) begin fail("W treo qua TMO chu ky (deadlock?)");  t_w = 0; end
            t_b  = (bvalid  & ~bready)  ? t_b  + 1 : 0; if (t_b  > TMO) begin fail("B treo qua TMO chu ky (deadlock?)");  t_b = 0; end
            t_ar = (arvalid & ~arready) ? t_ar + 1 : 0; if (t_ar > TMO) begin fail("AR treo qua TMO chu ky (deadlock?)"); t_ar = 0; end
            t_r  = (rvalid  & ~rready)  ? t_r  + 1 : 0; if (t_r  > TMO) begin fail("R treo qua TMO chu ky (deadlock?)");  t_r = 0; end
        end
    end

    // ---- 5. luat burst (kiem khi AW / AR duoc nhan) ----
    task check_burst(input [31:0] a, input [7:0] ln, input [2:0] sz, input [1:0] bt);
        reg [31:0] bytes;
        begin
            bytes = ({24'd0, ln} + 32'd1) << sz;
            if (sz > 3'd2) fail("burst: size > 2 tren bus 32 bit");
            if (bt == 2'b11) fail("burst: loai burst = 3 (reserved)");
            if (bt == 2'b10) begin
                if (!(ln == 8'd1 || ln == 8'd3 || ln == 8'd7 || ln == 8'd15)) fail("WRAP: len khong thuoc {1,3,7,15}");
                if ((a & ((32'd1 << sz) - 32'd1)) != 0) fail("WRAP: dia chi khong can theo size");
            end
            if (bt == 2'b00 && ln > 8'd15) fail("FIXED: len > 15");
            if (bt == 2'b01 && ((a & 32'hFFF) + bytes - ((a & ((32'd1 << sz) - 1)))) > 32'h1000) fail("INCR: vuot ranh gioi 4 KB");
        end
    endtask

    // ---- 2, 3: hang doi ghi ----
    reg [7:0]    awq_len [0:QD-1]; reg [IDW-1:0] awq_id [0:QD-1]; integer awq_n = 0;     // AW chua khop W
    reg [7:0]    wq_beats [0:QD-1]; integer wq_n = 0;                                     // W da xong (so beat - 1) nhung chua khop AW
    reg [IDW-1:0] bq_id [0:QD-1]; integer bq_n = 0;                                       // giao dich ghi da xong ca AW va W, chua co B
    integer wbeat = 0, i, j;
    reg [IDW-1:0] tid; reg [7:0] tl;
    // ---- 4: hang doi doc ----
    reg [IDW-1:0] rq_id [0:QD-1]; reg [7:0] rq_len [0:QD-1]; integer rq_got [0:QD-1]; integer rq_n = 0;
    integer found;
    always @(posedge clk) if (rst_n) begin
        if (awvalid & awready) begin
            n_aw = n_aw + 1; check_burst(awaddr, awlen, awsize, awburst);
            if (awq_n < QD) begin awq_len[awq_n] = awlen; awq_id[awq_n] = awid; awq_n = awq_n + 1; end else fail("hang doi AW tran (checker)");
        end
        if (wvalid & wready) begin
            n_w = n_w + 1;
            if (wlast) begin
                if (wq_n < QD) begin wq_beats[wq_n] = wbeat; wq_n = wq_n + 1; end else fail("hang doi W tran (checker)");
                wbeat = 0;
            end else wbeat = wbeat + 1;
        end
        // khop AW voi W dau hang doi
        while (awq_n > 0 && wq_n > 0) begin
            if (wq_beats[0] !== awq_len[0]) fail("WLAST sai: so beat W khac AWLEN + 1");
            if (bq_n < QD) begin bq_id[bq_n] = awq_id[0]; bq_n = bq_n + 1; end
            for (i = 0; i < QD - 1; i = i + 1) begin awq_len[i] = awq_len[i+1]; awq_id[i] = awq_id[i+1]; wq_beats[i] = wq_beats[i+1]; end
            awq_n = awq_n - 1; wq_n = wq_n - 1;
        end
        if (bvalid & bready) begin
            n_b = n_b + 1; found = -1;
            for (i = QD - 1; i >= 0; i = i - 1) if (i < bq_n && bq_id[i] === bid) found = i;
            if (found < 0) fail("B: BID khong khop giao dich ghi da hoan tat (hoac B som)");
            else begin for (i = found; i < QD - 1; i = i + 1) bq_id[i] = bq_id[i+1]; bq_n = bq_n - 1; end
        end
        // doc
        if (arvalid & arready) begin
            n_ar = n_ar + 1; check_burst(araddr, arlen, arsize, arburst);
            if (rq_n < QD) begin rq_id[rq_n] = arid; rq_len[rq_n] = arlen; rq_got[rq_n] = 0; rq_n = rq_n + 1; end else fail("hang doi AR tran (checker)");
        end
        if (rvalid & rready) begin
            n_r = n_r + 1; found = -1;
            for (i = QD - 1; i >= 0; i = i - 1) if (i < rq_n && rq_id[i] === rid) found = i;
            if (found < 0) fail("R: RID khong khop giao dich doc dang cho");
            else begin
                rq_got[found] = rq_got[found] + 1;
                if (rlast !== (rq_got[found] == rq_len[found] + 1)) fail("RLAST sai: so beat R khac ARLEN + 1");
                if (rq_got[found] > rq_len[found] + 1) fail("R: qua nhieu beat");
                if (rlast === 1'b1 || rq_got[found] >= rq_len[found] + 1) begin
                    for (i = found; i < QD - 1; i = i + 1) begin rq_id[i] = rq_id[i+1]; rq_len[i] = rq_len[i+1]; rq_got[i] = rq_got[i+1]; end
                    rq_n = rq_n - 1;
                end
            end
        end
    end

    // goi khi ket thuc: khong con giao dich treo
    task final_check;
        begin
            if (awq_n != 0 || wq_n != 0 || bq_n != 0) begin errors = errors + 1; $display("[AXI] %0s LOI: ket thuc con giao dich ghi treo (aw %0d, w %0d, cho B %0d)", NAME, awq_n, wq_n, bq_n); end
            if (rq_n != 0) begin errors = errors + 1; $display("[AXI] %0s LOI: ket thuc con %0d giao dich doc treo", NAME, rq_n); end
        end
    endtask
endmodule
