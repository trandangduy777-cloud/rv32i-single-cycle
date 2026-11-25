// Testbench cau AXI4 -> bus ngoai vi cu (axi_periph_bridge): W den tre ngau nhien sau AW, burst INCR / WRAP / FIXED ghi va doc, bus cu la mang 16 tu,
// vung cuoi mang bao l_err. Kiem: moi beat ghi dung 1 lan (dem l_we), dung dia chi / du lieu / byte-lane, doc tra dung tu tung beat, B / R phan hoi dung.
// Chay: vvp tb_axi_br +seed=N ; ket thuc bang dong "[AXI_BR] PASS" hoac "[AXI_BR] FAIL".
`timescale 1ns/1ps
module tb_axi_br;
    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg [5:0] awid = 0; reg [31:0] awaddr = 0; reg [7:0] awlen = 0; reg [2:0] awsize = 2; reg [1:0] awburst = 1; reg awvalid = 0; wire awready;
    reg [31:0] wdata = 0; reg [3:0] wstrb = 0; reg wlast = 0, wvalid = 0; wire wready;
    wire [5:0] bid; wire [1:0] bresp; wire bvalid; reg bready = 1;
    reg [5:0] arid = 0; reg [31:0] araddr = 0; reg [7:0] arlen = 0; reg [2:0] arsize = 2; reg [1:0] arburst = 1; reg arvalid = 0; wire arready;
    wire [5:0] rid; wire [31:0] rdata; wire [1:0] rresp; wire rlast, rvalid; reg rready = 1;
    wire [31:0] l_addr; wire l_we, l_re; wire [3:0] l_wstrb; wire [31:0] l_wdata; wire [31:0] l_rdata; wire l_err;

    axi_periph_bridge #(.IDW(6)) dut (.clk(clk), .rst_n(rst_n),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .l_addr(l_addr), .l_we(l_we), .l_re(l_re), .l_wstrb(l_wstrb), .l_wdata(l_wdata), .l_rdata(l_rdata), .l_err(l_err));

    // bus cu: 16 tu o 0x2000_0000.., tu 15 (0x2000_003C) la vung loi; ghi vao tu loi khong lam gi
    reg [31:0] mem [0:15]; integer wcount [0:15];
    wire [3:0] widx = l_addr[5:2];
    assign l_err   = (l_we | l_re) & (l_addr[31:6] != 26'h0800000 || widx == 4'd15);
    assign l_rdata = mem[widx];
    integer errs = 0, nwe = 0;
    always @(posedge clk) if (rst_n && l_we && !l_err) begin
        mem[widx] <= (mem[widx] & ~{{8{l_wstrb[3]}}, {8{l_wstrb[2]}}, {8{l_wstrb[1]}}, {8{l_wstrb[0]}}}) | (l_wdata & {{8{l_wstrb[3]}}, {8{l_wstrb[2]}}, {8{l_wstrb[1]}}, {8{l_wstrb[0]}}});
        wcount[widx] <= wcount[widx] + 1; nwe <= nwe + 1;
    end

    integer seed = 1; reg [31:0] lf;
    function [31:0] rnd(input integer d); begin lf = lf * 32'd1664525 + 32'd1013904223 + d; rnd = lf >> 7; end endfunction
    function [31:0] nxtaddr(input [31:0] a, input [1:0] bt, input [7:0] ln);
        reg [31:0] wrap;
        begin
            wrap = ({24'd0, ln} + 32'd1) << 2;
            case (bt) 2'b00: nxtaddr = a; 2'b10: nxtaddr = (a & ~(wrap - 32'd1)) | ((a + 32'd4) & (wrap - 32'd1)); default: nxtaddr = a + 32'd4; endcase
        end
    endfunction

    reg [31:0] gm [0:15];       // mo hinh tham chieu
    integer gwc [0:15];

    task automatic do_write(input [31:0] a, input [7:0] ln, input [1:0] bt, input exp_err);
        integer b, d; reg [31:0] ba; reg [31:0] dd; reg [3:0] ss; reg [3:0] ix;
        reg [31:0] mk;
        begin
            awid <= rnd(1); awaddr <= a; awlen <= ln; awsize <= 3'd2; awburst <= bt; awvalid <= 1'b1;
            @(posedge clk); while (!awready) @(posedge clk);
            awvalid <= 1'b0;
            ba = a;
            for (b = 0; b <= ln; b = b + 1) begin
                d = rnd(2) % 5; repeat (d) @(posedge clk);              // W den tre sau AW / giua cac beat: cau khong duoc ghi khi chua co W
                dd = rnd(3); ss = rnd(4); if (ss == 0) ss = 4'hF;
                wdata <= dd; wstrb <= ss; wlast <= (b == ln); wvalid <= 1'b1;
                @(posedge clk); while (!wready) @(posedge clk);
                wvalid <= 1'b0;
                ix = ba[5:2]; mk = {{8{ss[3]}}, {8{ss[2]}}, {8{ss[1]}}, {8{ss[0]}}};
                if (!exp_err && ba[31:6] == 26'h0800000 && ix != 4'd15) begin gm[ix] = (gm[ix] & ~mk) | (dd & mk); gwc[ix] = gwc[ix] + 1; end
                ba = nxtaddr(ba, bt, ln);
            end
            while (!bvalid) @(posedge clk);
            if (bresp !== (exp_err ? 2'b11 : 2'b00)) begin errs = errs + 1; $display("[AXI_BR] BRESP %0d khac mong doi (dia chi %h)", bresp, a); end
            @(posedge clk);
        end
    endtask

    task automatic do_read(input [31:0] a, input [7:0] ln, input [1:0] bt, input exp_err);
        integer b; reg [31:0] ba;
        begin
            arid <= rnd(5); araddr <= a; arlen <= ln; arsize <= 3'd2; arburst <= bt; arvalid <= 1'b1;
            @(posedge clk); while (!arready) @(posedge clk);
            arvalid <= 1'b0; ba = a;
            for (b = 0; b <= ln; b = b + 1) begin
                rready <= (rnd(6) % 3) != 0;
                @(posedge clk); while (!(rvalid && rready)) begin rready <= (rnd(7) % 3) != 0; @(posedge clk); end
                if (!exp_err && rdata !== gm[ba[5:2]]) begin errs = errs + 1; $display("[AXI_BR] doc beat %0d dia chi %h: %h khac %h", b, ba, rdata, gm[ba[5:2]]); end
                if (rresp !== (exp_err ? 2'b11 : 2'b00)) begin errs = errs + 1; $display("[AXI_BR] RRESP %0d (dia chi %h)", rresp, a); end
                if (rlast !== (b == ln)) begin errs = errs + 1; $display("[AXI_BR] RLAST sai o beat %0d", b); end
                ba = nxtaddr(ba, bt, ln);
            end
            rready <= 1'b1;
        end
    endtask

    integer i, k, ln, bt; reg [31:0] a; reg [7:0] l8; reg [1:0] b2;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        lf = 32'h1234567 + seed * 32'h9E3779B9;
        for (i = 0; i < 16; i = i + 1) begin mem[i] = 32'd0; gm[i] = 32'd0; gwc[i] = 0; wcount[i] = 0; end
        repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
        for (k = 0; k < 400; k = k + 1) begin
            bt = rnd(8) % 3; if (bt == 3) bt = 1;
            b2 = (bt == 0) ? 2'b00 : (bt == 1) ? 2'b01 : 2'b10;
            case (b2)
                2'b10: begin ln = 1 + 2 * (rnd(9) % 2) + 4 * (rnd(10) % 2) * (rnd(11) % 2); if (ln != 1 && ln != 3 && ln != 7) ln = 3; l8 = ln; a = 32'h2000_0000 + 4 * (rnd(12) % 8); end
                2'b00: begin l8 = rnd(13) % 5; a = 32'h2000_0000 + 4 * (rnd(14) % 14); end
                default: begin l8 = rnd(15) % 8; a = 32'h2000_0000 + 4 * (rnd(16) % (15 - l8)); end
            endcase
            if (rnd(17) % 8 == 0) begin
                // vung loi: tu 15 hoac ngoai cua so
                a = (rnd(18) % 2) ? 32'h2000_003C : 32'h2000_0100;
                if (b2 == 2'b10) a = a & ~((({24'd0, l8} + 32'd1) << 2) - 32'd1);
                if (b2 == 2'b10 && a[5:2] != 4'd15 && a[31:6] == 26'h0800000) a = 32'h2000_0100;
                if (rnd(19) % 2) do_write(a, l8, b2, 1'b1); else do_read(a, l8, b2, 1'b1);
            end else if (rnd(20) % 2) do_write(a, l8, b2, 1'b0);
            else do_read(a, l8, b2, 1'b0);
        end
        repeat (10) @(posedge clk);
        for (i = 0; i < 15; i = i + 1) begin
            if (mem[i] !== gm[i]) begin errs = errs + 1; $display("[AXI_BR] mem[%0d] = %h khac mo hinh %h", i, mem[i], gm[i]); end
            if (wcount[i] !== gwc[i]) begin errs = errs + 1; $display("[AXI_BR] tu %0d bi ghi %0d lan, mong doi %0d (ghi khi chua co W?)", i, wcount[i], gwc[i]); end
        end
        if (errs == 0) $display("[AXI_BR] PASS 400 giao dich, %0d lan ghi bus cu, 0 loi", nwe); else $display("[AXI_BR] FAIL %0d loi", errs);
        $finish;
    end
    initial begin #50000000; $display("[AXI_BR] FAIL het gio"); $finish; end
endmodule
