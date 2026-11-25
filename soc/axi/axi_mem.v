// Slave AXI4 bo nho (RAM, hoac ROM khi ROM = 1), 32 bit, tu viet. Ho tro burst FIXED / INCR / WRAP, byte strobe, doc va ghi chay doc lap (moi huong 1 giao dich).
// - ROM = 1: ghi duoc nuot (W) roi tra B voi SLVERR, noi dung khong doi.
// - Tham so kiem thu: RLAT = so chu ky cho truoc beat doc dau tien; STALL > 0 = xac suat (STALL / 16) beat doc khong san sang va wready ha o moi chu ky (LFSR, SEED);
//   RLAT = 0, STALL = 0: moi beat 1 chu ky.
// - Mang `mem` o muc cao nhat de testbench nap bang $readmemh(.., dut.u_xxx.mem).
module axi_mem #(
    parameter WORDS = 4096,
    parameter ROM   = 0,
    parameter IDW   = 6,
    parameter RLAT  = 0,
    parameter STALL = 0,
    parameter BDLY  = 0,            // so chu ky tre them truoc khi dua BVALID (kiem thu: B cua cac slave ve lech nhau)
    parameter [15:0] SEED = 16'hACE1,
    parameter INIT_FILE = ""
) (
    input  wire clk,
    input  wire rst_n,
    input  wire [IDW-1:0] awid,  input wire [31:0] awaddr, input wire [7:0] awlen, input wire [2:0] awsize, input wire [1:0] awburst,
    input  wire awvalid, output wire awready,
    input  wire [31:0] wdata, input wire [3:0] wstrb, input wire wlast, input wire wvalid, output wire wready,
    output wire [IDW-1:0] bid,   output wire [1:0] bresp, output wire bvalid, input wire bready,
    input  wire [IDW-1:0] arid,  input wire [31:0] araddr, input wire [7:0] arlen, input wire [2:0] arsize, input wire [1:0] arburst,
    input  wire arvalid, output wire arready,
    output wire [IDW-1:0] rid,   output wire [31:0] rdata, output wire [1:0] rresp, output wire rlast, output wire rvalid, input wire rready
);
    localparam AWB = $clog2(WORDS);
    reg [31:0] mem [0:WORDS-1];
    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);

    // LFSR 16 bit
    reg [15:0] lf;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lf <= SEED;
        else lf <= {lf[14:0], lf[15] ^ lf[13] ^ lf[12] ^ lf[10]};
    end
    wire gate_r = (STALL == 0) || (lf[3:0] >= STALL);
    wire gate_w = (STALL == 0) || (lf[11:8] >= STALL);

    // dia chi beat ke tiep: INCR cong, WRAP quay vong theo (len + 1) << size, FIXED giu nguyen
    function [31:0] nxt(input [31:0] a, input [2:0] sz, input [1:0] bt, input [7:0] ln);
        reg [31:0] step, wrap, inc;
        begin
            step = 32'd1 << sz;
            inc  = (a & ~(step - 32'd1)) + step;                       // beat tiep, can theo kich thuoc
            wrap = (({24'd0, ln} + 32'd1) << sz);                      // kich thuoc vung quay vong (byte)
            case (bt)
                2'b00: nxt = a;
                2'b10: nxt = (a & ~(wrap - 32'd1)) | (inc & (wrap - 32'd1));
                default: nxt = inc;
            endcase
        end
    endfunction

    // ---------------- ghi ----------------
    localparam WI = 2'd0, WD = 2'd1, WB = 2'd2;
    reg [1:0] wst; reg [IDW-1:0] w_id; reg [31:0] w_a; reg [7:0] w_len, w_cnt; reg [2:0] w_sz; reg [1:0] w_bt;
    assign awready = (wst == WI);
    assign wready  = (wst == WD) & gate_w;
    reg [7:0] b_cnt;
    assign bvalid  = (wst == WB) & (b_cnt == 8'd0);
    assign bid     = w_id;
    reg w_err;
    assign bresp   = w_err ? 2'b10 : 2'b00;
    wire [AWB-1:0] widx = w_a[AWB+1:2];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wst <= WI; w_id <= {IDW{1'b0}}; w_a <= 32'd0; w_len <= 8'd0; w_cnt <= 8'd0; w_sz <= 3'd0; w_bt <= 2'd1; w_err <= 1'b0; b_cnt <= 8'd0; end
        else case (wst)
            WI: if (awvalid) begin w_id <= awid; w_a <= awaddr; w_len <= awlen; w_cnt <= 8'd0; w_sz <= awsize; w_bt <= awburst; w_err <= 1'b0; wst <= WD; end
            WD: if (wvalid & wready) begin
                    if (ROM) w_err <= 1'b1;
                    else begin
                        if (wstrb[0]) mem[widx][7:0]   <= wdata[7:0];
                        if (wstrb[1]) mem[widx][15:8]  <= wdata[15:8];
                        if (wstrb[2]) mem[widx][23:16] <= wdata[23:16];
                        if (wstrb[3]) mem[widx][31:24] <= wdata[31:24];
                    end
                    w_a <= nxt(w_a, w_sz, w_bt, w_len); w_cnt <= w_cnt + 8'd1;
                    if (wlast) begin wst <= WB; b_cnt <= BDLY[7:0]; end
                end
            WB: if (b_cnt != 8'd0) b_cnt <= b_cnt - 8'd1; else if (bready) wst <= WI;
            default: wst <= WI;
        endcase
    end

    // ---------------- doc ----------------
    localparam RI = 2'd0, RW = 2'd1, RD = 2'd2;
    reg [1:0] rst_s; reg [IDW-1:0] r_id; reg [31:0] r_a; reg [7:0] r_len, r_cnt, r_wait; reg [2:0] r_sz; reg [1:0] r_bt; reg r_hold;
    assign arready = (rst_s == RI);
    wire r_rdy_data = (rst_s == RD) & (gate_r | r_hold);
    assign rvalid  = r_rdy_data;
    assign rid     = r_id;
    reg [31:0] r_q;                                               // du lieu giu on dinh khi master chua nhan (ghi cung dia chi tu master khac khong duoc doi payload)
    assign rdata   = r_hold ? r_q : mem[r_a[AWB+1:2]];
    assign rresp   = 2'b00;
    assign rlast   = (r_cnt == r_len);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rst_s <= RI; r_id <= {IDW{1'b0}}; r_a <= 32'd0; r_len <= 8'd0; r_cnt <= 8'd0; r_wait <= 8'd0; r_sz <= 3'd0; r_bt <= 2'd1; r_hold <= 1'b0; end
        else begin
            r_hold <= rvalid & ~rready; if (rvalid & ~rready) r_q <= rdata;
            case (rst_s)
                RI: if (arvalid) begin r_id <= arid; r_a <= araddr; r_len <= arlen; r_cnt <= 8'd0; r_sz <= arsize; r_bt <= arburst; r_wait <= RLAT[7:0]; rst_s <= (RLAT == 0) ? RD : RW; end
                RW: begin if (r_wait <= 8'd1) rst_s <= RD; r_wait <= r_wait - 8'd1; end
                RD: if (rvalid & rready) begin
                        r_a <= nxt(r_a, r_sz, r_bt, r_len); r_cnt <= r_cnt + 8'd1;
                        if (rlast) rst_s <= RI;
                    end
                default: rst_s <= RI;
            endcase
        end
    end
endmodule
