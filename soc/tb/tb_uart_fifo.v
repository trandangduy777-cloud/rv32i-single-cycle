`timescale 1ns/1ps
// Test FIFO nhan cua soc_uart (RX_DEPTH = 4): thu tu, so byte trong STATUS[11:8], day -> RXOVR va bo byte moi, doc dung luc byte moi toi
// khi day, tran con tro (nhieu vong), ngat khi khong rong, doc FIFO rong khong lam lech con tro, loi khung vao FIFO.
module tb_uart_fifo;
    localparam D = 4;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg sel = 0, we = 0, re = 0; reg [4:2] addr = 0; reg [3:0] wstrb = 0; reg [31:0] wdata = 0;
    wire [31:0] rdata; reg rx_drv = 1'b1; wire tx, irq;
    integer errors = 0;
    soc_uart #(.DEFAULT_DIV(16'd8), .RX_DEPTH(D)) dut (.clk(clk), .rst_n(rst_n), .sel(sel), .addr(addr), .we(we), .re(re), .wstrb(wstrb),
                                                       .wdata(wdata), .rdata(rdata), .rx(rx_drv), .tx(tx), .irq(irq));
    task wr(input [4:2] a, input [31:0] d, input [3:0] s);
        begin @(negedge clk); sel = 1; we = 1; re = 0; addr = a; wdata = d; wstrb = s; @(negedge clk); sel = 0; we = 0; wstrb = 0; end
    endtask
    task rd(input [4:2] a, output [31:0] d);
        begin @(negedge clk); sel = 1; re = 1; we = 0; addr = a; #1 d = rdata; @(negedge clk); sel = 0; re = 0; end
    endtask
    task peek(input [4:2] a, output [31:0] d);
        begin @(negedge clk); sel = 1; re = 0; we = 0; addr = a; #1 d = rdata; @(negedge clk); sel = 0; end
    endtask
    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin errors = errors + 1; $display("[UART_FIFO] LOI %0s: %h, mong doi %h", what, got, want); end
    endtask
    task send(input [7:0] d, input stop);
        integer j;
        begin
            rx_drv = 0; repeat (8) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin rx_drv = d[j]; repeat (8) @(posedge clk); end
            rx_drv = stop; repeat (8) @(posedge clk); rx_drv = 1; repeat (2) @(posedge clk);
        end
    endtask
    reg [31:0] v; integer i;
    initial begin
        repeat (3) @(posedge clk); #1 rst_n = 1;
        peek(3'd2, v); check("status reset: count = 0", v, 32'h1);
        wr(3'd4, 32'h1, 4'b0001); check("irq khi rong", irq, 0);
        send(8'hA1, 1); peek(3'd2, v); check("1 byte: count = 1, RXVALID", v & 32'hF03, 32'h103);
        check("irq khi khong rong", irq, 1);
        send(8'hA2, 1); send(8'hA3, 1); send(8'hA4, 1);
        peek(3'd2, v); check("day: count = 4", v & 32'hF07, 32'h403 | 32'h0);
        // FIFO day, byte moi bi bo + RXOVR, noi dung cu khong doi
        send(8'hEE, 1);
        peek(3'd2, v); check("tran: RXOVR, van 4 byte", v & 32'hF07, 32'h407);
        rd(3'd1, v); check("pop 1", v & 32'hFF, 32'hA1);
        peek(3'd2, v); check("sau pop: count = 3", (v >> 8) & 15, 3);
        rd(3'd1, v); check("pop 2", v & 32'hFF, 32'hA2);
        rd(3'd1, v); check("pop 3", v & 32'hFF, 32'hA3);
        rd(3'd1, v); check("pop 4", v & 32'hFF, 32'hA4);
        peek(3'd2, v); check("rong: count = 0, RXVALID = 0, RXOVR con (sticky)", v & 32'hF07, 32'h005);
        check("irq tat khi rong", irq, 0);
        // doc khi rong khong lam lech con tro
        rd(3'd1, v); rd(3'd1, v); peek(3'd2, v); check("doc rong: count van 0", (v >> 8) & 15, 0);
        wr(3'd2, 32'h04, 4'b0001);
        send(8'h5A, 1); rd(3'd1, v); check("sau doc rong, byte ke tiep dung", v & 32'hFF, 32'h5A);
        // nhieu vong con tro: gui 2 byte, doc 2 byte, lap 13 lan (13 x 2 = 26 byte qua FIFO 4 muc, nhieu vong)
        for (i = 0; i < 13; i = i + 1) begin
            send(8'h10 + i, 1); send(8'h80 + i, 1);
            rd(3'd1, v); check("vong a", v & 32'hFF, 8'h10 + i);
            rd(3'd1, v); check("vong b", v & 32'hFF, 8'h80 + i);
        end
        peek(3'd2, v); check("het vong: rong", (v >> 8) & 15, 0);
        // FIFO day roi mot khung moi toi dung chu ky lay mau bit stop cung luc voi mot lenh doc: khong tran, byte moi vao
        wr(3'd2, 32'h04, 4'b0001);
        send(8'h01, 1); send(8'h02, 1); send(8'h03, 1); send(8'h04, 1);
        rx_drv = 0; repeat (8) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin rx_drv = 8'h05 >> i; repeat (8) @(posedge clk); end
        rx_drv = 1;                                                 // bit stop: cho toi chu ky lay mau, doc dung chu ky do
        while (!(dut.rst_ == 3'd3 && dut.rc == 16'd0)) @(negedge clk);
        sel = 1; re = 1; we = 0; addr = 3'd1; #1 v = rdata; @(negedge clk); sel = 0; re = 0;
        check("pop cung chu ky nhan: byte dau", v & 32'hFF, 1);
        repeat (8) @(posedge clk);
        peek(3'd2, v); check("pop cung chu ky nhan: day lai, khong RXOVR", v & 32'hF07, 32'h403);
        rd(3'd1, v); check("p2", v & 32'hFF, 2); rd(3'd1, v); check("p3", v & 32'hFF, 3);
        rd(3'd1, v); check("p4", v & 32'hFF, 4); rd(3'd1, v); check("p5 (byte toi cung luc doc)", v & 32'hFF, 5);
        // loi khung: byte van vao FIFO kem RXFERR, khong them byte
        send(8'h77, 0); repeat (30) @(posedge clk);
        peek(3'd2, v); check("ferr: 1 byte + RXFERR", v & 32'hF0B, 32'h10B);
        rd(3'd1, v); check("ferr: du lieu", v & 32'hFF, 32'h77);
        if (errors == 0) $display("[UART_FIFO] PASS"); else $display("[UART_FIFO] FAIL %0d loi", errors);
        $finish;
    end
    initial begin #20_000_000; $display("[UART_FIFO] FAIL het gio"); $finish; end
endmodule
