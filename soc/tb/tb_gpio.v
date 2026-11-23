`timescale 1ns/1ps
// Test rieng cho soc_gpio: OUT/DIR/IE/EDGE theo byte-lane, SET/CLR/TGL, dong bo 2 flip-flop (tre dung 2 chu ky), canh len / xuong, W1C,
// su kien moi thang W1C cung chu ky, che ngat theo IE, irq; so voi mo hinh tham chieu cap chu ky khi kich thich ngau nhien.
module tb_gpio;
    localparam N = 16;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg sel = 0, we = 0; reg [5:2] addr = 0; reg [3:0] wstrb = 0; reg [31:0] wdata = 0;
    wire [31:0] rdata; reg [N-1:0] pin = 0; wire [N-1:0] gout, goe; wire irq;
    integer errors = 0;
    soc_gpio #(.N(N)) dut (.clk(clk), .rst_n(rst_n), .sel(sel), .addr(addr), .we(we), .wstrb(wstrb), .wdata(wdata), .rdata(rdata),
                           .gpio_in(pin), .gpio_out(gout), .gpio_oe(goe), .irq(irq));

    task wr(input [5:2] a, input [31:0] d, input [3:0] s);
        begin @(negedge clk); sel = 1; we = 1; addr = a; wdata = d; wstrb = s; @(negedge clk); sel = 0; we = 0; wstrb = 0; end
    endtask
    task peek(input [5:2] a, output [31:0] d);
        begin @(negedge clk); sel = 1; we = 0; addr = a; #1 d = rdata; @(negedge clk); sel = 0; end
    endtask
    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin errors = errors + 1; $display("[GPIO] LOI %0s: %h, mong doi %h", what, got, want); end
    endtask

    // ---- mo hinh tham chieu cap chu ky cho kich thich ngau nhien ----
    reg [N-1:0] m_out, m_dir, m_ie, m_pend, m_edge, m_s1, m_s2, m_q;
    reg         m_en = 0;
    wire [N-1:0] m_ev = (m_s2 & ~m_q & ~m_edge) | (~m_s2 & m_q & m_edge);
    wire [N-1:0] wm = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};
    always @(posedge clk) if (m_en) begin
        m_s1 <= pin; m_s2 <= m_s1; m_q <= m_s2;
        if (sel & we) case (addr)
            4'd0: m_out  <= (m_out & ~wm) | (wdata[N-1:0] & wm);
            4'd2: m_dir  <= (m_dir & ~wm) | (wdata[N-1:0] & wm);
            4'd3: m_ie   <= (m_ie & ~wm) | (wdata[N-1:0] & wm);
            4'd5: m_edge <= (m_edge & ~wm) | (wdata[N-1:0] & wm);
            4'd6: m_out  <= m_out | (wdata[N-1:0] & wm);
            4'd7: m_out  <= m_out & ~(wdata[N-1:0] & wm);
            4'd8: m_out  <= m_out ^ (wdata[N-1:0] & wm);
            default: ;
        endcase
        m_pend <= (m_pend & ~((sel & we & addr == 4'd4) ? (wdata[N-1:0] & wm) : {N{1'b0}})) | m_ev;
    end
    always @(negedge clk) if (m_en && rst_n) begin
        if (gout !== m_out || goe !== m_dir) begin errors = errors + 1; $display("[GPIO] LOI mo hinh out/oe"); end
        if (irq !== (|(m_pend & m_ie))) begin errors = errors + 1; $display("[GPIO] LOI mo hinh irq"); end
        if (dut.pend_r !== m_pend) begin errors = errors + 1; $display("[GPIO] LOI mo hinh pend %h %h", dut.pend_r, m_pend); end
    end

    reg [31:0] v; integer j; reg [31:0] seed;
    initial begin
        repeat (3) @(posedge clk); #1 rst_n = 1;
        peek(4'd0, v); check("out reset", v, 0);
        peek(4'd2, v); check("dir reset", v, 0);
        peek(4'd3, v); check("ie reset", v, 0);
        peek(4'd5, v); check("edge reset", v, 0);
        check("oe reset", goe, 0);

        // ---- OUT, DIR, byte-lane ----
        wr(4'd0, 32'hFFFF_1234, 4'b1111); peek(4'd0, v); check("out ghi 16 bit", v, 32'h1234);
        wr(4'd0, 32'h0000_AB00, 4'b0010); peek(4'd0, v); check("out byte 1", v, 32'hAB34);
        wr(4'd0, 32'h0000_00CD, 4'b0001); peek(4'd0, v); check("out byte 0", v, 32'hABCD);
        wr(4'd0, 32'h0000_0000, 4'b0100); peek(4'd0, v); check("out byte 2 khong anh huong", v, 32'hABCD);
        check("gpio_out", gout, 16'hABCD);
        wr(4'd2, 32'h0000_00F0, 4'b0011); peek(4'd2, v); check("dir", v, 32'hF0); check("gpio_oe", goe, 16'h00F0);
        // doc IN: pad = ben ngoai (dai tre 2 chu ky)
        pin = 16'h0F0F; @(negedge clk); peek(4'd1, v); check("in sau 2 chu ky", v, 32'h0F0F);
        pin = 16'hFFFF; @(posedge clk); #1; peek(4'd1, v); check("in khong som hon 2 chu ky", v, 32'h0F0F);
        peek(4'd1, v); check("in sau them", v, 32'hFFFF);

        // ---- SET / CLR / TGL ----
        wr(4'd0, 32'h0, 4'b0011);
        wr(4'd6, 32'h00F0, 4'b0011); peek(4'd0, v); check("set", v, 32'hF0);
        wr(4'd6, 32'h0F00, 4'b0001); peek(4'd0, v); check("set byte-lane (byte 1 khong ghi)", v, 32'hF0);
        wr(4'd7, 32'h0030, 4'b0011); peek(4'd0, v); check("clr", v, 32'hC0);
        wr(4'd8, 32'h00FF, 4'b0011); peek(4'd0, v); check("tgl", v, 32'h3F);
        wr(4'd8, 32'hFF00, 4'b0001); peek(4'd0, v); check("tgl byte-lane", v, 32'h3F);
        peek(4'd6, v); check("doc set = 0", v, 0); peek(4'd7, v); check("doc clr = 0", v, 0); peek(4'd8, v); check("doc tgl = 0", v, 0);
        peek(4'd9, v); check("dia chi ngoai = 0", v, 0);

        // ---- canh len: PEND, W1C, IE, irq ----
        pin = 0; repeat (6) @(posedge clk); wr(4'd0, 0, 4'b0011); wr(4'd4, 32'hFFFF, 4'b0011);
        peek(4'd4, v); check("pend sach", v, 0);
        pin[3] = 1; repeat (4) @(posedge clk); peek(4'd4, v); check("canh len -> pend", v, 32'h8);
        check("irq khi IE = 0", irq, 0);
        wr(4'd3, 32'h8, 4'b0001); check("irq khi IE", irq, 1);
        wr(4'd3, 32'h4, 4'b0001); check("irq IE khac chan", irq, 0);
        wr(4'd3, 32'h8, 4'b0001);
        wr(4'd4, 32'h8, 4'b0010); peek(4'd4, v); check("W1C sai byte-lane", v, 32'h8);
        wr(4'd4, 32'h8, 4'b0001); peek(4'd4, v); check("W1C", v, 0); check("irq het", irq, 0);
        pin[3] = 0; repeat (4) @(posedge clk); peek(4'd4, v); check("canh xuong khong tinh khi EDGE = 0", v, 0);

        // ---- canh xuong ----
        wr(4'd5, 32'h0020, 4'b0011); pin[5] = 1; repeat (4) @(posedge clk); peek(4'd4, v); check("canh len khong tinh khi EDGE = 1", v, 0);
        pin[5] = 0; repeat (4) @(posedge clk); peek(4'd4, v); check("canh xuong", v, 32'h20);
        wr(4'd4, 32'hFFFF, 4'b0011);

        // ---- su kien moi thang lenh xoa W1C trong cung chu ky ----
        pin = 0; repeat (6) @(posedge clk); wr(4'd5, 32'h0, 4'b0011); wr(4'd4, 32'hFFFF, 4'b0011);
        pin[2] = 1;
        @(negedge clk); while (!dut.ev[2]) @(negedge clk);
        sel = 1; we = 1; addr = 4'd4; wdata = 32'h4; wstrb = 4'b0001; @(negedge clk); sel = 0; we = 0; wstrb = 0;
        peek(4'd4, v); check("su kien thang W1C cung chu ky", v, 32'h4);
        wr(4'd4, 32'hFFFF, 4'b0011); pin = 0; repeat (6) @(posedge clk); wr(4'd4, 32'hFFFF, 4'b0011);

        // ---- kich thich ngau nhien so voi mo hinh ----
        rst_n = 0; @(posedge clk); #1 rst_n = 1;
        m_out = 0; m_dir = 0; m_ie = 0; m_pend = 0; m_edge = 0; m_s1 = 0; m_s2 = 0; m_q = 0; pin = 0; m_en = 1;
        seed = 32'h1234_5678;
        for (j = 0; j < 4000; j = j + 1) begin
            @(negedge clk);
            seed = seed * 1664525 + 1013904223;
            sel = (seed[5:3] != 0); we = seed[9]; addr = seed[14:11] % 10; wdata = seed * 22695477; wstrb = seed[19:16];
            if (seed[24:22] == 0) pin = pin ^ (16'h1 << seed[28:25]);
            if (seed[31:29] == 0) pin = seed[15:0];
        end
        @(negedge clk); sel = 0; we = 0; @(negedge clk);

        if (errors == 0) $display("[GPIO] PASS"); else $display("[GPIO] FAIL %0d loi", errors);
        $finish;
    end
    initial begin #20_000_000; $display("[GPIO] FAIL het gio"); $finish; end
endmodule
