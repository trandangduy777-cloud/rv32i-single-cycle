// rv32_ram: bo boc RAM 1 cong doc/ghi, DOC DONG BO, ghi theo tung nhom bit (byte). Mot giao dien, hai phien ban chon luc bien dich:
//   - mac dinh: mo hinh mo phong (mang reg), dung cho mo phong va tong hop FPGA / FF (yosys tu suy ra RAM hoac FF);
//   - -DRV32_RAM_IHP: macro SRAM cua IHP SG13G2 (RM_IHPSG13_1P_<hang>x64_c2_bm_bist), chi ho tro DW = 32 hoac 64. Ten cong cua macro lay theo
//     hieu biet cua tac gia chua doi chieu voi file verilog / LEF trong PDK tren may: KIEM LAI soc/mem/ihp_sram_stub.v voi libs.ref/sg13g2_sram/verilog/ truoc khi chay flow.
// Hop dong thoi gian (hai phien ban nhu nhau, tb_ram kiem):
//   - en = 1, we = 0: doc; dout nhan noi dung o addr SAU canh clk (do tre 1 chu ky). en = 1, we = 1: ghi cac nhom bit co be = 1; dout GIU NGUYEN gia tri cu.
//   - en = 0: khong lam gi, dout giu nguyen. Ghi roi doc cung dia chi o chu ky ke tiep thay du lieu moi.
//   - Noi dung ban dau: mac dinh 0 (mo phong), hoac INIT_FILE ($readmemh); UNINIT_X = 1 -> 'x de bat doc vung chua ghi (macro that khong khoi tao).
// Moi bang > 256 bit trong du an (tag / data cua cache, bang du doan) nen dung module nay de doi sang macro khong phai sua noi dung.
module rv32_ram #(
    parameter WORDS     = 1024,
    parameter DW        = 32,
    parameter BW        = 8,                 // so bit moi nhom ghi (be co DW / BW bit)
    parameter INIT_FILE = "",
    parameter UNINIT_X  = 0
) (
    input  wire                     clk,
    input  wire                     en,
    input  wire                     we,
    input  wire [DW/BW-1:0]         be,
    input  wire [$clog2(WORDS)-1:0] addr,
    input  wire [DW-1:0]            din,
    output reg  [DW-1:0]            dout
);
    localparam AW = $clog2(WORDS);
    localparam NB = DW / BW;

`ifndef RV32_RAM_IHP
    // ---------------- phien ban mo phong ----------------
    reg [DW-1:0] mem [0:WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < WORDS; k = k + 1) mem[k] = UNINIT_X ? {DW{1'bx}} : {DW{1'b0}};
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
        dout = UNINIT_X ? {DW{1'bx}} : {DW{1'b0}};
    end
    integer b;
    always @(posedge clk) if (en) begin
        if (we) begin
            for (b = 0; b < NB; b = b + 1) if (be[b]) mem[addr][b*BW +: BW] <= din[b*BW +: BW];
        end else dout <= mem[addr];
    end
`else
    // ---------------- phien ban macro IHP SG13G2 ----------------
    // DW = 64: 1 hang = 1 tu, macro WORDS x 64. DW = 32: 2 tu / hang (addr[0] chon nua), macro (WORDS / 2) x 64.
    localparam ROWS = (DW == 64) ? WORDS : WORDS / 2;
    localparam RAW  = $clog2(ROWS);
    wire [63:0] m_bm, m_din, m_dout;
    wire [RAW-1:0] m_addr;
    reg  half_q;
    generate
        if (DW == 64) begin : g64
            assign m_addr = addr;
            assign m_din  = din;
            genvar gi;
            for (gi = 0; gi < 64; gi = gi + 1) begin : bm assign m_bm[gi] = be[gi / BW]; end
        end else if (DW == 32) begin : g32
            assign m_addr = addr[AW-1:1];
            assign m_din  = {din, din};
            genvar gj;
            for (gj = 0; gj < 32; gj = gj + 1) begin : bm
                assign m_bm[gj]      = ~addr[0] & be[gj / BW];
                assign m_bm[32 + gj] =  addr[0] & be[gj / BW];
            end
        end else begin : gbad
            initial $fatal(1, "rv32_ram: macro IHP chi ho tro DW = 32 hoac 64");
        end
        case (ROWS)
            256:  begin : m256  RM_IHPSG13_1P_256x64_c2_bm_bist  u_m (.A_CLK(clk), .A_MEN(en), .A_WEN(we), .A_REN(~we), .A_ADDR(m_addr), .A_DIN(m_din), .A_DLY(1'b1), .A_BM(m_bm), .A_DOUT(m_dout),
                                .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR({RAW{1'b0}}), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)); end
            512:  begin : m512  RM_IHPSG13_1P_512x64_c2_bm_bist  u_m (.A_CLK(clk), .A_MEN(en), .A_WEN(we), .A_REN(~we), .A_ADDR(m_addr), .A_DIN(m_din), .A_DLY(1'b1), .A_BM(m_bm), .A_DOUT(m_dout),
                                .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR({RAW{1'b0}}), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)); end
            1024: begin : m1024 RM_IHPSG13_1P_1024x64_c2_bm_bist u_m (.A_CLK(clk), .A_MEN(en), .A_WEN(we), .A_REN(~we), .A_ADDR(m_addr), .A_DIN(m_din), .A_DLY(1'b1), .A_BM(m_bm), .A_DOUT(m_dout),
                                .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR({RAW{1'b0}}), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)); end
            2048: begin : m2048 RM_IHPSG13_1P_2048x64_c2_bm_bist u_m (.A_CLK(clk), .A_MEN(en), .A_WEN(we), .A_REN(~we), .A_ADDR(m_addr), .A_DIN(m_din), .A_DLY(1'b1), .A_BM(m_bm), .A_DOUT(m_dout),
                                .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR({RAW{1'b0}}), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)); end
            default: begin : mbad initial $fatal(1, "rv32_ram: khong co macro IHP cho %0d hang x 64 bit (co 256 / 512 / 1024 / 2048)", ROWS); end
        endcase
    endgenerate
    always @(posedge clk) if (en & ~we) half_q <= addr[0];
    always @* dout = (DW == 64) ? m_dout : (half_q ? m_dout[63:32] : m_dout[31:0]);
`endif
endmodule
