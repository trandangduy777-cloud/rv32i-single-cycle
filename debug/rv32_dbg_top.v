// Mo phong debug: rv32im_pipeline (-DDBG) + RAM 1 MB o 0x8000_0000 + Debug Module + JTAG DTM. Mo phong bang Verilator (debug/tb_main.cpp)
// co server remote_bitbang cho OpenOCD. Ghi vao TOHOST (0x8010_0000) ket thuc chuong trinh (ma ra = gia tri ghi).
//   Vung debug 0xFFFF_F800-0xFFFF_FFFF chi truy cap duoc khi hart o D-mode (dbg_mode), phan con lai la RAM / TOHOST.
module rv32_dbg_top #(
    parameter ENABLE_C   = 0,
    parameter MISALIGNED = 0,
    parameter [31:0] IDCODE = 32'h1000_2001
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tck,
    input  wire        tms,
    input  wire        tdi,
    output wire        tdo,
    input  wire        trst_n,
    input  wire        irq_ext,
    input  wire        boot_halt,          // 1: hart dung o lenh dau tien sau reset nguon (nhu resethaltreq), cho debugger
    output reg         done,
    output reg  [31:0] exit_code
);
    localparam [31:0] RAM_BASE = 32'h8000_0000, TOHOST = 32'h8010_0000, IRQSW = 32'h8010_0008;
    localparam MEMW = 1 << 18;                                   // 1 MB
    reg [31:0] mem [0:MEMW-1];
    initial begin : init
        integer i;
        reg [1023:0] fn;
        for (i = 0; i < MEMW; i = i + 1) mem[i] = 32'd0;
        if ($value$plusargs("prog=%s", fn)) $readmemh(fn, mem);
    end

    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we, dmem_re, dmem_fence, icache_flush;
    wire        dbg_mode, halt_req, ndmreset;
    wire        core_rst_n = rst_n & ~ndmreset;

    // ---- DM / DTM ----
    wire        dmi_valid, dmi_write;
    wire [6:0]  dmi_addr;
    wire [31:0] dmi_wdata, dmi_rdata;
    reg         rst_q;
    always @(posedge clk or negedge rst_n) if (!rst_n) rst_q <= 1'b0; else rst_q <= ndmreset;
    wire        hart_reset_ack = rst_q & ~ndmreset;               // ndmreset vua ha: loi vua duoc reset
    wire [31:0] dm_idata, dm_drdata;
    rv32_dtm #(.IDCODE(IDCODE)) u_dtm (.tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo), .trst_n(trst_n), .clk(clk), .rst_n(rst_n),
        .dmi_valid(dmi_valid), .dmi_write(dmi_write), .dmi_addr(dmi_addr), .dmi_wdata(dmi_wdata), .dmi_rdata(dmi_rdata));

    wire in_dbg_i = dbg_mode & (imem_addr[31:11] == 21'h1FFFFF);
    wire in_dbg_d = dbg_mode & (dmem_addr[31:11] == 21'h1FFFFF);
    rv32_dm u_dm (.clk(clk), .rst_n(rst_n), .dmi_valid(dmi_valid), .dmi_write(dmi_write), .dmi_addr(dmi_addr), .dmi_wdata(dmi_wdata),
        .dmi_rdata(dmi_rdata), .halt_req(halt_req), .ndmreset(ndmreset), .hart_reset_ack(hart_reset_ack),
        .h_iaddr(imem_addr), .h_idata(dm_idata), .h_daddr(in_dbg_d ? dmem_addr : 32'd0), .h_dre(dmem_re & in_dbg_d),
        .h_drdata(dm_drdata), .h_dwe(dmem_we & in_dbg_d), .h_dwstrb(dmem_wstrb), .h_dwdata(dmem_wdata));

    // ---- RAM ----
    wire [17:0] iw = imem_addr[19:2];
    wire [31:0] iw0 = mem[iw], iw1 = mem[iw + 18'd1];
    wire        i_ram = (imem_addr[31:20] == RAM_BASE[31:20]);
    wire [31:0] i_ramd = i_ram ? (imem_addr[1] ? {iw1[15:0], iw0[31:16]} : iw0) : 32'd0;
    wire [31:0] imem_data = in_dbg_i ? dm_idata : i_ramd;
    wire        d_ram = (dmem_addr[31:20] == RAM_BASE[31:20]);
    assign dmem_rdata = in_dbg_d ? dm_drdata : (d_ram ? mem[dmem_addr[19:2]] : 32'd0);
    always @(posedge clk) begin
        if (dmem_we && d_ram) begin
            if (dmem_wstrb[0]) mem[dmem_addr[19:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) mem[dmem_addr[19:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) mem[dmem_addr[19:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mem[dmem_addr[19:2]][31:24] <= dmem_wdata[31:24];
        end
    end
    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin done <= 1'b0; exit_code <= 32'd0; end
        else if (dmem_we && dmem_addr == TOHOST) begin done <= 1'b1; exit_code <= dmem_wdata; end
    end
    // ghi 1 / 0 vao 0x8010_0008: dat / xoa MEIP (chuong trinh tu tao ngat ngoai cho kiem tra ngat + debug)
    reg irq_sw;
    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) irq_sw <= 1'b0;
        else if (dmem_we && dmem_addr == IRQSW) irq_sw <= dmem_wdata[0];
    end
    // boot_halt: yeu cau halt tu luc reset nguon cho toi khi hart vao D-mode lan dau
    reg boot_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) boot_q <= boot_halt;
        else if (dbg_mode) boot_q <= 1'b0;
    end

    rv32im_pipeline #(.RESET_PC(RAM_BASE), .ENABLE_C(ENABLE_C), .MISALIGNED(MISALIGNED)) u_core (
        .clk(clk), .rst_n(core_rst_n), .imem_addr(imem_addr), .imem_data(imem_data), .imem_ready(1'b1),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we), .dmem_re(dmem_re),
        .dmem_fence(dmem_fence), .icache_flush(icache_flush), .dmem_rdata(dmem_rdata), .dmem_ready(1'b1),
        .irq_timer(1'b0), .irq_soft(1'b0), .irq_ext(irq_ext | irq_sw), .dbg_halt_req(halt_req | boot_q), .dbg_mode(dbg_mode));
endmodule
