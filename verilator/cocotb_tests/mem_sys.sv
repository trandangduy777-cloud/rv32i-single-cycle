// He thong bo nho cho test cocotb: rv32_icache + rv32_dcache + rv32_bus_arbiter -> 1 cong bo nho chung (m_*), do bo nho Python phuc vu.
// Chi la day noi, khong them logic. Tham so giong cau hinh cache trong pipeline.
module mem_sys #(
    parameter ILINES = 8, IWORDS = 4, IWAYS = 1,
    parameter LINES = 8, WORDS = 4, WAYS = 1, WBUF = 2,
    parameter [31:0] CMASK = 32'hFFFF0000, CBASE = 32'h0   // >= 0x10000: thiet bi, khong cache
) (
    input  wire        clk,
    input  wire        rst_n,
    // phia lenh
    input  wire [31:0] ia,
    output wire [31:0] idata,
    output wire        iready,
    input  wire        iflush,
    // phia du lieu
    input  wire [31:0] da,
    input  wire        dre,
    input  wire        dwe,
    input  wire        dfence,
    input  wire [3:0]  dwstrb,
    input  wire [31:0] dwdata,
    output wire [31:0] drdata,
    output wire        dready,
    // bo nho chung
    output wire        m_req,
    output wire        m_we,
    output wire [31:0] m_addr,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    input  wire        m_ack,
    input  wire [31:0] m_rdata
);
    wire i_req, i_ack, d_req, d_we, d_ack, dwb_empty;
    wire [31:0] i_addr, d_addr, d_wdata;
    wire [3:0]  d_wstrb;
    wire [31:0] n_imiss, n_dmiss;

    rv32_icache #(.LINES(ILINES), .WORDS(IWORDS), .WAYS(IWAYS)) u_ic (
        .clk(clk), .rst_n(rst_n), .addr(ia), .data(idata), .ready(iready), .flush(iflush),
        .m_req(i_req), .m_addr(i_addr), .m_ack(i_ack), .m_rdata(m_rdata), .n_miss(n_imiss));

    rv32_dcache #(.LINES(LINES), .WORDS(WORDS), .WAYS(WAYS), .WBUF(WBUF), .CMASK(CMASK), .CBASE(CBASE)) u_dc (
        .clk(clk), .rst_n(rst_n), .addr(da), .re(dre), .we(dwe), .fence(dfence), .wstrb(dwstrb), .wdata(dwdata),
        .rdata(drdata), .ready(dready), .wb_empty(dwb_empty),
        .m_req(d_req), .m_we(d_we), .m_addr(d_addr), .m_wdata(d_wdata), .m_wstrb(d_wstrb), .m_ack(d_ack), .m_rdata(m_rdata), .n_miss(n_dmiss));

    rv32_bus_arbiter u_arb (
        .clk(clk), .rst_n(rst_n), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_wdata(d_wdata), .d_wstrb(d_wstrb), .d_ack(d_ack),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_ack(m_ack));
endmodule
