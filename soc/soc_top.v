// SoC nho quanh pipeline RV32IMC (rv32im_pipeline, ENABLE_C = 1): ROM + RAM + CLINT (rv32_mtimer) + UART + GPIO + SYSCON qua soc_bus.
// Bo nho to hop nen dmem_ready = imem_ready = 1; khong co cache. irq_ext = ngat UART | ngat GPIO; irq_timer / irq_soft tu CLINT.
module soc_top #(
    parameter        ROM_WORDS   = 4096,                  // 16 KB
    parameter        RAM_WORDS   = 4096,                  // 16 KB
    parameter        ROM_INIT    = "",                    // file hex (moi dong 1 tu 32 bit), de trong = nap tu testbench
    parameter [15:0] UART_DIV    = 16'd434,               // 50 MHz / 115200
    parameter        MTIME_PRESC = 1,
    parameter        GPIO_N      = 16
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              uart_rx,
    output wire              uart_tx,
    input  wire [GPIO_N-1:0] gpio_in,
    output wire [GPIO_N-1:0] gpio_out,
    output wire [GPIO_N-1:0] gpio_oe,
    output wire              exit_valid,
    output wire [31:0]       exit_code
);
    localparam ROM_AW = $clog2(ROM_WORDS) + 2;
    localparam RAM_AW = $clog2(RAM_WORDS) + 2;

    wire [31:0] imem_addr, imem_data, dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we, dmem_re;
    wire        irq_timer, irq_soft, irq_ext, irq_uart, irq_gpio;

    rv32im_pipeline #(.ENABLE_C(1)) u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data), .imem_ready(1'b1),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_re(dmem_re), .dmem_fence(), .icache_flush(), .dmem_rdata(dmem_rdata), .dmem_ready(1'b1),
        .irq_timer(irq_timer), .irq_soft(irq_soft), .irq_ext(irq_ext)
    );

    wire sel_rom, sel_ram, sel_clint, sel_uart, sel_gpio, sel_sys, i_sel_rom, bus_err;
    wire [31:0] rom_rd, ram_rd, clint_rd, uart_rd, gpio_rd, sys_rd, rom_idata;

    soc_bus #(.ROM_AW(ROM_AW), .RAM_AW(RAM_AW)) u_bus (
        .daddr(dmem_addr), .dwe(dmem_we), .dre(dmem_re),
        .sel_rom(sel_rom), .sel_ram(sel_ram), .sel_clint(sel_clint), .sel_uart(sel_uart), .sel_gpio(sel_gpio), .sel_sys(sel_sys),
        .rom_rd(rom_rd), .ram_rd(ram_rd), .clint_rd(clint_rd), .uart_rd(uart_rd), .gpio_rd(gpio_rd), .sys_rd(sys_rd),
        .rdata(dmem_rdata), .bus_err(bus_err), .iaddr(imem_addr), .i_sel_rom(i_sel_rom)
    );

    soc_rom #(.WORDS(ROM_WORDS), .INIT_FILE(ROM_INIT)) u_rom (
        .i_addr(imem_addr), .i_data(rom_idata), .d_addr(dmem_addr), .d_data(rom_rd)
    );
    assign imem_data = i_sel_rom ? rom_idata : 32'd0;

    soc_ram #(.WORDS(RAM_WORDS)) u_ram (
        .clk(clk), .sel(sel_ram), .addr(dmem_addr), .we(dmem_we), .wstrb(dmem_wstrb), .wdata(dmem_wdata), .rdata(ram_rd)
    );

    rv32_mtimer #(.PRESCALE(MTIME_PRESC)) u_clint (
        .clk(clk), .rst_n(rst_n), .sel(sel_clint), .addr(dmem_addr[4:2]), .we(dmem_we), .wstrb(dmem_wstrb),
        .wdata(dmem_wdata), .rdata(clint_rd), .irq(irq_timer), .msip(irq_soft)
    );

    soc_uart #(.DEFAULT_DIV(UART_DIV)) u_uart (
        .clk(clk), .rst_n(rst_n), .sel(sel_uart), .addr(dmem_addr[4:2]), .we(dmem_we), .re(dmem_re), .wstrb(dmem_wstrb),
        .wdata(dmem_wdata), .rdata(uart_rd), .rx(uart_rx), .tx(uart_tx), .irq(irq_uart)
    );

    soc_gpio #(.N(GPIO_N)) u_gpio (
        .clk(clk), .rst_n(rst_n), .sel(sel_gpio), .addr(dmem_addr[5:2]), .we(dmem_we), .wstrb(dmem_wstrb),
        .wdata(dmem_wdata), .rdata(gpio_rd), .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe), .irq(irq_gpio)
    );

    soc_syscon u_sys (
        .clk(clk), .rst_n(rst_n), .sel(sel_sys), .addr(dmem_addr[4:2]), .we(dmem_we), .wstrb(dmem_wstrb),
        .wdata(dmem_wdata), .rdata(sys_rd), .bus_err(bus_err), .exit_valid(exit_valid), .exit_code(exit_code)
    );

    assign irq_ext = irq_uart | irq_gpio;
endmodule
