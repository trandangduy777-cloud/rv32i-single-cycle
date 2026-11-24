`timescale 1ns/1ps
// Test rieng cho soc_bus, soc_rom, soc_ram, soc_syscon: bien tung vung dia chi, chon dung mot vung, mux du lieu doc, bus_err,
// ROM doc lenh o dia chi chia het cho 2 (vat qua ranh gioi tu), RAM theo byte, SYSCON (ID, SCRATCH theo byte, EXIT, BUSERR dem, bao hoa).
module tb_bus;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer errors = 0;
    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin errors = errors + 1; $display("[BUS] LOI %0s: %h, mong doi %h", what, got, want); end
    endtask

    reg [31:0] daddr = 0, iaddr = 0; reg dwe = 0, dre = 0;
    wire sel_rom, sel_ram, sel_clint, sel_uart, sel_gpio, sel_sys, sel_plic, i_sel_rom, i_sel_ram, bus_err; wire [31:0] rdata;
    soc_bus #(.ROM_AW(14), .RAM_AW(14)) bus (
        .daddr(daddr), .dwe(dwe), .dre(dre), .sel_rom(sel_rom), .sel_ram(sel_ram), .sel_clint(sel_clint), .sel_uart(sel_uart),
        .sel_gpio(sel_gpio), .sel_sys(sel_sys), .sel_plic(sel_plic), .rom_rd(32'h1111_0001), .ram_rd(32'h2222_0002), .clint_rd(32'h3333_0003),
        .uart_rd(32'h4444_0004), .gpio_rd(32'h5555_0005), .sys_rd(32'h6666_0006), .plic_rd(32'h7777_0007), .rdata(rdata), .bus_err(bus_err),
        .iaddr(iaddr), .i_sel_rom(i_sel_rom), .i_sel_ram(i_sel_ram));

    // mo hinh tham chieu: vung (0 = khong co) va gia tri doc
    function [2:0] region(input [31:0] a);
        begin
            if (a < 32'h4000) region = 1;
            else if (a >= 32'h1000_0000 && a < 32'h1000_4000) region = 2;
            else if (a >= 32'h0200_0000 && a < 32'h0200_0020) region = 3;
            else if (a >= 32'h2000_0000 && a < 32'h2000_1000) region = 4;
            else if (a >= 32'h2000_1000 && a < 32'h2000_2000) region = 5;
            else if (a >= 32'h2000_2000 && a < 32'h2000_3000) region = 6;
            else if (a >= 32'h0C00_0000 && a < 32'h0C40_0000) region = 7;
            else region = 0;
        end
    endfunction
    function [31:0] rv(input [2:0] r);
        case (r) 1: rv = 32'h1111_0001; 2: rv = 32'h2222_0002; 3: rv = 32'h3333_0003; 4: rv = 32'h4444_0004; 5: rv = 32'h5555_0005; 6: rv = 32'h6666_0006; 7: rv = 32'h7777_0007; default: rv = 0; endcase
    endfunction
    task probe(input [31:0] a);
        reg [2:0] r; reg [6:0] s;
        begin
            r = region(a); daddr = a; iaddr = a; dre = 1; dwe = 0; #1;
            s = {sel_plic, sel_sys, sel_gpio, sel_uart, sel_clint, sel_ram, sel_rom};
            if (s !== (r == 0 ? 7'd0 : (7'd1 << (r - 1)))) begin errors = errors + 1; $display("[BUS] LOI giai ma %h: sel=%b vung=%0d", a, s, r); end
            if (rdata !== rv(r)) begin errors = errors + 1; $display("[BUS] LOI du lieu doc %h: %h", a, rdata); end
            if (bus_err !== (r == 0)) begin errors = errors + 1; $display("[BUS] LOI bus_err doc %h", a); end
            dre = 0; dwe = 1; #1;
            if (bus_err !== (r == 0 || r == 1)) begin errors = errors + 1; $display("[BUS] LOI bus_err ghi %h", a); end
            dwe = 0; #1;
            if (bus_err !== 1'b0) begin errors = errors + 1; $display("[BUS] LOI bus_err khi khong truy cap %h", a); end
            if (i_sel_ram !== (a >= 32'h1000_0000 && a < 32'h1000_4000)) begin errors = errors + 1; $display("[BUS] LOI i_sel_ram %h", a); end
            if (i_sel_rom !== (a < 32'h4000)) begin errors = errors + 1; $display("[BUS] LOI i_sel_rom %h", a); end
        end
    endtask

    // ---- ROM, RAM, SYSCON that ----
    reg [31:0] ram_ia = 0; wire [31:0] ram_id;
    reg [31:0] ra_i = 0, ra_d = 0; wire [31:0] rom_i, rom_d;
    soc_rom #(.WORDS(16)) rom (.i_addr(ra_i), .i_data(rom_i), .d_addr(ra_d), .d_data(rom_d));
    reg ram_sel = 0, ram_we = 0; reg [31:0] ram_addr = 0, ram_wd = 0; reg [3:0] ram_ws = 0; wire [31:0] ram_rd;
    soc_ram #(.WORDS(16)) ram (.clk(clk), .sel(ram_sel), .addr(ram_addr), .we(ram_we), .wstrb(ram_ws), .wdata(ram_wd), .rdata(ram_rd), .i_addr(ram_ia), .i_data(ram_id));
    reg ss = 0, sw = 0; reg [4:2] sa = 0; reg [3:0] sws = 0; reg [31:0] swd = 0; wire [31:0] srd; reg berr = 0; wire ev; wire [31:0] ec;
    soc_syscon sys (.clk(clk), .rst_n(rst_n), .sel(ss), .addr(sa), .we(sw), .wstrb(sws), .wdata(swd), .rdata(srd), .bus_err(berr), .exit_valid(ev), .exit_code(ec));

    task sysw(input [4:2] a, input [31:0] d, input [3:0] s); begin @(negedge clk); ss = 1; sw = 1; sa = a; swd = d; sws = s; @(negedge clk); ss = 0; sw = 0; sws = 0; end endtask
    task sysr(input [4:2] a, output [31:0] d); begin @(negedge clk); ss = 1; sw = 0; sa = a; #1 d = srd; @(negedge clk); ss = 0; end endtask

    integer j, k; reg [31:0] seed, v; reg [31:0] words [0:15]; reg [31:0] expw; reg [7:0] bytes [0:63]; reg [31:0] pa;
    initial begin
        // ---- giai ma: bien va ngau nhien ----
        probe(32'h0000_0000); probe(32'h0000_3FFC); probe(32'h0000_4000); probe(32'h0000_7FFC); probe(32'h0000_8000); probe(32'h4000_0000);
        probe(32'h0FFF_FFFC); probe(32'h1000_0000); probe(32'h1000_3FFC); probe(32'h1000_4000); probe(32'h1000_8000); probe(32'h1100_0000); probe(32'h9000_0000);
        probe(32'h01FF_FFFC); probe(32'h0200_0000); probe(32'h0200_0010); probe(32'h0200_001C); probe(32'h0200_0020); probe(32'h0200_0040); probe(32'h0300_0000); probe(32'h0A00_0000);
        probe(32'h1FFF_FFFC); probe(32'h2000_0000); probe(32'h2000_0FFC); probe(32'h2000_1000); probe(32'h2000_1FFC); probe(32'h2000_2000);
        probe(32'h2000_2FFC); probe(32'h2000_3000); probe(32'h2000_FFFC); probe(32'h2001_0000); probe(32'h2100_0000); probe(32'hA000_0000); probe(32'hFFFF_FFFC);
        seed = 32'hC0FFEE01;
        for (j = 0; j < 20000; j = j + 1) begin
            seed = seed * 1664525 + 1013904223;
            case (seed[2:0])
                0: pa = seed >> 3;                                     // ngau nhien thuan
                1: pa = {18'd0, seed[13:2], 2'b00} ^ (seed[31] ? 32'h0000_4000 : 0);
                2: pa = 32'h1000_0000 ^ {seed[17:3], 2'b00};
                3: pa = 32'h0200_0000 ^ {seed[9:3], 2'b00};
                4: pa = 32'h2000_0000 ^ {seed[17:3], 2'b00};
                default: pa = seed;
            endcase
            probe(pa);
        end

        // ---- ROM: nap tu va doc lenh chia het cho 2 ----
        for (j = 0; j < 16; j = j + 1) begin words[j] = {8'(j * 16 + 3), 8'(j * 16 + 2), 8'(j * 16 + 1), 8'(j * 16 + 0)} ^ 32'hA5C3_0F1E; rom.mem[j] = words[j]; end
        for (j = 0; j < 64; j = j + 2) begin
            ra_i = j; ra_d = j; #1;
            expw = (j % 4 == 0) ? words[j / 4] : {words[(j / 4 + 1) % 16][15:0], words[j / 4][31:16]};
            check("rom lenh", rom_i, expw);
            check("rom du lieu", rom_d, words[j / 4]);
        end
        ra_i = 32'h3FFE; #1; check("rom vat o cuoi", rom_i, {rom.mem[0][15:0], rom.mem[15][31:16]});

        // ---- RAM theo byte ----
        for (j = 0; j < 64; j = j + 1) bytes[j] = 0;
        for (j = 0; j < 2000; j = j + 1) begin
            seed = seed * 1664525 + 1013904223;
            @(negedge clk); ram_addr = {26'd0, seed[9:4], 2'b00} & 32'h3C; ram_wd = seed * 69069; ram_ws = seed[19:16]; ram_sel = seed[20] | seed[21]; ram_we = seed[22] | seed[23];
            k = ram_addr[5:2] * 4;
            if (ram_sel & ram_we) begin
                if (ram_ws[0]) bytes[k]   = ram_wd[7:0];
                if (ram_ws[1]) bytes[k+1] = ram_wd[15:8];
                if (ram_ws[2]) bytes[k+2] = ram_wd[23:16];
                if (ram_ws[3]) bytes[k+3] = ram_wd[31:24];
            end
            @(negedge clk); ram_sel = 0; ram_we = 0;
            k = (seed[15:12]) * 4; ram_addr = k; #1;
            check("ram doc", ram_rd, {bytes[k+3], bytes[k+2], bytes[k+1], bytes[k]});
        end

        // ---- RAM: cong lenh chia het cho 2 (lenh nen vat qua ranh gioi tu, vat vong o cuoi mang) ----
        for (j = 0; j < 64; j = j + 2) begin
            ram_ia = j; #1;
            check("ram lenh", ram_id, {bytes[(j+3)%64], bytes[(j+2)%64], bytes[(j+1)%64], bytes[j]});
        end

        // ---- SYSCON ----
        repeat (3) @(posedge clk); #1 rst_n = 1;
        sysr(3'd0, v); check("sys id", v, 32'h5256_3C01);
        sysw(3'd0, 32'hDEAD_BEEF, 4'b1111); sysr(3'd0, v); check("sys id chi doc", v, 32'h5256_3C01);
        sysw(3'd1, 32'h1122_3344, 4'b1111); sysr(3'd1, v); check("scratch", v, 32'h1122_3344);
        sysw(3'd1, 32'h0000_AA00, 4'b0010); sysr(3'd1, v); check("scratch byte 1", v, 32'h1122_AA44);
        sysw(3'd1, 32'h00BB_0000, 4'b0100); sysr(3'd1, v); check("scratch byte 2", v, 32'h11BB_AA44);
        sysw(3'd1, 32'hCC00_0000, 4'b1000); sysr(3'd1, v); check("scratch byte 3", v, 32'hCCBB_AA44);
        sysw(3'd1, 32'h0000_00DD, 4'b0001); sysr(3'd1, v); check("scratch byte 0", v, 32'hCCBB_AADD);
        sysw(3'd1, 32'h0, 4'b0000); sysr(3'd1, v); check("scratch wstrb 0", v, 32'hCCBB_AADD);
        if (ev !== 1'b0) begin errors = errors + 1; $display("[BUS] LOI exit_valid som"); end
        sysw(3'd2, 32'h0000_002A, 4'b1111); sysr(3'd2, v); check("exit doc lai", v, 32'h2A);
        if (ev !== 1'b1 || ec !== 32'h2A) begin errors = errors + 1; $display("[BUS] LOI exit"); end
        sysr(3'd4, v); check("sys dia chi khac", v, 0);
        // BUSERR: dem, xoa, bao hoa
        sysw(3'd3, 0, 4'b1111); sysr(3'd3, v); check("buserr ve 0", v, 0);
        @(negedge clk); berr = 1; repeat (5) @(negedge clk); berr = 0; sysr(3'd3, v); check("buserr dem 5", v, 5);
        sysw(3'd3, 1, 4'b0001); sysr(3'd3, v); check("buserr xoa bang ghi bat ky", v, 0);
        @(negedge clk); berr = 1; sysw(3'd3, 0, 4'b1111); berr = 0; sysr(3'd3, v); check("xoa thang dem cung chu ky", v, 0);
        sys.berr = 32'hFFFF_FFFE; @(negedge clk); berr = 1; repeat (4) @(negedge clk); berr = 0; sysr(3'd3, v); check("buserr bao hoa", v, 32'hFFFF_FFFF);

        if (errors == 0) $display("[BUS] PASS"); else $display("[BUS] FAIL %0d loi", errors);
        $finish;
    end
    initial begin #200_000_000; $display("[BUS] FAIL het gio"); $finish; end
endmodule
