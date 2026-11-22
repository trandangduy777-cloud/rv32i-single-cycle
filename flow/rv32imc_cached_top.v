// Dinh cho flow: pipeline RV32IMC + cache lenh + cache du lieu (16 dong x 4 tu moi cache) + bo phan xu bus.
// Ra ngoai chi con 1 bus bo nho (m_*). Mang nho cua cache duoc tong hop thanh flip-flop vi repo chua co macro
// SRAM cho IHP SG13G2: dien tich la so tham khao, cao hon nhieu so voi chip dung SRAM that.
module rv32imc_cached_top (
    input  wire        clk,
    input  wire        rst_n,
    output wire        m_req,
    output wire        m_we,
    output wire [31:0] m_addr,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    input  wire        m_ack,
    input  wire [31:0] m_rdata,
    input  wire        irq_timer,
    input  wire        irq_soft,
    input  wire        irq_ext
);
    wire [31:0] imem_addr, imem_data, dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we, dmem_re, dmem_fence, imem_ready, dmem_ready, icache_flush;
    wire        ic_req, ic_ack, dc_req, dc_we, dc_ack;
    wire [31:0] ic_addr, dc_addr, dc_wdata, ic_miss, dc_miss;
    wire [3:0]  dc_wstrb;

    rv32im_pipeline #(.ENABLE_C(1)) u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data), .imem_ready(imem_ready),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_re(dmem_re), .dmem_fence(dmem_fence), .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
        .icache_flush(icache_flush),
        .irq_timer(irq_timer), .irq_soft(irq_soft), .irq_ext(irq_ext)
    );
    rv32_icache #(.LINES(16), .WORDS(4)) u_ic (
        .clk(clk), .rst_n(rst_n), .addr(imem_addr), .data(imem_data), .ready(imem_ready), .flush(icache_flush),
        .m_req(ic_req), .m_addr(ic_addr), .m_ack(ic_ack), .m_rdata(m_rdata), .n_miss(ic_miss));
    // vung cacheable: 0x0000_0000-0x7FFF_FFFF; tu 0x8000_0000 tro len la thiet bi, di thang qua bus
    rv32_dcache #(.LINES(16), .WORDS(4), .CMASK(32'h8000_0000), .CBASE(32'h0000_0000)) u_dc (
        .clk(clk), .rst_n(rst_n), .addr(dmem_addr), .re(dmem_re), .we(dmem_we), .fence(dmem_fence), .wstrb(dmem_wstrb),
        .wdata(dmem_wdata), .rdata(dmem_rdata), .ready(dmem_ready),
        .m_req(dc_req), .m_we(dc_we), .m_addr(dc_addr), .m_wdata(dc_wdata), .m_wstrb(dc_wstrb),
        .m_ack(dc_ack), .m_rdata(m_rdata), .n_miss(dc_miss));
    rv32_bus_arbiter u_arb (
        .clk(clk), .rst_n(rst_n),
        .i_req(ic_req), .i_addr(ic_addr), .i_ack(ic_ack),
        .d_req(dc_req), .d_we(dc_we), .d_addr(dc_addr), .d_wdata(dc_wdata), .d_wstrb(dc_wstrb), .d_ack(dc_ack),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_ack(m_ack));
endmodule
