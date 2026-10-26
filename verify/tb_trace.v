`timescale 1ns/1ps
// Testbench in vet: moi lenh hoan tat (retire) in 1 dong cung dinh dang voi rv32i_iss.py
// Tham so dong lenh: +prog=<file hex lenh>  [+dmem=<file hex du lieu ban dau>]
// Ket thuc khi chuong trinh ghi vao dia chi tohost (0x1000)
module tb_trace;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata, imem_data;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;

    rv32i_core dut (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_rdata(dmem_rdata)
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

    reg        rd_w;
    reg [31:0] mask;
    // Lay mau o canh len: luc nay cac tin hieu to hop con la gia tri cua lenh sap thuc thi
    // (cac thanh ghi chi cap nhat sau, qua NBA), nen khong bi dua tin hieu.
    always @(posedge clk) begin
        if (rst_n && dut.retire) begin   // lenh M mat nhieu chu ky: chi in khi lenh hoan tat
            rd_w = dut.rd_we && (dut.rd != 5'd0);
            mask = {{8{dmem_wstrb[3]}}, {8{dmem_wstrb[2]}}, {8{dmem_wstrb[1]}}, {8{dmem_wstrb[0]}}};
            $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%08x strb=%x",
                     imem_addr, imem_data,
                     rd_w ? dut.rd : 5'd0, rd_w ? dut.rd_val : 32'd0,
                     dmem_we, dmem_we ? dmem_addr : 32'd0,
                     dmem_we ? (dmem_wdata & mask) : 32'd0,
                     dmem_we ? dmem_wstrb : 4'd0);
            if (dmem_we && dmem_addr == TOHOST) $finish;
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
