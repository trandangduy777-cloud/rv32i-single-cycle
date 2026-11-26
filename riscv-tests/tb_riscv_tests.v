`timescale 1ns/1ps
// Testbench chay anh nhi phan cua riscv-tests tren 1 trong 3 loi (chon bang -D khi bien dich):
//   (khong -D)  : rv32i_core (single-cycle)    -DPIPE : rv32i_pipeline    -DPIPE_FULL : rv32im_pipeline
// Anh (hex tu 32 bit moi dong) nap vao CA bo nho lenh va bo nho du lieu (kien truc Harvard cua loi nay),
// moi bo nho 64 KB. Tham so: +img=<file hex>. Ket qua: ghi vao TOHOST (0x00100000), 1 = PASS.
// phan mo rong bit-manip va Zicond (mac dinh tat): -DZBA=1 -DZBB=1 -DZBS=1 -DZBC=1 -DZICOND=1
`ifndef ZBA
`define ZBA 0
`endif
`ifndef ZBB
`define ZBB 0
`endif
`ifndef ZBS
`define ZBS 0
`endif
`ifndef ZBC
`define ZBC 0
`endif
`ifndef ZICOND
`define ZICOND 0
`endif
`ifndef A_EXT
`define A_EXT 0
`endif
`ifndef A_ST_CLR
`define A_ST_CLR 0
`endif
`define ZBPARAMS .ZBA(`ZBA), .ZBB(`ZBB), .ZBS(`ZBS), .ZBC(`ZBC), .ZICOND(`ZICOND), .A_EXT(`A_EXT), .A_ST_CLR(`A_ST_CLR)
module tb_riscv_tests;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata, imem_data;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;

`ifdef PIPE_FULL
    rv32im_pipeline #(`ZBPARAMS) dut (
`elsif PIPE
    rv32i_pipeline dut (
`else
    rv32i_core dut (
`endif
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_rdata(dmem_rdata)
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

    always @(posedge clk) begin
        if (dmem_we && dmem_addr != TOHOST) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[15:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[15:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[15:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[15:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    integer cycles = 0;
    always @(posedge clk) if (rst_n) cycles <= cycles + 1;

    always @(posedge clk) begin
        if (rst_n && dmem_we && dmem_addr == TOHOST) begin
            if (dmem_wdata == 32'd1) $display("RESULT PASS %0d", cycles);
            else                     $display("RESULT FAIL test=%0d", dmem_wdata >> 1);
            $finish;
        end
        if (cycles > 400000) begin
            $display("RESULT TIMEOUT");
            $finish;
        end
    end

    integer i;
    reg [8*256-1:0] imgfile;
    initial begin
        for (i = 0; i < 16384; i = i + 1) begin imem[i] = 32'h00000013; dmem[i] = 32'd0; end
        if (!$value$plusargs("img=%s", imgfile)) begin $display("thieu +img="); $finish; end
        $readmemh(imgfile, imem);
        $readmemh(imgfile, dmem);
        repeat (3) @(posedge clk);
        @(negedge clk);             // nha reset o canh xuong, tranh chay dua voi canh len (quan trong khi mo phong netlist)
        rst_n = 1;
    end
endmodule
