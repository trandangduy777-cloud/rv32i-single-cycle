`timescale 1ns/1ps
// Testbench cho so vet voi Spike: chuong trinh dat o 0x8000_0000 (giong ban do bo nho mac dinh cua Spike),
// loi khoi dong o RESET_PC = 0x8000_0000, bo nho lenh va du lieu dung chung 256 KB (dia chi [17:2]).
// Moi lenh hoan tat in 1 dong:  pc=.. ins=.. rd=.. val=.. st=.. addr=.. data=.. strb=..
// Thanh ghi x1-x31 duoc dat 0 truoc khi chay nhu Spike. Ket thuc khi chuong trinh ghi vao TOHOST (0x8010_0000). Chon loi: -DSC (single-cycle), -DPIPE, -DPIPE_FULL.
// Tham so: +prog=<file hex>
module tb_cosim;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    localparam [31:0] BASE   = 32'h8000_0000;
    localparam [31:0] TOHOST = 32'h8010_0000;

    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata, imem_data;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;

`ifdef PIPE_FULL
    rv32im_pipeline #(.RESET_PC(BASE)) dut (
`elsif PIPE
    rv32i_pipeline #(.RESET_PC(BASE)) dut (
`else
    rv32i_core #(.RESET_PC(BASE)) dut (
`endif
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_rdata(dmem_rdata)
`ifdef PIPE_FULL
        , .irq_timer(1'b0), .irq_soft(1'b0), .irq_ext(1'b0)
`endif
    );

    reg [31:0] mem [0:65535];
    assign imem_data  = mem[imem_addr[17:2]];
    assign dmem_rdata = mem[dmem_addr[17:2]];

    always @(posedge clk) begin
        if (dmem_we && dmem_addr != TOHOST) begin
            if (dmem_addr[31:18] != BASE[31:18]) begin
                $display("ERROR: ghi ngoai vung nho: addr=%08x", dmem_addr); $finish;
            end
            if (dmem_wstrb[0]) mem[dmem_addr[17:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) mem[dmem_addr[17:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) mem[dmem_addr[17:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mem[dmem_addr[17:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    reg        rd_w;
    reg [31:0] mask;
    integer    n = 0;
`ifdef SC
    // single-cycle: lay mau o canh len khi lenh hoan tat (lenh M mat nhieu chu ky)
    always @(posedge clk) begin
        if (rst_n && dut.retire) begin
            rd_w = dut.rd_we && (dut.rd != 5'd0);
            mask = {{8{dmem_wstrb[3]}}, {8{dmem_wstrb[2]}}, {8{dmem_wstrb[1]}}, {8{dmem_wstrb[0]}}};
            $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%08x strb=%x",
                     imem_addr, imem_data, rd_w ? dut.rd : 5'd0, rd_w ? dut.rd_val : 32'd0,
                     dmem_we, dmem_we ? dmem_addr : 32'd0, dmem_we ? (dmem_wdata & mask) : 32'd0,
                     dmem_we ? dmem_wstrb : 4'd0);
            n = n + 1;
            if (dmem_we && dmem_addr == TOHOST) $finish;
        end
    end
`else
    // pipeline: tang WB
    always @(posedge clk) begin
        if (rst_n && dut.memwb_valid) begin
            rd_w = dut.memwb_rd_we && (dut.memwb_rd != 5'd0);
            $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%08x strb=%x",
                     dut.memwb_pc, dut.memwb_instr, rd_w ? dut.memwb_rd : 5'd0, rd_w ? dut.memwb_val : 32'd0,
                     dut.memwb_tst, dut.memwb_taddr, dut.memwb_tdata, dut.memwb_tstrb);
            n = n + 1;
            if (dut.memwb_tst && dut.memwb_taddr == TOHOST) $finish;
        end
    end
`endif

    reg [8*256-1:0] progfile;
    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 32'd0;
        // thanh ghi khong co reset trong RTL; Spike bat dau voi 0, nen dat 0 de vet so sanh duoc
        // (vd. ham luu thanh ghi s0/s1 chua dung len stack)
        for (i = 1; i < 32; i = i + 1) dut.regs[i] = 32'd0;
        if (!$value$plusargs("prog=%s", progfile)) begin $display("ERROR: thieu +prog="); $finish; end
        $readmemh(progfile, mem);
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        #50_000_000;
        $display("TIMEOUT sau %0d lenh", n);
        $finish;
    end
endmodule
