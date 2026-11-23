`timescale 1ns/1ps
// Test rieng cho rv32_mtimer voi PRESCALE khac 1 (3 va 8, cung mot clock): mtime tang dung moi PRESCALE chu ky, khong lech pha khi ghi mtime,
// carry len 32 bit cao, irq dung chu ky (mtime >= mtimecmp), ghi theo byte-lane. SoC chi dung PRESCALE = 1 nen khoi nay duoc kiem rieng.
module tb_mtimer;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg sel = 0, we = 0; reg [4:2] addr = 0; reg [3:0] wstrb = 0; reg [31:0] wdata = 0;
    wire [31:0] rd3, rd8; wire irq3, irq8, ms3, ms8;
    integer errors = 0;
    rv32_mtimer #(.PRESCALE(3)) d3 (.clk(clk), .rst_n(rst_n), .sel(sel), .addr(addr), .we(we), .wstrb(wstrb), .wdata(wdata), .rdata(rd3), .irq(irq3), .msip(ms3));
    rv32_mtimer #(.PRESCALE(8)) d8 (.clk(clk), .rst_n(rst_n), .sel(sel), .addr(addr), .we(we), .wstrb(wstrb), .wdata(wdata), .rdata(rd8), .irq(irq8), .msip(ms8));
    task wr(input [4:2] a, input [31:0] d, input [3:0] s);
        begin @(negedge clk); sel = 1; we = 1; addr = a; wdata = d; wstrb = s; @(negedge clk); sel = 0; we = 0; wstrb = 0; end
    endtask
    task check(input [255:0] what, input [63:0] got, input [63:0] want);
        if (got !== want) begin errors = errors + 1; $display("[MTIMER] LOI %0s: %0d, mong doi %0d (chu ky %0d)", what, got, want, t); end
    endtask
    // mo hinh: t = so canh clock da qua ke tu luc nha reset; mtime tang o canh co (t % P) == P - 1
    integer t = 0; reg [63:0] m3, m8;
    always @(posedge clk) if (rst_n) begin
        if ((t % 3) == 2) m3 = m3 + 1;
        if ((t % 8) == 7) m8 = m8 + 1;
        t = t + 1;
    end
    // ghi mtime tu bus thay doi gia tri nhung khong doi pha: mo hinh ghi theo cung thoi diem
    reg [63:0] p3 = 0, p8 = 0; reg wedge = 0, started = 0; integer tt;
    always @(posedge clk) wedge <= sel & we;
    always @(negedge clk) begin
        if (rst_n && started && !wedge) begin
            tt = t - 1;                                           // chi so canh vua qua
            check("tang mtime /3", d3.mtime - p3, ((tt % 3) == 2) ? 1 : 0);
            check("tang mtime /8", d8.mtime - p8, ((tt % 8) == 7) ? 1 : 0);
        end
        if (rst_n) started <= 1;
        p3 <= d3.mtime; p8 <= d8.mtime;
    end
    task rd64(output [63:0] a3, output [63:0] a8);
        begin
            @(negedge clk); sel = 1; we = 0; addr = 3'd0; #1; a3[31:0] = rd3; a8[31:0] = rd8;
            addr = 3'd1; #1; a3[63:32] = rd3; a8[63:32] = rd8; @(negedge clk); sel = 0;
        end
    endtask
    integer i; reg [63:0] x3, x8;
    initial begin
        m3 = 0; m8 = 0;
        repeat (3) @(posedge clk); #1 rst_n = 1;
        // dem tu do: moi chu ky so sanh mtime voi mo hinh (doc sau canh clock, truoc canh ke)
        for (i = 0; i < 400; i = i + 1) begin
            @(negedge clk);
            check("mtime/3", d3.mtime, m3); check("mtime/8", d8.mtime, m8);
        end
        // mtimecmp khoi dong khong ngat; dat cmp = mtime + 5 tick: irq len dung luc mtime >= cmp
        check("irq khoi dong /3", irq3, 0); check("irq khoi dong /8", irq8, 0);
        @(negedge clk); x3 = d3.mtime + 5; x8 = d8.mtime + 5;
        // ghi mtimecmp (hai khoi chung bus: ghi cung gia tri, nen dat theo khoi /3 va kiem rieng khoi /8 qua gia tri tuyet doi)
        wr(3'd3, 32'h0, 4'b1111); wr(3'd2, x3[31:0], 4'b1111);
        for (i = 0; i < 40; i = i + 1) begin
            @(negedge clk);
            check("irq/3 = (mtime >= cmp)", irq3, (d3.mtime >= x3)); check("irq/8 = (mtime >= cmp)", irq8, (d8.mtime >= x3));
        end
        // ghi mtime giua pha: pha khong bi dat lai; bo theo doi lien tuc (khoi mon) kiem moi chu ky khong co ghi: tang dung 1 tai canh t % P == P - 1
        wr(3'd1, 32'h0, 4'b1111); wr(3'd0, 32'd1000, 4'b1111);
        repeat (100) @(negedge clk);
        check("mtime sau ghi lon hon 1000 /3", d3.mtime > 1000, 1); check("mtime sau ghi lon hon 1000 /8", d8.mtime > 1000, 1);
        // carry sang 32 bit cao
        wr(3'd1, 32'h0, 4'b1111); wr(3'd0, 32'hFFFF_FFFE, 4'b1111);
        repeat (64) @(negedge clk);
        check("mtime cao da tang /3", d3.mtime[63:32] != 0, 1); check("mtime cao da tang /8", d8.mtime[63:32] != 0, 1);
        // ghi theo byte: chi byte 1 cua mtimecmp
        wr(3'd3, 32'hFFFF_FFFF, 4'b1111); wr(3'd2, 32'h0, 4'b1111); wr(3'd2, 32'h0000_AB00, 4'b0010);
        check("cmp byte 1 /3", d3.mtimecmp[31:0], 32'h0000_AB00); check("cmp byte 1 /8", d8.mtimecmp[31:0], 32'h0000_AB00);
        if (errors == 0) $display("[MTIMER] PASS"); else $display("[MTIMER] FAIL %0d loi", errors);
        $finish;
    end
    initial begin #2_000_000; $display("[MTIMER] FAIL het gio"); $finish; end
endmodule
