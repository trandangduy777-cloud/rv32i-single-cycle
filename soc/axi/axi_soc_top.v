// SoC voi bus AXI4 (soc_axi_top): cung chuc nang va ban do dia chi nhu soc_top, them cache lenh + cache du lieu nap dong bang burst, DMA 2 kenh, va them 1 cua so RAM khong qua cache.
// Master: M0 = cache lenh (doc burst), M1 = cache du lieu (nap dong burst, ghi xuyen 1 beat, doc ngoai vi 1 beat), M2 = DMA. Slave: S0 = ROM, S1 = RAM, S2 = cau AXI4 -> bus ngoai vi cu (CLINT, PLIC, UART, GPIO, SYSCON, DMA).
// Ban do: nhu soc_top (ROM 0x0000_0000 16 KB, CLINT 0x0200_0000, PLIC 0x0C00_0000, RAM 0x1000_0000 16 KB, UART 0x2000_0000, GPIO 0x2000_1000, SYSCON 0x2000_2000) cong:
//   DMA 0x2001_0000 (thanh ghi) va 0x4000_0000 = bi danh RAM, KHONG qua cache du lieu (CMASK / CBASE chi cache 0x1000_0000..0x1FFF_FFFF) - bo dem cua DMA dat o day de khong bi dong cache cu.
// Ngat PLIC: nguon 1..7 nhu soc_top, 8 = DMA kenh 0, 9 = DMA kenh 1.
// Cache du lieu / lenh la write-through, khong tu dong nhat quan voi DMA: phan mem dung cua so 0x4000_0000 cho bo dem DMA, hoac FENCE / FENCE.I truoc khi doc lai vung cacheable.
module soc_axi_top #(
    parameter        ROM_WORDS   = 4096,
    parameter        RAM_WORDS   = 4096,
    parameter        ROM_INIT    = "",
    parameter [15:0] UART_DIV    = 16'd434,
    parameter        MTIME_PRESC = 1,
    parameter        GPIO_N      = 16,
    parameter        UART_RX_DEPTH = 8,
    parameter        IC_LINES = 128, parameter IC_WORDS = 4, parameter IC_WAYS = 2,
    parameter        DC_LINES = 64, parameter DC_WORDS = 4, parameter DC_WAYS = 2, parameter DC_WBUF = 4,
    parameter        RAM_STALL = 0, parameter ROM_RLAT = 0, parameter ROM_BDLY = 12        // tham so kiem thu: lam cham bo nho de thu core chiu tre
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              uart_rx,
    output wire              uart_tx,
    input  wire [3:0]        ext_irq,
    input  wire [GPIO_N-1:0] gpio_in,
    output wire [GPIO_N-1:0] gpio_out,
    output wire [GPIO_N-1:0] gpio_oe,
    output wire              exit_valid,
    output wire [31:0]       exit_code
);
    localparam IDW = 4, NM = 3, NS = 3, SIDW = 6;

    // ---------------- loi + cache ----------------
    wire [31:0] imem_addr, imem_data, dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we, dmem_re, dmem_fence, icache_flush, imem_ready, dmem_ready;
    wire        irq_timer, irq_soft, irq_ext;

    rv32im_pipeline #(.ENABLE_C(1)) u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data), .imem_ready(imem_ready),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_re(dmem_re), .dmem_fence(dmem_fence), .icache_flush(icache_flush), .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
        .irq_timer(irq_timer), .irq_soft(irq_soft), .irq_ext(irq_ext)
    );

    wire ic_req, ic_ack; wire [31:0] ic_addr, ic_rdata;
    rv32_icache #(.LINES(IC_LINES), .WORDS(IC_WORDS), .WAYS(IC_WAYS)) u_ic (
        .clk(clk), .rst_n(rst_n), .addr(imem_addr), .data(imem_data), .ready(imem_ready), .flush(icache_flush),
        .m_req(ic_req), .m_addr(ic_addr), .m_ack(ic_ack), .m_rdata(ic_rdata), .n_miss()
    );
    wire dc_req, dc_we, dc_fill, dc_ack, dc_err; wire [31:0] dc_addr, dc_wdata, dc_rdata; wire [3:0] dc_wstrb;
    rv32_dcache #(.LINES(DC_LINES), .WORDS(DC_WORDS), .WAYS(DC_WAYS), .WBUF(DC_WBUF), .CMASK(32'hF000_0000), .CBASE(32'h1000_0000)) u_dc (
        .clk(clk), .rst_n(rst_n), .addr(dmem_addr), .re(dmem_re), .we(dmem_we), .fence(dmem_fence), .wstrb(dmem_wstrb), .wdata(dmem_wdata),
        .rdata(dmem_rdata), .ready(dmem_ready), .wb_empty(),
        .m_req(dc_req), .m_we(dc_we), .m_fill(dc_fill), .m_addr(dc_addr), .m_wdata(dc_wdata), .m_wstrb(dc_wstrb), .m_ack(dc_ack), .m_rdata(dc_rdata), .n_miss()
    );

    // ---------------- cac master AXI ----------------
    wire [IDW-1:0] i_arid; wire [31:0] i_araddr; wire [7:0] i_arlen; wire [2:0] i_arsize; wire [1:0] i_arburst; wire i_arvalid, i_arready;
    wire [IDW-1:0] i_rid; wire [31:0] i_rdata; wire [1:0] i_rresp; wire i_rlast, i_rvalid, i_rready;
    axi_icache_master #(.WORDS(IC_WORDS), .IDW(IDW), .ID(0)) u_im (
        .clk(clk), .rst_n(rst_n), .m_req(ic_req), .m_addr(ic_addr), .m_ack(ic_ack), .m_rdata(ic_rdata),
        .arid(i_arid), .araddr(i_araddr), .arlen(i_arlen), .arsize(i_arsize), .arburst(i_arburst), .arvalid(i_arvalid), .arready(i_arready),
        .rid(i_rid), .rdata(i_rdata), .rresp(i_rresp), .rlast(i_rlast), .rvalid(i_rvalid), .rready(i_rready));

    wire [IDW-1:0] d_awid, d_arid, d_bid, d_rid; wire [31:0] d_awaddr, d_wdata, d_araddr, d_rdata; wire [7:0] d_awlen, d_arlen; wire [2:0] d_awsize, d_arsize;
    wire [1:0] d_awburst, d_arburst, d_bresp, d_rresp; wire [3:0] d_wstrb;
    wire d_awvalid, d_awready, d_wlast, d_wvalid, d_wready, d_bvalid, d_bready, d_arvalid, d_arready, d_rlast, d_rvalid, d_rready;
    axi_dcache_master #(.WORDS(DC_WORDS), .IDW(IDW), .ID(1)) u_dm (
        .clk(clk), .rst_n(rst_n), .m_req(dc_req), .m_we(dc_we), .m_fill(dc_fill), .m_addr(dc_addr), .m_wdata(dc_wdata), .m_wstrb(dc_wstrb),
        .m_ack(dc_ack), .m_rdata(dc_rdata), .err(dc_err),
        .awid(d_awid), .awaddr(d_awaddr), .awlen(d_awlen), .awsize(d_awsize), .awburst(d_awburst), .awvalid(d_awvalid), .awready(d_awready),
        .wdata(d_wdata), .wstrb(d_wstrb), .wlast(d_wlast), .wvalid(d_wvalid), .wready(d_wready),
        .bid(d_bid), .bresp(d_bresp), .bvalid(d_bvalid), .bready(d_bready),
        .arid(d_arid), .araddr(d_araddr), .arlen(d_arlen), .arsize(d_arsize), .arburst(d_arburst), .arvalid(d_arvalid), .arready(d_arready),
        .rid(d_rid), .rdata(d_rdata), .rresp(d_rresp), .rlast(d_rlast), .rvalid(d_rvalid), .rready(d_rready));

    wire [IDW-1:0] a_awid, a_arid, a_bid, a_rid; wire [31:0] a_awaddr, a_wdata, a_araddr, a_rdata; wire [7:0] a_awlen, a_arlen; wire [2:0] a_awsize, a_arsize;
    wire [1:0] a_awburst, a_arburst, a_bresp, a_rresp; wire [3:0] a_wstrb;
    wire a_awvalid, a_awready, a_wlast, a_wvalid, a_wready, a_bvalid, a_bready, a_arvalid, a_arready, a_rlast, a_rvalid, a_rready;
    wire [31:0] dma_rd; wire [1:0] dma_irq; wire sel_dma;
    wire [31:0] l_addr, l_wdata, l_rdata; wire [3:0] l_wstrb; wire l_we, l_re, l_err;
    axi_dma #(.NCH(2), .IDW(IDW)) u_dma (
        .clk(clk), .rst_n(rst_n), .sel(sel_dma), .addr(l_addr[6:2]), .we(l_we), .wstrb(l_wstrb), .wdata(l_wdata), .rdata(dma_rd), .irq(dma_irq),
        .awid(a_awid), .awaddr(a_awaddr), .awlen(a_awlen), .awsize(a_awsize), .awburst(a_awburst), .awvalid(a_awvalid), .awready(a_awready),
        .wdata_o(a_wdata), .wstrb_o(a_wstrb), .wlast(a_wlast), .wvalid(a_wvalid), .wready(a_wready),
        .bid(a_bid), .bresp(a_bresp), .bvalid(a_bvalid), .bready(a_bready),
        .arid(a_arid), .araddr(a_araddr), .arlen(a_arlen), .arsize(a_arsize), .arburst(a_arburst), .arvalid(a_arvalid), .arready(a_arready),
        .rid(a_rid), .rdata_i(a_rdata), .rresp(a_rresp), .rlast(a_rlast), .rvalid(a_rvalid), .rready(a_rready));

    // ---------------- interconnect ----------------
    wire [NM*IDW-1:0] s_awid = {a_awid, d_awid, {IDW{1'b0}}};
    wire [NM*32-1:0]  s_awaddr = {a_awaddr, d_awaddr, 32'd0};
    wire [NM*8-1:0]   s_awlen = {a_awlen, d_awlen, 8'd0};
    wire [NM*3-1:0]   s_awsize = {a_awsize, d_awsize, 3'd0};
    wire [NM*2-1:0]   s_awburst = {a_awburst, d_awburst, 2'd0};
    wire [NM-1:0]     s_awvalid = {a_awvalid, d_awvalid, 1'b0};
    wire [NM-1:0]     s_awready;
    wire [NM*32-1:0]  s_wdata = {a_wdata, d_wdata, 32'd0};
    wire [NM*4-1:0]   s_wstrb = {a_wstrb, d_wstrb, 4'd0};
    wire [NM-1:0]     s_wlast = {a_wlast, d_wlast, 1'b0};
    wire [NM-1:0]     s_wvalid = {a_wvalid, d_wvalid, 1'b0};
    wire [NM-1:0]     s_wready;
    wire [NM*IDW-1:0] s_bid; wire [NM*2-1:0] s_bresp; wire [NM-1:0] s_bvalid;
    wire [NM-1:0]     s_bready = {a_bready, d_bready, 1'b0};
    wire [NM*IDW-1:0] s_arid = {a_arid, d_arid, i_arid};
    wire [NM*32-1:0]  s_araddr = {a_araddr, d_araddr, i_araddr};
    wire [NM*8-1:0]   s_arlen = {a_arlen, d_arlen, i_arlen};
    wire [NM*3-1:0]   s_arsize = {a_arsize, d_arsize, i_arsize};
    wire [NM*2-1:0]   s_arburst = {a_arburst, d_arburst, i_arburst};
    wire [NM-1:0]     s_arvalid = {a_arvalid, d_arvalid, i_arvalid};
    wire [NM-1:0]     s_arready;
    wire [NM*IDW-1:0] s_rid; wire [NM*32-1:0] s_rdata; wire [NM*2-1:0] s_rresp; wire [NM-1:0] s_rlast, s_rvalid;
    wire [NM-1:0]     s_rready = {a_rready, d_rready, i_rready};
    assign i_arready = s_arready[0]; assign d_arready = s_arready[1]; assign a_arready = s_arready[2];
    assign d_awready = s_awready[1]; assign a_awready = s_awready[2];
    assign d_wready = s_wready[1]; assign a_wready = s_wready[2];
    assign d_bid = s_bid[IDW +: IDW]; assign d_bresp = s_bresp[2 +: 2]; assign d_bvalid = s_bvalid[1];
    assign a_bid = s_bid[2*IDW +: IDW]; assign a_bresp = s_bresp[4 +: 2]; assign a_bvalid = s_bvalid[2];
    assign i_rid = s_rid[0 +: IDW]; assign i_rdata = s_rdata[31:0]; assign i_rresp = s_rresp[1:0]; assign i_rlast = s_rlast[0]; assign i_rvalid = s_rvalid[0];
    assign d_rid = s_rid[IDW +: IDW]; assign d_rdata = s_rdata[63:32]; assign d_rresp = s_rresp[3:2]; assign d_rlast = s_rlast[1]; assign d_rvalid = s_rvalid[1];
    assign a_rid = s_rid[2*IDW +: IDW]; assign a_rdata = s_rdata[95:64]; assign a_rresp = s_rresp[5:4]; assign a_rlast = s_rlast[2]; assign a_rvalid = s_rvalid[2];

    wire [NS*SIDW-1:0] m_awid, m_bid, m_arid, m_rid; wire [NS*32-1:0] m_awaddr, m_wdata, m_araddr, m_rdata; wire [NS*8-1:0] m_awlen, m_arlen;
    wire [NS*3-1:0] m_awsize, m_arsize; wire [NS*2-1:0] m_awburst, m_arburst, m_bresp, m_rresp; wire [NS*4-1:0] m_wstrb;
    wire [NS-1:0] m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;

    // vung: 0 ROM, 1 RAM, 2 RAM bi danh, 3 CLINT, 4 PLIC, 5 ngoai vi 0x2000_0000..0x2001_FFFF (cau ngoai vi)
    localparam [6*32-1:0] RB = {32'h2000_0000, 32'h0C00_0000, 32'h0200_0000, 32'h4000_0000, 32'h1000_0000, 32'h0000_0000};
    localparam [6*32-1:0] RM = {32'hFFFE_0000, 32'hFFC0_0000, 32'hFFFF_F000, 32'hFFFF_C000, 32'hFFFF_C000, 32'hFFFF_C000};
    localparam [6*8-1:0]  RS = {8'd2, 8'd2, 8'd2, 8'd1, 8'd1, 8'd0};
    axi_xbar #(.NM(NM), .NS(NS), .IDW(IDW), .NR(6), .R_BASE(RB), .R_MASK(RM), .R_SLV(RS), .MAXOUT(4)) u_xbar (
        .clk(clk), .rst_n(rst_n),
        .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize), .s_awburst(s_awburst), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize), .s_arburst(s_arburst), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready));

    `define AXS(S, P, ROMV, WRD, RL, ST, BD, SD) axi_mem #(.WORDS(WRD), .ROM(ROMV), .IDW(SIDW), .RLAT(RL), .STALL(ST), .BDLY(BD), .SEED(SD)) P ( \
        .clk(clk), .rst_n(rst_n), \
        .awid(m_awid[S*SIDW +: SIDW]), .awaddr(m_awaddr[S*32 +: 32]), .awlen(m_awlen[S*8 +: 8]), .awsize(m_awsize[S*3 +: 3]), .awburst(m_awburst[S*2 +: 2]), .awvalid(m_awvalid[S]), .awready(m_awready[S]), \
        .wdata(m_wdata[S*32 +: 32]), .wstrb(m_wstrb[S*4 +: 4]), .wlast(m_wlast[S]), .wvalid(m_wvalid[S]), .wready(m_wready[S]), \
        .bid(m_bid[S*SIDW +: SIDW]), .bresp(m_bresp[S*2 +: 2]), .bvalid(m_bvalid[S]), .bready(m_bready[S]), \
        .arid(m_arid[S*SIDW +: SIDW]), .araddr(m_araddr[S*32 +: 32]), .arlen(m_arlen[S*8 +: 8]), .arsize(m_arsize[S*3 +: 3]), .arburst(m_arburst[S*2 +: 2]), .arvalid(m_arvalid[S]), .arready(m_arready[S]), \
        .rid(m_rid[S*SIDW +: SIDW]), .rdata(m_rdata[S*32 +: 32]), .rresp(m_rresp[S*2 +: 2]), .rlast(m_rlast[S]), .rvalid(m_rvalid[S]), .rready(m_rready[S]));
    `AXS(0, u_rom, 1, ROM_WORDS, ROM_RLAT, 0, ROM_BDLY, 16'h77A3)
    `AXS(1, u_ram, 0, RAM_WORDS, 0, RAM_STALL, 0, 16'hACE1)

    // ---------------- cau ngoai vi + ngoai vi cu ----------------
    axi_periph_bridge #(.IDW(SIDW)) u_br (
        .clk(clk), .rst_n(rst_n),
        .awid(m_awid[2*SIDW +: SIDW]), .awaddr(m_awaddr[64 +: 32]), .awlen(m_awlen[16 +: 8]), .awsize(m_awsize[6 +: 3]), .awburst(m_awburst[4 +: 2]), .awvalid(m_awvalid[2]), .awready(m_awready[2]),
        .wdata(m_wdata[64 +: 32]), .wstrb(m_wstrb[8 +: 4]), .wlast(m_wlast[2]), .wvalid(m_wvalid[2]), .wready(m_wready[2]),
        .bid(m_bid[2*SIDW +: SIDW]), .bresp(m_bresp[4 +: 2]), .bvalid(m_bvalid[2]), .bready(m_bready[2]),
        .arid(m_arid[2*SIDW +: SIDW]), .araddr(m_araddr[64 +: 32]), .arlen(m_arlen[16 +: 8]), .arsize(m_arsize[6 +: 3]), .arburst(m_arburst[4 +: 2]), .arvalid(m_arvalid[2]), .arready(m_arready[2]),
        .rid(m_rid[2*SIDW +: SIDW]), .rdata(m_rdata[64 +: 32]), .rresp(m_rresp[4 +: 2]), .rlast(m_rlast[2]), .rvalid(m_rvalid[2]), .rready(m_rready[2]),
        .l_addr(l_addr), .l_we(l_we), .l_re(l_re), .l_wstrb(l_wstrb), .l_wdata(l_wdata), .l_rdata(l_rdata), .l_err(l_err));

    wire sel_rom_x, sel_ram_x, sel_clint, sel_uart, sel_gpio, sel_sys, sel_plic, bus_err_x, i_rom_x, i_ram_x;
    wire [31:0] clint_rd, uart_rd, gpio_rd, sys_rd, plic_rd, leg_rd;
    wire irq_uart, irq_uart_rx, irq_uart_tx, irq_gpio;
    soc_bus #(.ROM_AW(14), .RAM_AW(14)) u_bus (
        .daddr(l_addr), .dwe(l_we), .dre(l_re),
        .sel_rom(sel_rom_x), .sel_ram(sel_ram_x), .sel_clint(sel_clint), .sel_uart(sel_uart), .sel_gpio(sel_gpio), .sel_sys(sel_sys), .sel_plic(sel_plic),
        .rom_rd(32'd0), .ram_rd(32'd0), .clint_rd(clint_rd), .uart_rd(uart_rd), .gpio_rd(gpio_rd), .sys_rd(sys_rd), .plic_rd(plic_rd),
        .rdata(leg_rd), .bus_err(bus_err_x), .iaddr(32'd0), .i_sel_rom(i_rom_x), .i_sel_ram(i_ram_x));
    assign sel_dma = (l_addr[31:12] == 20'h20010);
    assign l_rdata = leg_rd | ({32{sel_dma}} & dma_rd);
    assign l_err   = (l_re | l_we) & ~(sel_clint | sel_uart | sel_gpio | sel_sys | sel_plic | sel_dma);

    rv32_mtimer #(.PRESCALE(MTIME_PRESC)) u_clint (
        .clk(clk), .rst_n(rst_n), .sel(sel_clint), .addr(l_addr[4:2]), .we(l_we), .wstrb(l_wstrb),
        .wdata(l_wdata), .rdata(clint_rd), .irq(irq_timer), .msip(irq_soft));
    soc_uart #(.DEFAULT_DIV(UART_DIV), .RX_DEPTH(UART_RX_DEPTH)) u_uart (
        .clk(clk), .rst_n(rst_n), .sel(sel_uart), .addr(l_addr[4:2]), .we(l_we), .re(l_re), .wstrb(l_wstrb),
        .wdata(l_wdata), .rdata(uart_rd), .rx(uart_rx), .tx(uart_tx), .irq(irq_uart), .irq_rx(irq_uart_rx), .irq_tx(irq_uart_tx));
    soc_gpio #(.N(GPIO_N)) u_gpio (
        .clk(clk), .rst_n(rst_n), .sel(sel_gpio), .addr(l_addr[5:2]), .we(l_we), .wstrb(l_wstrb),
        .wdata(l_wdata), .rdata(gpio_rd), .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe), .irq(irq_gpio));
    soc_syscon u_sys (
        .clk(clk), .rst_n(rst_n), .sel(sel_sys), .addr(l_addr[4:2]), .we(l_we), .wstrb(l_wstrb),
        .wdata(l_wdata), .rdata(sys_rd), .bus_err(dc_err), .exit_valid(exit_valid), .exit_code(exit_code));
    soc_plic #(.NSRC(9), .PRIO_W(3)) u_plic (
        .clk(clk), .rst_n(rst_n), .sel(sel_plic), .addr(l_addr[21:2]), .we(l_we), .re(l_re), .wstrb(l_wstrb),
        .wdata(l_wdata), .rdata(plic_rd), .src({dma_irq, ext_irq, irq_gpio, irq_uart_tx, irq_uart_rx}), .eip(irq_ext));
endmodule
