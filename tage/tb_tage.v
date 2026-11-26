`timescale 1ns/1ps
// Testbench don vi cho rv32_tage.v: doc vet nhanh (moi dong "pc_hex taken"), voi moi nhanh: du doan (to hop) roi cap
// nhat bang + lich su trong cung chu ky. In "P <du doan>" moi nhanh de so voi mo hinh tham chieu tage/tage_model.py.
module tb_tage;
`ifndef NT
`define NT 4
`endif
`ifndef IB
`define IB 6
`endif
`ifndef TB
`define TB 8
`endif
`ifndef BB
`define BB 7
`endif
`ifndef HLV
`define HLV {8'd32, 8'd16, 8'd8, 8'd4}
`endif
`ifndef RSTLOG
`define RSTLOG 11
`endif
    localparam PW = $clog2(`NT + 1);
    localparam MW = 3 + 1 + 2 * PW + `BB + `NT * (`IB + `TB);
    reg clk = 0, rst_n = 1;
    reg  [31:0] pc;
    reg         tk, v;
    wire        pt;
    wire [MW-1:0] pm;
    rv32_tage #(.NT(`NT), .IB(`IB), .TB(`TB), .BB(`BB), .PCB(1), .HL(`HLV), .RST_LOG(`RSTLOG)) dut (
        .clk(clk), .rst_n(rst_n), .p_pc(pc), .p_taken(pt), .p_meta(pm),
        .u_valid(v), .u_taken(tk), .u_meta(pm), .h_valid(v), .h_taken(tk));
    integer fd, r, n = 0, nm = 0;
    reg [31:0] a; integer t;
    initial begin
        if (!$value$plusargs("trace=%s", fname)) $finish;
        fd = $fopen(fname, "r");
        v = 0; pc = 0; tk = 0;
        #1 rst_n = 0; #4 rst_n = 1;
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %d\n", a, t);
            if (r == 2) begin
                pc = a; tk = t[0]; v = 1;
                #1 $display("P %0d", pt);
                n = n + 1; if (pt != tk) nm = nm + 1;
                #4 clk = 1; #5 clk = 0; v = 0;
            end
        end
        $display("DONE n=%0d miss=%0d", n, nm);
        $finish;
    end
    reg [8*256-1:0] fname;
endmodule
