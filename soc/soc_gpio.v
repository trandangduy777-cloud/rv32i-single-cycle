// GPIO cho SoC, N chan. Thanh ghi (addr = offset[5:2], moi thanh ghi N bit thap; ghi theo byte-lane voi wstrb):
//   0x00 OUT   R/W  gia tri xuat            0x04 IN   R  gia tri chan sau 2 flip-flop dong bo (doc duoc ca chan dang xuat)
//   0x08 DIR   R/W  1 = chan xuat (reset 0) 0x0C IE   R/W  cho phep ngat tung chan
//   0x10 PEND  R    su kien da ghi nhan; W1C (ghi 1 de xoa; su kien moi cung chu ky thang)
//   0x14 EDGE  R/W  0 = canh len, 1 = canh xuong (theo tung chan)
//   0x18 SET   W    OUT |= wdata            0x1C CLR  W  OUT &= ~wdata            0x20 TGL  W  OUT ^= wdata   (doc: 0)
// gpio_out/gpio_oe noi toi o chan (o chan: oe ? out : ben ngoai); gpio_in la gia tri that tren chan. irq = |(PEND & IE), muc cao.
module soc_gpio #(
    parameter N = 16
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         sel,
    input  wire [5:2]   addr,
    input  wire         we,
    input  wire [3:0]   wstrb,
    input  wire [31:0]  wdata,
    output reg  [31:0]  rdata,
    input  wire [N-1:0] gpio_in,
    output wire [N-1:0] gpio_out,
    output wire [N-1:0] gpio_oe,
    output wire         irq
);
    reg [N-1:0] out_r, dir_r, ie_r, pend_r, edge_r, in_s1, in_s2, in_q;
    wire [31:0] wmask = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};
    wire [N-1:0] wd = wdata[N-1:0];
    wire [N-1:0] wm = wmask[N-1:0];
    wire         wr = sel & we;
    wire [N-1:0] rise = in_s2 & ~in_q;
    wire [N-1:0] fall = ~in_s2 & in_q;
    wire [N-1:0] ev   = (rise & ~edge_r) | (fall & edge_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_r <= {N{1'b0}}; dir_r <= {N{1'b0}}; ie_r <= {N{1'b0}}; pend_r <= {N{1'b0}}; edge_r <= {N{1'b0}};
            in_s1 <= {N{1'b0}}; in_s2 <= {N{1'b0}}; in_q <= {N{1'b0}};
        end else begin
            in_s1 <= gpio_in; in_s2 <= in_s1; in_q <= in_s2;
            if (wr) case (addr)
                4'd0: out_r  <= (out_r  & ~wm) | (wd & wm);
                4'd2: dir_r  <= (dir_r  & ~wm) | (wd & wm);
                4'd3: ie_r   <= (ie_r   & ~wm) | (wd & wm);
                4'd5: edge_r <= (edge_r & ~wm) | (wd & wm);
                4'd6: out_r  <= out_r |  (wd & wm);
                4'd7: out_r  <= out_r & ~(wd & wm);
                4'd8: out_r  <= out_r ^  (wd & wm);
                default: ;
            endcase
            pend_r <= (pend_r & ~((wr && addr == 4'd4) ? (wd & wm) : {N{1'b0}})) | ev;
        end
    end

    always @* begin
        case (addr)
            4'd0:    rdata = {{(32-N){1'b0}}, out_r};
            4'd1:    rdata = {{(32-N){1'b0}}, in_s2};
            4'd2:    rdata = {{(32-N){1'b0}}, dir_r};
            4'd3:    rdata = {{(32-N){1'b0}}, ie_r};
            4'd4:    rdata = {{(32-N){1'b0}}, pend_r};
            4'd5:    rdata = {{(32-N){1'b0}}, edge_r};
            default: rdata = 32'd0;
        endcase
    end

    assign gpio_out = out_r;
    assign gpio_oe  = dir_r;
    assign irq      = |(pend_r & ie_r);
endmodule
