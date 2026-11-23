// UART 8N1 cho SoC (bus don gian 32 bit giong rv32_mtimer: doc to hop, ghi dong bo). Thanh ghi (addr = offset[4:2]):
//   0x00 TXDATA  W: byte[7:0] -> bat dau gui (bo qua va dat TXDROP neu dang ban). R: 0
//   0x04 RXDATA  R: byte nhan duoc (doc xong thi RXVALID xoa). W: bo qua
//   0x08 STATUS  R: [0] TXREADY (khong ban) [1] RXVALID [2] RXOVR (nhan byte moi khi RXVALID con 1, byte moi bi bo)
//                   [3] RXFERR (bit stop = 0) [4] TXDROP. Bit 2-4 la sticky, ghi 1 vao bit do de xoa (W1C)
//   0x0C DIV     R/W: so chu ky clock moi bit, 16 bit, nho nhat 4 (ghi gia tri nho hon thi lay 4); reset = DEFAULT_DIV
//   0x10 IE      R/W: [0] ngat khi RXVALID [1] ngat khi TXREADY. irq la muc cao
// Dang khung: bit start 0, 8 bit du lieu LSB truoc, bit stop 1. TX chot DIV luc bat dau khung. RX dong bo 2 flip-flop,
// bat canh xuong, lay mau giua bit start (loai nhieu < nua bit), roi giua moi bit; byte nhan duoc ke ca khi bit stop = 0 (kem co RXFERR).
module soc_uart #(
    parameter [15:0] DEFAULT_DIV = 16'd16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sel,
    input  wire [4:2]  addr,
    input  wire        we,
    input  wire        re,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        rx,
    output wire        tx,
    output wire        irq
);
    reg [15:0] div;
    reg [1:0]  ie;

    // ---------------- TX ----------------
    reg        busy, tx_drop;
    reg [9:0]  txs;
    reg [3:0]  txn;
    reg [15:0] txc, txd;
    wire       wr_tx = sel & we & (addr == 3'd0) & wstrb[0];
    assign tx = busy ? txs[0] : 1'b1;
    wire tx_ready = ~busy;

    // ---------------- RX ----------------
    reg        rx_s1, rx_s2;
    reg [2:0]  rst_;                 // trang thai: 0 ranh, 1 kiem tra start, 2 du lieu, 3 stop, 4 cho duong len cao
    reg [15:0] rc;
    reg [2:0]  rn;
    reg [7:0]  rbuf, rx_data;
    reg        rx_valid, rx_ovr, rx_ferr;
    wire       pop = sel & re & (addr == 3'd1);
    wire       w_status = sel & we & (addr == 3'd2) & wstrb[0];
    wire [15:0] wmask16 = {{8{wstrb[1]}}, {8{wstrb[0]}}};
    wire [15:0] div_new = (div & ~wmask16) | (wdata[15:0] & wmask16);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div <= DEFAULT_DIV; ie <= 2'b00;
            busy <= 1'b0; tx_drop <= 1'b0; txs <= 10'h3FF; txn <= 4'd0; txc <= 16'd0; txd <= DEFAULT_DIV;
            rx_s1 <= 1'b1; rx_s2 <= 1'b1; rst_ <= 3'd0; rc <= 16'd0; rn <= 3'd0; rbuf <= 8'd0; rx_data <= 8'd0;
            rx_valid <= 1'b0; rx_ovr <= 1'b0; rx_ferr <= 1'b0;
        end else begin
            // ---- thanh ghi cau hinh ----
            if (sel & we & (addr == 3'd3) & (wstrb[1] | wstrb[0])) div <= (div_new < 16'd4) ? 16'd4 : div_new;
            if (sel & we & (addr == 3'd4) & wstrb[0]) ie <= wdata[1:0];

            // ---- TX ----
            if (wr_tx & ~busy) begin
                txs <= {1'b1, wdata[7:0], 1'b0}; txd <= div; txc <= div - 16'd1; txn <= 4'd0; busy <= 1'b1;
            end else if (busy) begin
                if (txc == 16'd0) begin
                    txc <= txd - 16'd1; txs <= {1'b1, txs[9:1]}; txn <= txn + 4'd1;
                    if (txn == 4'd9) busy <= 1'b0;
                end else txc <= txc - 16'd1;
            end

            // ---- RX ----
            rx_s1 <= rx; rx_s2 <= rx_s1;
            if (pop) rx_valid <= 1'b0;
            if (w_status) begin
                if (wdata[2]) rx_ovr  <= 1'b0;
                if (wdata[3]) rx_ferr <= 1'b0;
                if (wdata[4]) tx_drop <= 1'b0;
            end
            case (rst_)
                3'd0: if (!rx_s2) begin rst_ <= 3'd1; rc <= {1'b0, div[15:1]} - 16'd1; end
                3'd1: if (rc == 16'd0) begin
                          if (rx_s2) rst_ <= 3'd0;                  // nhieu, khong phai bit start
                          else begin rst_ <= 3'd2; rc <= div - 16'd1; rn <= 3'd0; end
                      end else rc <= rc - 16'd1;
                3'd2: if (rc == 16'd0) begin
                          rbuf <= {rx_s2, rbuf[7:1]}; rc <= div - 16'd1; rn <= rn + 3'd1;
                          if (rn == 3'd7) rst_ <= 3'd3;
                      end else rc <= rc - 16'd1;
                3'd3: if (rc == 16'd0) begin
                          if (rx_valid & ~pop) rx_ovr <= 1'b1;
                          else begin rx_data <= rbuf; rx_valid <= 1'b1; end
                          if (!rx_s2) rx_ferr <= 1'b1;
                          rst_ <= rx_s2 ? 3'd0 : 3'd4;
                      end else rc <= rc - 16'd1;
                3'd4: if (rx_s2) rst_ <= 3'd0;
                default: rst_ <= 3'd0;
            endcase
            // sticky do su kien moi thang lenh xoa cung chu ky; tx_drop dat sau cung
            if (wr_tx & busy) tx_drop <= 1'b1;
        end
    end

    always @* begin
        case (addr)
            3'd1:    rdata = {24'd0, rx_data};
            3'd2:    rdata = {27'd0, tx_drop, rx_ferr, rx_ovr, rx_valid, tx_ready};
            3'd3:    rdata = {16'd0, div};
            3'd4:    rdata = {30'd0, ie};
            default: rdata = 32'd0;
        endcase
    end

    assign irq = (ie[0] & rx_valid) | (ie[1] & tx_ready);
endmodule
