`timescale 1ns/1ps
// Testbench in vet cho pipeline: moi lenh o tang WB in 1 dong cung dinh dang voi rv32i_iss.py
// Tham so dong lenh: +prog=<file hex lenh>  [+dmem=<file hex du lieu ban dau>]
// Ket thuc khi chuong trinh ghi vao dia chi tohost (0x1000)
module tb_trace_pipe;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata, imem_data;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;

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

    reg [31:0] imem [0:1023];
    reg [31:0] dmem [0:1023];
    assign imem_data  = imem[imem_addr[11:2]];
    assign dmem_rdata = dmem[dmem_addr[11:2]];

    localparam TOHOST = 32'h0000_1000;

    always @(posedge clk) begin
        if (dmem_we && dmem_addr != TOHOST) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[11:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[11:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[11:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[11:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    reg rd_w;
    // Tang commit (WB): in 1 dong cho moi lenh hoan tat, cung dinh dang voi ISS.
    // Lay mau o canh len: luc nay cac thanh ghi pipeline chua cap nhat (NBA), nen doc dung lenh dang o WB.
    always @(posedge clk) begin
        if (rst_n && dut.memwb_valid) begin
            rd_w = dut.memwb_rd_we && (dut.memwb_rd != 5'd0);
            $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%08x strb=%x",
                     dut.memwb_pc, dut.memwb_instr,
                     rd_w ? dut.memwb_rd : 5'd0, rd_w ? dut.memwb_val : 32'd0,
                     dut.memwb_tst, dut.memwb_taddr, dut.memwb_tdata, dut.memwb_tstrb);
            if (dut.memwb_tst && dut.memwb_taddr == TOHOST) $finish;
        end
    end

    reg [8*256-1:0] progfile, dmemfile;
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) begin imem[i] = 32'h00000013; dmem[i] = 32'd0; end
        if (!$value$plusargs("prog=%s", progfile)) progfile = "prog.hex";
        $readmemh(progfile, imem);
        if ($value$plusargs("dmem=%s", dmemfile)) $readmemh(dmemfile, dmem);
        repeat (3) @(posedge clk);
        @(negedge clk);          // nha reset o canh xuong de khong dua voi canh len
        rst_n = 1;
        #200000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
