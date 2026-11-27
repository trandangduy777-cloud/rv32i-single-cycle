`timescale 1ns/1ps
// Kiem rv32_ram (mo hinh mo phong, hoac -DRV32_RAM_IHP voi ihp_sram_stub.v) so voi mo hinh tham chieu doc lap: ngau nhien doc / ghi / khong truy cap,
// byte enable ngau nhien, doc ngay sau ghi, dout giu khi ghi / khong enable, nhieu cau hinh (rong 32 / 64 / 24 (chi mo phong), do sau).
// Chay: iverilog -g2012 [-DRV32_RAM_IHP] -o x soc/tb/tb_ram.v soc/mem/rv32_ram.v [soc/mem/ihp_sram_stub.v] && vvp x [+seed=N]
module ram_chk #(parameter WORDS = 1024, parameter DW = 32, parameter BW = 8, parameter N = 60000, parameter SEED = 1) (input clk, output reg done, output reg [31:0] errs);
    localparam AW = $clog2(WORDS), NB = DW / BW;
    reg en = 0, we = 0; reg [NB-1:0] be = 0; reg [AW-1:0] addr = 0; reg [DW-1:0] din = 0;
    wire [DW-1:0] dout;
    rv32_ram #(.WORDS(WORDS), .DW(DW), .BW(BW)) dut (.clk(clk), .en(en), .we(we), .be(be), .addr(addr), .din(din), .dout(dout));
    reg [DW-1:0] ref_mem [0:WORDS-1];
    reg [DW-1:0] ref_dout;
    reg [DW-1:0] known [0:WORDS-1];          // bit nao da tung duoc ghi (macro that khong khoi tao: chi so sanh bit da biet)
    reg [DW-1:0] kd;
    integer i, b, seed, r;
    initial begin
        done = 0; errs = 0; seed = SEED;
        for (i = 0; i < WORDS; i = i + 1) begin ref_mem[i] = 0; known[i] = 0; end
        ref_dout = 0; kd = 0;
        repeat (3) @(posedge clk);
        for (i = 0; i < N; i = i + 1) begin
            // dat tin hieu sau canh len (tranh dua), kiem dout o canh sau
            #1;
            r = $random(seed);
            en = (r[3:0] != 0);
            we = r[4] | (r[5] & r[6]);
            be = $random(seed);
            if (r[9:7] == 0 && i > 0) addr = addr;                                       // lap dia chi: doc ngay sau ghi / ghi de
            else if (r[9:7] == 1) addr = $random(seed) % 4;                              // vung nho, de va cham
            else addr = $random(seed);
            din = {$random(seed), $random(seed)};
            // mo hinh: cap nhat theo canh sap toi
            if (en) begin
                if (we) begin
                    for (b = 0; b < NB; b = b + 1) if (be[b]) begin ref_mem[addr][b*BW +: BW] = din[b*BW +: BW]; known[addr][b*BW +: BW] = {BW{1'b1}}; end
                end else begin ref_dout = ref_mem[addr]; kd = known[addr]; end
            end
            @(posedge clk);
            #1;
            if ((dout & kd) !== (ref_dout & kd)) begin
                errs = errs + 1;
                if (errs < 5) $display("[RAM] LOI W=%0d DW=%0d BW=%0d op %0d: dout %h mong doi %h (bit biet %h)", WORDS, DW, BW, i, dout, ref_dout, kd);
            end
        end
        done = 1;
    end
endmodule

module tb_ram;
    reg clk = 0; always #5 clk = ~clk;
    wire [5:0] d; wire [31:0] e0, e1, e2, e3, e4, e5;
    integer sd = 1;
    initial if ($value$plusargs("seed=%d", sd)) ;
    ram_chk #(.WORDS(1024), .DW(32), .SEED(1))  c0 (clk, d[0], e0);
    ram_chk #(.WORDS(2048), .DW(32), .SEED(2))  c1 (clk, d[1], e1);
    ram_chk #(.WORDS(512),  .DW(64), .SEED(3))  c2 (clk, d[2], e2);
    ram_chk #(.WORDS(4096), .DW(32), .SEED(4))  c3 (clk, d[3], e3);
    ram_chk #(.WORDS(2048), .DW(64), .SEED(5))  c4 (clk, d[4], e4);
    ram_chk #(.WORDS(512),  .DW(32), .SEED(6))  c5 (clk, d[5], e5);
    wire [31:0] etot = e0 + e1 + e2 + e3 + e4 + e5;
    initial begin
        wait (&d);
        #20;
`ifdef RV32_RAM_IHP
        if (etot == 0) $display("[RAM_IHP] PASS 6 cau hinh x 60000 thao tac khop mo hinh (qua stub macro, giao dien gia dinh)");
        else $display("[RAM_IHP] FAIL %0d loi", etot);
`else
        if (etot == 0) $display("[RAM] PASS 6 cau hinh x 60000 thao tac khop mo hinh");
        else $display("[RAM] FAIL %0d loi", etot);
`endif
        $finish;
    end
    initial begin #50000000; $display("[RAM] FAIL het gio"); $finish; end
endmodule
