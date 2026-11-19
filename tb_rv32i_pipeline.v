`timescale 1ns/1ps
// Testbench pipeline: nap chuong trinh (mac dinh prog_base.hex, doi bang +prog=<file>) vao bo nho lenh, chay pipeline, cho chuong trinh ghi ket qua vao dia chi tohost.
// tohost = 0x1000: ghi 1 = PASS, ghi (0x400 | so test) = FAIL
module tb_rv32i_pipeline;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;          // 100 MHz

    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;
    wire [31:0] imem_data;

`ifdef PIPE_FULL
    rv32im_pipeline dut (            // RV32IM + CSR + trap
`else
    rv32i_pipeline dut (             // RV32I thuan
`endif
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_rdata(dmem_rdata)
`ifdef PIPE_FULL
`ifndef NO_IRQ_PORTS
        , .irq_timer(1'b0), .irq_ext(1'b0)     // ngat duoc kiem tra rieng trong tb_irq.v
`endif
`endif
    );

    // ---- bo nho lenh 4 KB ----
    reg [31:0] imem [0:1023];
    assign imem_data = imem[imem_addr[11:2]];

    // ---- bo nho du lieu 4 KB ----
    reg [31:0] dmem [0:1023];
    assign dmem_rdata = dmem[dmem_addr[11:2]];

    localparam TOHOST = 32'h0000_1000;

    integer i;
    reg [8*256-1:0] progfile;
    always @(posedge clk) begin
        if (dmem_we && dmem_addr != TOHOST) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[11:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[11:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[11:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[11:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    integer cycles = 0;
    always @(posedge clk) if (rst_n) cycles <= cycles + 1;

    // ---- bat ket qua ----
    always @(posedge clk) begin
        if (rst_n && dmem_we && dmem_addr == TOHOST) begin
            if (dmem_wdata == 32'd1) begin
                $display("[TB] PASS sau %0d chu ky. fib(10) luu o 0x300 = %0d", cycles, dmem[32'h300 >> 2]);
            end else begin
                $display("[TB] FAIL: test so %0d (tohost = 0x%08x)", dmem_wdata & 32'h3FF, dmem_wdata);
            end
            $finish;
        end
    end

    initial begin
        for (i = 0; i < 1024; i = i + 1) begin imem[i] = 32'h00000013; dmem[i] = 32'd0; end   // NOP
        if (!$value$plusargs("prog=%s", progfile)) progfile = "prog_base.hex";
        $readmemh(progfile, imem);
`ifndef NO_VCD
        $dumpfile("rv32i_pipeline.vcd");
        $dumpvars(0, tb_rv32i_pipeline);
`endif
        repeat (3) @(posedge clk);
        @(negedge clk);             // nha reset o canh xuong: tranh chay dua voi canh len, netlist sau P&R moi cho cung so chu ky voi RTL
        rst_n = 1;
        #200000;
        $display("[TB] TIMEOUT");
        $finish;
    end
endmodule
