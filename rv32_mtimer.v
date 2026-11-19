// Bo dem thoi gian may (mtime/mtimecmp) kieu CLINT, giao tiep bus don gian 32 bit, tu viet
// - Thanh ghi (offset tu dia chi co so): 0x0 mtime[31:0], 0x4 mtime[63:32], 0x8 mtimecmp[31:0], 0xC mtimecmp[63:32]
// - mtime tang 1 moi PRESCALE chu ky clock. irq = (mtime >= mtimecmp), giu muc cao cho toi khi phan mem doi mtimecmp.
// - mtimecmp khoi dong = 0xFFFF_FFFF_FFFF_FFFF nen khong co ngat truoc khi phan mem cai dat.
// - Doc combinational, ghi dong bo (cung kieu bo nho du lieu cua loi). sel = dia chi roi vao vung cua khoi nay.
module rv32_mtimer #(
    parameter PRESCALE = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sel,
    input  wire [3:2]  addr,
    input  wire        we,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        irq
);
    reg [63:0] mtime, mtimecmp;
    reg [31:0] pre;
    wire tick = (pre == PRESCALE - 1);

    wire [31:0] wmask = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime    <= 64'd0;
            mtimecmp <= {64{1'b1}};
            pre      <= 32'd0;
        end else begin
            pre <= tick ? 32'd0 : pre + 32'd1;
            if (sel & we & (addr == 2'd0))      mtime[31:0]     <= (mtime[31:0]     & ~wmask) | (wdata & wmask);
            else if (sel & we & (addr == 2'd1)) mtime[63:32]    <= (mtime[63:32]    & ~wmask) | (wdata & wmask);
            else if (tick)                      mtime           <= mtime + 64'd1;
            if (sel & we & (addr == 2'd2))      mtimecmp[31:0]  <= (mtimecmp[31:0]  & ~wmask) | (wdata & wmask);
            if (sel & we & (addr == 2'd3))      mtimecmp[63:32] <= (mtimecmp[63:32] & ~wmask) | (wdata & wmask);
        end
    end

    always @* begin
        case (addr)
            2'd0: rdata = mtime[31:0];
            2'd1: rdata = mtime[63:32];
            2'd2: rdata = mtimecmp[31:0];
            default: rdata = mtimecmp[63:32];
        endcase
    end

    assign irq = (mtime >= mtimecmp);
endmodule
