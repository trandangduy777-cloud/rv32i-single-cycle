// Cau AXI4 -> bus ngoai vi cu (to hop: addr, we / re 1 chu ky, wstrb, wdata, rdata), tu viet. Nhan burst bat ky (FIXED / INCR / WRAP, size <= 2) va
// thuc hien tung beat thanh 1 truy cap ngoai vi (nen DMA co the burst FIXED vao FIFO UART). Moi lan 1 giao dich (doc hoac ghi, luan phien khi ca hai cho).
// l_err (dia chi trong cua so cau nhung khong co ngoai vi) -> phan hoi DECERR (2'b11) cho ca burst.
module axi_periph_bridge #(
    parameter IDW = 6
) (
    input  wire clk, input wire rst_n,
    input  wire [IDW-1:0] awid, input wire [31:0] awaddr, input wire [7:0] awlen, input wire [2:0] awsize, input wire [1:0] awburst, input wire awvalid, output wire awready,
    input  wire [31:0] wdata, input wire [3:0] wstrb, input wire wlast, input wire wvalid, output wire wready,
    output wire [IDW-1:0] bid, output wire [1:0] bresp, output wire bvalid, input wire bready,
    input  wire [IDW-1:0] arid, input wire [31:0] araddr, input wire [7:0] arlen, input wire [2:0] arsize, input wire [1:0] arburst, input wire arvalid, output wire arready,
    output wire [IDW-1:0] rid, output wire [31:0] rdata, output wire [1:0] rresp, output wire rlast, output wire rvalid, input wire rready,
    // bus ngoai vi cu
    output wire [31:0] l_addr, output wire l_we, output wire l_re, output wire [3:0] l_wstrb, output wire [31:0] l_wdata,
    input  wire [31:0] l_rdata, input wire l_err
);
    localparam [2:0] IDLE = 0, WDATA = 1, WRESP = 2, RACC = 3, RRSP = 4;
    reg [2:0]  st;
    reg        pref_rd;                              // luan phien: lan truoc phuc vu doc thi lan nay uu tien ghi
    reg [IDW-1:0] id_r; reg [31:0] a_r; reg [7:0] len_r, cnt; reg [2:0] sz_r; reg [1:0] bt_r;
    reg        err_r; reg [31:0] rd_r;

    function [31:0] nxt(input [31:0] a, input [2:0] sz, input [1:0] bt, input [7:0] ln);
        reg [31:0] step, wrap, inc;
        begin
            step = 32'd1 << sz; inc = (a & ~(step - 32'd1)) + step; wrap = ({24'd0, ln} + 32'd1) << sz;
            case (bt) 2'b00: nxt = a; 2'b10: nxt = (a & ~(wrap - 32'd1)) | (inc & (wrap - 32'd1)); default: nxt = inc; endcase
        end
    endfunction

    wire take_w = (st == IDLE) & awvalid & (~pref_rd | ~arvalid);
    wire take_r = (st == IDLE) & arvalid & ~take_w;
    assign awready = take_w;
    assign arready = take_r;

    assign l_addr  = a_r;
    assign l_wdata = wdata;
    assign l_wstrb = wstrb;
    assign l_we    = (st == WDATA) & wvalid;
    assign wready  = (st == WDATA);
    assign l_re    = (st == RACC);
    assign bid     = id_r; assign bresp = err_r ? 2'b11 : 2'b00; assign bvalid = (st == WRESP);
    assign rid     = id_r; assign rdata = rd_r; assign rresp = err_r ? 2'b11 : 2'b00; assign rvalid = (st == RRSP); assign rlast = (cnt == len_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin st <= IDLE; pref_rd <= 1'b0; id_r <= 0; a_r <= 0; len_r <= 0; cnt <= 0; sz_r <= 0; bt_r <= 0; err_r <= 0; rd_r <= 0; end
        else case (st)
            IDLE: begin
                if (take_w) begin id_r <= awid; a_r <= awaddr; len_r <= awlen; sz_r <= awsize; bt_r <= awburst; cnt <= 0; err_r <= 1'b0; st <= WDATA; pref_rd <= 1'b1; end
                else if (take_r) begin id_r <= arid; a_r <= araddr; len_r <= arlen; sz_r <= arsize; bt_r <= arburst; cnt <= 0; err_r <= 1'b0; st <= RACC; pref_rd <= 1'b0; end
            end
            WDATA: if (wvalid) begin
                if (l_err) err_r <= 1'b1;
                a_r <= nxt(a_r, sz_r, bt_r, len_r); cnt <= cnt + 8'd1;
                if (wlast) st <= WRESP;
            end
            WRESP: if (bready) st <= IDLE;
            RACC: begin rd_r <= l_rdata; if (l_err) err_r <= 1'b1; st <= RRSP; end
            RRSP: if (rready) begin
                if (rlast) st <= IDLE;
                else begin a_r <= nxt(a_r, sz_r, bt_r, len_r); cnt <= cnt + 8'd1; st <= RACC; end
            end
            default: st <= IDLE;
        endcase
    end
endmodule
