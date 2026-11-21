`timescale 1ns/1ps
// Do hieu nang: chay bench.hex tren 1 loi, in so chu ky, so lenh hoan tat va CPI.
//   (khong -D): rv32i_core (CPI = 1 voi RV32I, lon hon 1 khi co lenh M)   -DPIPE: rv32i_pipeline   -DPIPE_FULL: rv32im_pipeline
module tb_bench;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata, imem_data;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;
`ifdef PIPE_FULL
    rv32im_pipeline dut (
`elsif PIPE
    rv32i_pipeline dut (
`else
    rv32i_core dut (
`endif
        .clk(clk), .rst_n(rst_n), .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
        .dmem_we(dmem_we), .dmem_rdata(dmem_rdata)
`ifdef PIPE_FULL
`ifndef NO_IRQ_PORTS
        , .irq_timer(1'b0), .irq_soft(1'b0), .irq_ext(1'b0)     // ngat duoc kiem tra rieng trong tb_irq.v
        , .imem_ready(1'b1), .dmem_ready(1'b1), .dmem_re()      // bo nho to hop; cache kiem tra trong cosim
`endif
`endif
    );

    localparam TOHOST = 32'h0010_0000;
    reg [31:0] imem [0:16383];
    reg [31:0] dmem [0:16383];
    assign imem_data  = imem[imem_addr[15:2]];
    assign dmem_rdata = dmem[dmem_addr[15:2]];
    always @(posedge clk)
        if (dmem_we && dmem_addr != TOHOST) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[15:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[15:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[15:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[15:2]][31:24] <= dmem_wdata[31:24];
        end

    integer cycles = 0, instret = 0, i;
    always @(posedge clk) if (rst_n) begin
        cycles <= cycles + 1;
`ifdef PIPE_FULL
        if (dut.memwb_valid) instret <= instret + 1;
`elsif PIPE
        if (dut.memwb_valid) instret <= instret + 1;
`else
        if (dut.retire) instret <= instret + 1;   // lenh M dung lai nhieu chu ky, nen khong dem moi chu ky
`endif
        if (dmem_we && dmem_addr == TOHOST) begin
            $display("BENCH cycles=%0d instret=%0d CPI=%0d.%03d", cycles, instret,
                     cycles / instret, ((cycles * 1000) / instret) % 1000);
            $display("CHECK %08x %08x %08x %08x %08x", dmem[512], dmem[513], dmem[514], dmem[515], dmem[516]);
            $finish;
        end
        if (cycles > 3000000) begin $display("TIMEOUT"); $finish; end
    end
    reg [8*256-1:0] img;
    initial begin
        for (i = 0; i < 16384; i = i + 1) begin imem[i] = 32'h13; dmem[i] = 0; end
        if (!$value$plusargs("img=%s", img)) begin $display("thieu +img="); $finish; end
        $readmemh(img, imem); $readmemh(img, dmem);
        repeat (3) @(posedge clk); @(negedge clk); rst_n = 1;   // nha reset o canh xuong, tranh chay dua
    end
endmodule
