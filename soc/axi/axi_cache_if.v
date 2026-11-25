// Cau noi giua giao dien 1-tu cua cache (m_req giu toi m_ack) va AXI4 master, tu viet.
// axi_icache_master: cache lenh chi nap dong (doc tuan tu tu dau dong, WORDS tu) -> 1 burst INCR AWLEN = WORDS - 1, moi beat R = 1 m_ack.
// axi_dcache_master: nap dong (m_fill) -> 1 burst INCR; doc ngoai vung cacheable -> 1 beat; ghi xuyen (m_we) -> 1 beat, m_ack khi nhan B (store toi duoc bo nho roi moi pop
// bo dem ghi, nen FENCE / FENCE.I cua loi dung nghia). Moi lan 1 giao dich. `err` = xung 1 chu ky khi co phan hoi SLVERR / DECERR (SYSCON dem nhu bus_err cu).
module axi_icache_master #(
    parameter WORDS = 4,
    parameter IDW   = 4,
    parameter [IDW-1:0] ID = 0
) (
    input  wire clk, input wire rst_n,
    input  wire m_req, input wire [31:0] m_addr, output wire m_ack, output wire [31:0] m_rdata,
    output wire [IDW-1:0] arid, output wire [31:0] araddr, output wire [7:0] arlen, output wire [2:0] arsize, output wire [1:0] arburst, output wire arvalid, input wire arready,
    input  wire [IDW-1:0] rid, input wire [31:0] rdata, input wire [1:0] rresp, input wire rlast, input wire rvalid, output wire rready
);
    reg [1:0]  st;                 // 0 nghi, 1 phat AR, 2 nhan R
    reg [31:0] a_r;
    assign arid = ID; assign araddr = a_r; assign arlen = WORDS - 1; assign arsize = 3'd2; assign arburst = 2'b01;
    assign arvalid = (st == 2'd1);
    assign rready  = (st == 2'd2);
    assign m_ack   = (st == 2'd2) & rvalid;
    assign m_rdata = rdata;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin st <= 2'd0; a_r <= 32'd0; end
        else case (st)
            2'd0: if (m_req) begin a_r <= m_addr; st <= 2'd1; end
            2'd1: if (arready) st <= 2'd2;
            2'd2: if (rvalid && rlast) st <= 2'd0;
            default: st <= 2'd0;
        endcase
    end
endmodule

module axi_dcache_master #(
    parameter WORDS  = 4,
    parameter IDW    = 4,
    parameter [IDW-1:0] ID = 1,
    parameter POSTED = 1       // 1: ghi xong (m_ack) khi AW va W deu duoc nhan, B nhan sau (toi da vai giao dich dang bay); 0: m_ack khi nhan B
) (
    input  wire clk, input wire rst_n,
    input  wire m_req, input wire m_we, input wire m_fill, input wire [31:0] m_addr, input wire [31:0] m_wdata, input wire [3:0] m_wstrb,
    output wire m_ack, output wire [31:0] m_rdata, output wire err,
    output wire [IDW-1:0] awid, output wire [31:0] awaddr, output wire [7:0] awlen, output wire [2:0] awsize, output wire [1:0] awburst, output wire awvalid, input wire awready,
    output wire [31:0] wdata, output wire [3:0] wstrb, output wire wlast, output wire wvalid, input wire wready,
    input  wire [IDW-1:0] bid, input wire [1:0] bresp, input wire bvalid, output wire bready,
    output wire [IDW-1:0] arid, output wire [31:0] araddr, output wire [7:0] arlen, output wire [2:0] arsize, output wire [1:0] arburst, output wire arvalid, input wire arready,
    input  wire [IDW-1:0] rid, input wire [31:0] rdata, input wire [1:0] rresp, input wire rlast, input wire rvalid, output wire rready
);
    // POSTED = 1 dua tren tinh chat cua cac slave trong SoC nay: ghi co hieu luc ngay khi beat W cuoi duoc nhan (axi_mem, cau ngoai vi), nen thu tu "ghi roi doc / ghi roi
    // nap lenh" giu nguyen du B toi sau. Rieng doc ngoai vung cacheable (thanh ghi thiet bi) van cho het B truoc de loi bao cho lenh sau (vi du doc BUSERR) luon thay ket qua.
    localparam [2:0] IDLE = 0, RAR = 1, RD = 2, WR = 3, WB = 4;
    reg [2:0]  st;
    reg [31:0] a_r, d_r; reg [3:0] s_r; reg fill_r, aw_d, w_d, e_seen; reg [2:0] outst;
    wire aw_ok = aw_d | (awvalid & awready);
    wire w_ok  = w_d  | (wvalid & wready);
    assign awid = ID; assign awaddr = a_r; assign awlen = 8'd0; assign awsize = 3'd2; assign awburst = 2'b01;
    assign wdata = d_r; assign wstrb = s_r; assign wlast = 1'b1;
    assign awvalid = (st == WR) & ~aw_d;
    assign wvalid  = (st == WR) & ~w_d;
    assign bready  = (POSTED != 0) ? 1'b1 : (st == WB);
    assign arid = ID; assign araddr = a_r; assign arlen = fill_r ? (WORDS - 1) : 8'd0; assign arsize = 3'd2; assign arburst = 2'b01;
    assign arvalid = (st == RAR);
    assign rready  = (st == RD);
    wire   wr_acked = (POSTED != 0) ? ((st == WR) & aw_ok & w_ok) : ((st == WB) & bvalid);
    assign m_ack   = ((st == RD) & rvalid) | wr_acked;
    assign m_rdata = rdata;
    // 1 xung moi giao dich loi (nap dong DECERR co WORDS beat nhung chi dem 1 lan)
    assign err     = (((st == RD) & rvalid & (rresp != 2'b00) & ~e_seen) | (bvalid & bready & (bresp != 2'b00)));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin st <= IDLE; a_r <= 32'd0; d_r <= 32'd0; s_r <= 4'd0; fill_r <= 1'b0; aw_d <= 1'b0; w_d <= 1'b0; e_seen <= 1'b0; outst <= 3'd0; end
        else begin
            if (POSTED != 0) outst <= outst + {2'b00, wr_acked} - {2'b00, bvalid};
            case (st)
                IDLE: if (m_req && (m_we || m_fill || outst == 3'd0 || POSTED == 0)) begin
                    e_seen <= 1'b0; a_r <= m_addr; d_r <= m_wdata; s_r <= m_wstrb; fill_r <= m_fill & ~m_we; aw_d <= 1'b0; w_d <= 1'b0;
                    st <= m_we ? WR : RAR;
                end
                RAR: if (arready) st <= RD;
                RD:  begin if (rvalid && rresp != 2'b00) e_seen <= 1'b1; if (rvalid && rlast) st <= IDLE; end
                WR:  begin
                    if (awvalid && awready) aw_d <= 1'b1;
                    if (wvalid && wready) w_d <= 1'b1;
                    if (aw_ok && w_ok) st <= (POSTED != 0) ? IDLE : WB;
                end
                WB:  if (bvalid) st <= IDLE;
                default: st <= IDLE;
            endcase
        end
    end
endmodule
