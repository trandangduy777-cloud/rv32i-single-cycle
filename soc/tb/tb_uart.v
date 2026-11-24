`timescale 1ns/1ps
// Test rieng cho soc_uart (khong co CPU): thanh ghi, khung TX o muc bit (do dai tung bit chinh xac), TXDROP, DIV (nho nhat 4, theo byte-lane,
// chot luc bat dau khung), RX (nhieu khung, overrun, loi khung, nhieu bit start, dung sai +-1 chu ky o DIV 32), ngat, vong lap TX -> RX.
module tb_uart;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg         sel = 0, we = 0, re = 0;
    reg  [4:2]  addr = 0;
    reg  [3:0]  wstrb = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    reg         rx_drv = 1'b1, loop = 1'b0;
    wire        tx, irq, irq_rx, irq_tx;
    wire        rx_in = loop ? tx : rx_drv;
    integer errors = 0, cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    soc_uart #(.DEFAULT_DIV(16'd16)) dut (.clk(clk), .rst_n(rst_n), .sel(sel), .addr(addr), .we(we), .re(re), .wstrb(wstrb),
                                          .wdata(wdata), .rdata(rdata), .rx(rx_in), .tx(tx), .irq(irq), .irq_rx(irq_rx), .irq_tx(irq_tx));

    task wr(input [4:2] a, input [31:0] d, input [3:0] s);
        begin @(negedge clk); sel = 1; we = 1; re = 0; addr = a; wdata = d; wstrb = s; @(negedge clk); sel = 0; we = 0; wstrb = 0; end
    endtask
    task rd(input [4:2] a, output [31:0] d);
        begin @(negedge clk); sel = 1; re = 1; we = 0; addr = a; #1 d = rdata; @(negedge clk); sel = 0; re = 0; end
    endtask
    task peek(input [4:2] a, output [31:0] d);                // doc khong co tac dung phu (re = 0)
        begin @(negedge clk); sel = 1; re = 0; we = 0; addr = a; #1 d = rdata; @(negedge clk); sel = 0; end
    endtask
    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin errors = errors + 1; $display("[UART] LOI %0s: %h, mong doi %h (t=%0d)", what, got, want, cyc); end
    endtask

    // ---- giai ma TX o muc bit: bat dau tu canh xuong, kiem tung bit dung bang bc chu ky ----
    task expect_tx(input [7:0] d, input integer bc);
        integer j, t0; reg [7:0] g;
        begin
            @(posedge clk); while (tx !== 1'b0) @(posedge clk);
            t0 = cyc;
            for (j = 0; j < 10; j = j + 1) begin
                // dau bit: muc khong doi trong bc chu ky
                repeat (bc / 2) @(posedge clk);
                if (j == 0 && tx !== 1'b0) begin errors = errors + 1; $display("[UART] LOI start"); end
                if (j >= 1 && j <= 8) g[j-1] = tx;
                if (j == 9 && tx !== 1'b1) begin errors = errors + 1; $display("[UART] LOI stop"); end
                repeat (bc - bc / 2) @(posedge clk);
            end
            // het khung: dung o chu ky t0 + 10 bc (mau ngay sau do): cac bit da lay o giua, nen kiem them bien bit bang so chu ky
            if (cyc - t0 != 10 * bc) begin errors = errors + 1; $display("[UART] LOI do dai khung %0d, mong doi %0d", cyc - t0, 10 * bc); end
            if (g !== d) begin errors = errors + 1; $display("[UART] LOI du lieu TX %h, mong doi %h", g, d); end
        end
    endtask
    // kiem bien bit: moi lan tx doi muc, so chu ky ke tu canh xuong phai chia het bc
    integer tcyc, edge_t0; reg tq = 1'b1, in_f = 1'b0; integer mbc = 16;
    always @(posedge clk) begin
        tq <= tx;
        if (!in_f && tq && !tx) begin in_f = 1; edge_t0 = cyc; end
        else if (in_f) begin
            if (tq != tx && ((cyc - edge_t0) % mbc) != 0) begin errors = errors + 1; $display("[UART] LOI bien bit lech (t=%0d)", cyc); end
            if (cyc - edge_t0 >= 10 * mbc) in_f = 0;
        end
    end

    // ---- gui mot khung vao rx_drv ----
    task send(input [7:0] d, input stop, input integer bc);
        integer j;
        begin
            rx_drv = 0; repeat (bc) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin rx_drv = d[j]; repeat (bc) @(posedge clk); end
            rx_drv = stop; repeat (bc) @(posedge clk);
            rx_drv = 1;
        end
    endtask

    reg [31:0] v; integer n, j, busy_cycles;
    initial begin
        repeat (3) @(posedge clk); #1 rst_n = 1;
        // ---- gia tri reset ----
        peek(3'd2, v); check("status reset", v, 32'h1);
        peek(3'd3, v); check("div reset", v, 16);
        peek(3'd4, v); check("ie reset", v, 0);
        peek(3'd0, v); check("txdata doc", v, 0);
        if (irq !== 1'b0) begin errors = errors + 1; $display("[UART] LOI irq luc reset"); end

        // ---- TX o DIV 16: du lieu, thoi gian, TXREADY ----
        fork
            begin wr(3'd0, 32'hFFFF_FF55, 4'b0001); end
            expect_tx(8'h55, 16);
        join
        peek(3'd2, v); check("ready sau khung", v & 32'h1, 1);
        fork wr(3'd0, 32'h00, 4'b0001); expect_tx(8'h00, 16); join
        fork wr(3'd0, 32'hA3, 4'b0001); expect_tx(8'hA3, 16); join
        fork wr(3'd0, 32'hFF, 4'b0001); expect_tx(8'hFF, 16); join
        // TXREADY thap dung 10*DIV chu ky
        begin : busyblk
            @(negedge clk); sel = 1; we = 1; addr = 0; wdata = 8'h0F; wstrb = 4'b0001;
            @(negedge clk); sel = 0; we = 0; wstrb = 0;
            busy_cycles = 0;
            while (!dut.tx_ready) begin @(negedge clk); busy_cycles = busy_cycles + 1; end
            check("busy 10 DIV", busy_cycles, 160);
        end
        // ghi TXDATA voi wstrb[0] = 0 khong gui
        wr(3'd0, 32'h0000_0100, 4'b0010); repeat (4) @(posedge clk);
        peek(3'd2, v); check("wstrb khong chua byte 0", v & 32'h1, 1);
        // sel = 0 khong gui
        @(negedge clk); sel = 0; we = 1; addr = 0; wdata = 8'h11; wstrb = 4'b1111; @(negedge clk); we = 0;
        repeat (4) @(posedge clk); peek(3'd2, v); check("khong sel khong gui", v & 32'h1, 1);

        // ---- TXDROP ----
        wr(3'd0, 32'h41, 4'b0001);
        wr(3'd0, 32'h42, 4'b0001);                                  // bi bo
        peek(3'd2, v); check("txdrop dat", v & 32'h10, 32'h10);
        repeat (170) @(posedge clk);
        peek(3'd2, v); check("khung 41 xong, khong gui 42", v & 32'h1, 1);
        wr(3'd2, 32'h10, 4'b0001); peek(3'd2, v); check("txdrop xoa W1C", v & 32'h10, 0);
        wr(3'd2, 32'h00, 4'b0001);
        // wstrb[0] = 0 khong xoa
        wr(3'd0, 32'h41, 4'b0001); wr(3'd0, 32'h42, 4'b0001); wr(3'd2, 32'h10, 4'b0010);
        peek(3'd2, v); check("txdrop khong xoa khi wstrb[0] = 0", v & 32'h10, 32'h10);
        repeat (170) @(posedge clk); wr(3'd2, 32'h10, 4'b0001);

        // ---- DIV: nho nhat 4, byte-lane, chot luc bat dau khung ----
        wr(3'd3, 32'd2, 4'b0011); peek(3'd3, v); check("div nho nhat", v, 4);
        wr(3'd3, 32'd0, 4'b0011); peek(3'd3, v); check("div 0 -> 4", v, 4);
        wr(3'd3, 32'd3, 4'b0011); peek(3'd3, v); check("div 3 -> 4", v, 4);
        wr(3'd3, 32'd4, 4'b0011); peek(3'd3, v); check("div 4", v, 4);
        wr(3'd3, 32'h0000_0024, 4'b0001); peek(3'd3, v); check("div byte0", v, 32'h24);
        wr(3'd3, 32'h0000_0100, 4'b0010); peek(3'd3, v); check("div byte1", v, 32'h124);
        wr(3'd3, 32'hFFFF_0000, 4'b1100); peek(3'd3, v); check("div byte 2-3 khong doi", v, 32'h124);
        wr(3'd3, 32'h0000_BEEF, 4'b0000); peek(3'd3, v); check("div wstrb 0", v, 32'h124);
        wr(3'd3, 32'd5, 4'b0011); mbc = 5; fork wr(3'd0, 8'h5A, 4'b0001); expect_tx(8'h5A, 5); join
        wr(3'd3, 32'd4, 4'b0011); mbc = 4; fork wr(3'd0, 8'hC3, 4'b0001); expect_tx(8'hC3, 4); join
        wr(3'd3, 32'd33, 4'b0011); mbc = 33; fork wr(3'd0, 8'h96, 4'b0001); expect_tx(8'h96, 33); join
        // doi DIV khi dang gui: khung dang gui giu DIV cu
        wr(3'd3, 32'd20, 4'b0011); mbc = 20;
        fork begin wr(3'd0, 8'hE1, 4'b0001); repeat (30) @(posedge clk); wr(3'd3, 32'd7, 4'b0011); end expect_tx(8'hE1, 20); join
        wr(3'd3, 32'd16, 4'b0011); mbc = 16; repeat (4) @(posedge clk);

        // ---- RX: 3 byte, doc, pop ----
        send(8'h00, 1, 16); peek(3'd2, v); check("rx00 valid", v & 32'h1F, 32'h3);   // rx_valid | tx_ready
        rd(3'd1, v); check("rx00 data", v, 0);
        peek(3'd2, v); check("pop xoa valid", v & 32'h2, 0);
        send(8'hFF, 1, 16); rd(3'd1, v); check("rxFF", v, 32'hFF);
        peek(3'd2, v); check("pop xoa valid (FF)", v & 32'h2, 0);
        peek(3'd1, v); check("du lieu giu lai sau pop", v, 32'hFF);
        wr(3'd1, 32'h0, 4'b1111); send(8'h81, 1, 16); wr(3'd1, 32'hFFFF_FFFF, 4'b1111);
        peek(3'd2, v); check("ghi RXDATA khong pop va khong doi du lieu", v & 32'h2, 32'h2);
        rd(3'd1, v); check("rx81 sau ghi RXDATA", v, 32'h81);
        send(8'h5A, 1, 16); peek(3'd1, v); check("peek khong pop", v, 32'h5A);
        peek(3'd2, v); check("peek khong pop valid", v & 32'h2, 32'h2);
        rd(3'd1, v); check("rx5A", v, 32'h5A);
        peek(3'd2, v); check("khong co co sticky", v & 32'h1C, 0);

        // ---- overrun: 2 khung lien tiep, khong doc ----
        send(8'h11, 1, 16); send(8'h22, 1, 16);
        peek(3'd2, v); check("overrun co", v & 32'h6, 32'h6);
        rd(3'd1, v); check("overrun giu byte dau", v, 32'h11);
        wr(3'd2, 32'h18, 4'b0001); peek(3'd2, v); check("W1C bit khac khong xoa overrun", v & 32'h4, 32'h4);
        wr(3'd2, 32'h04, 4'b0001); peek(3'd2, v); check("overrun W1C", v & 32'h4, 0);
        // byte moi dung luc doc: khong coi la overrun
        // (doc xong roi nhan tiep binh thuong)
        send(8'h33, 1, 16); peek(3'd2, v); check("khong overrun sau doc", v & 32'hC, 0); rd(3'd1, v); check("rx33", v, 32'h33);

        // ---- loi khung ----
        send(8'hA7, 0, 16); peek(3'd2, v); check("ferr", v & 32'h8, 32'h8);
        wr(3'd2, 32'h14, 4'b0001); peek(3'd2, v); check("W1C bit khac khong xoa ferr", v & 32'h8, 32'h8);
        rd(3'd1, v); check("byte loi khung van giao", v, 32'hA7);
        wr(3'd2, 32'h08, 4'b0001); peek(3'd2, v); check("ferr W1C", v & 32'h8, 0);
        // sau loi khung (duong con thap o cuoi), khung ke tiep nhan duoc
        send(8'h3C, 1, 16); rd(3'd1, v); check("sau ferr", v, 32'h3C);

        // ---- break: duong thap rat lau -> dung 1 byte (0x00 + ferr), khong sinh them byte, khong overrun ----
        rx_drv = 0; repeat (16 * 40) @(posedge clk); rx_drv = 1; repeat (16 * 12) @(posedge clk);
        peek(3'd2, v); check("break: 1 byte co ferr, khong overrun", v & 32'h1E, 32'hA);
        rd(3'd1, v); check("break: byte 0", v, 0);
        repeat (16 * 12) @(posedge clk); peek(3'd2, v); check("break: khong co byte thu hai", v & 32'h2, 0);
        wr(3'd2, 32'h08, 4'b0001);
        // W1C TXDROP khong xoa bang bit khac
        wr(3'd0, 32'h41, 4'b0001); wr(3'd0, 32'h42, 4'b0001); wr(3'd2, 32'h0C, 4'b0001);
        peek(3'd2, v); check("W1C bit khac khong xoa txdrop", v & 32'h10, 32'h10);
        repeat (170) @(posedge clk); wr(3'd2, 32'h10, 4'b0001);

        // ---- nhieu bit start (thap < nua bit): khong thanh byte ----
        rx_drv = 0; repeat (5) @(posedge clk); rx_drv = 1; repeat (200) @(posedge clk);
        peek(3'd2, v); check("nhieu khong tao byte", v & 32'h1E, 0);

        // ---- dung sai +-1 chu ky o DIV 32 ----
        wr(3'd3, 32'd32, 4'b0011);
        send(8'hB6, 1, 33); repeat (40) @(posedge clk); rd(3'd1, v); check("dung sai +1", v, 32'hB6);
        send(8'h49, 1, 31); repeat (40) @(posedge clk); rd(3'd1, v); check("dung sai -1", v, 32'h49);
        send(8'h6D, 1, 32); repeat (40) @(posedge clk); rd(3'd1, v); check("danh nghia", v, 32'h6D);
        peek(3'd2, v); check("khong co sticky o dung sai", v & 32'h1C, 0);
        wr(3'd3, 32'd16, 4'b0011);

        // ---- ngat ----
        wr(3'd4, 32'h1, 4'b0001); check("irq rx khi chua co", irq, 0);
        send(8'h77, 1, 16); check("irq rx", irq, 1); check("irq_rx = rx", irq_rx, 1); check("irq_tx = 0 khi IE[1] = 0", irq_tx, 0);
        rd(3'd1, v); check("irq rx het", irq, 0);
        wr(3'd4, 32'h2, 4'b0001); check("irq tx khi san sang", irq, 1); check("irq_tx = tx", irq_tx, 1); check("irq_rx = 0 khi IE[0] = 0", irq_rx, 0);
        wr(3'd0, 32'h31, 4'b0001); @(posedge clk); #1 check("irq tx khi ban", irq, 0);
        repeat (170) @(posedge clk); check("irq tx lai", irq, 1);
        wr(3'd4, 32'h0, 4'b0001); check("irq tat", irq, 0);
        wr(3'd4, 32'hFFFF_FFFC, 4'b1111); peek(3'd4, v); check("ie chi 2 bit", v, 0);
        wr(3'd4, 32'h3, 4'b0001); peek(3'd4, v); check("ie 3", v, 3);
        send(8'h01, 1, 16); check("irq ca hai", irq, 1); rd(3'd1, v); wr(3'd4, 32'h0, 4'b0001);

        // ---- vong lap TX -> RX, 256 gia tri ----
        loop = 1; mbc = 16; repeat (20) @(posedge clk);
        n = 0;
        for (j = 0; j < 256; j = j + 1) begin
            wr(3'd0, j, 4'b0001);
            peek(3'd2, v);
            while (!(v & 32'h2)) peek(3'd2, v);
            rd(3'd1, v); if (v !== j) begin n = n + 1; end
            while (!dut.tx_ready) @(posedge clk);
        end
        check("vong lap loi", n, 0);
        peek(3'd2, v); check("vong lap khong co co loi", v & 32'h1C, 0);
        loop = 0;

        if (errors == 0) $display("[UART] PASS"); else $display("[UART] FAIL %0d loi", errors);
        $finish;
    end
    initial begin #50_000_000; $display("[UART] FAIL het gio"); $finish; end
endmodule
