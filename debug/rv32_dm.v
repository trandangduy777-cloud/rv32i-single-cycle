// Debug Module (RISC-V Debug spec 0.13.2) cho 1 hart: dmcontrol (haltreq, resumereq, ackhavereset, ndmreset, dmactive),
// dmstatus, hartinfo, abstractcs, command (Access Register 32 bit: GPR 0x1000-0x101F, CSR 0x0000-0x0FFF, postexec,
// transfer, write), data0/1, progbuf0-7 (impebreak), abstractauto (autoexecdata, autoexecprogbuf), haltsum0. Khong co: system bus, nhieu hart (hartsel != 0
// la khong ton tai), aarpostincrement, quick access (nhung cmd do tra cmderr = 2 "khong ho tro").
// Hart giao tiep qua vung nho 0xFFFF_F800-0xFFFF_FFFF (chi truy cap duoc khi hart o D-mode, do top giai ma):
//   +0x000 ROM debug (debug/dbg_rom.S, sinh boi debug/gen_rom.py)    +0x200 chuong trinh tru tuong (5 tu) + progbuf (8 tu) + ebreak
//   +0x300 data0 / data1                                              +0x400 hop thu ghi: HALTED GOING RESUMING DONE EXC; +0x420 doc: FLAGS
// Lenh tru tuong (command) duoc dich thanh lenh RISC-V ghi vao 5 tu dau cua vung chuong trinh roi hart chay (GO).
module rv32_dm (
    input  wire        clk,
    input  wire        rst_n,
    // DMI (mien clk): dmi_valid 1 chu ky; doc tra dmi_rdata ngay (to hop, gia tri truoc khi ghi)
    input  wire        dmi_valid,
    input  wire        dmi_write,
    input  wire [6:0]  dmi_addr,
    input  wire [31:0] dmi_wdata,
    output reg  [31:0] dmi_rdata,
    // hart
    output wire        halt_req,
    output wire        ndmreset,
    input  wire        hart_reset_ack,    // loi vua duoc reset (xung) -> havereset
    // bus cua hart toi vung debug
    input  wire [31:0] h_iaddr,
    output reg  [31:0] h_idata,
    input  wire [31:0] h_daddr,
    input  wire        h_dre,
    output reg  [31:0] h_drdata,
    input  wire        h_dwe,
    input  wire [3:0]  h_dwstrb,
    input  wire [31:0] h_dwdata
);
    // ROM-BEGIN
    localparam [31:0] ROM_00 = 32'h00c0006f;
    localparam [31:0] ROM_01 = 32'h0300006f;
    localparam [31:0] ROM_02 = 32'h0380006f;
    localparam [31:0] ROM_03 = 32'h7b241073;
    localparam [31:0] ROM_04 = 32'hc0002023;
    localparam [31:0] ROM_05 = 32'hc2002403;
    localparam [31:0] ROM_06 = 32'hfe040ee3;
    localparam [31:0] ROM_07 = 32'hfff40413;
    localparam [31:0] ROM_08 = 32'h00040463;
    localparam [31:0] ROM_09 = 32'h0280006f;
    localparam [31:0] ROM_10 = 32'hc0002223;
    localparam [31:0] ROM_11 = 32'h7b202473;
    localparam [31:0] ROM_12 = 32'ha0000067;
    localparam [31:0] ROM_13 = 32'h7b241073;
    localparam [31:0] ROM_14 = 32'hc0002623;
    localparam [31:0] ROM_15 = 32'hfd9ff06f;
    localparam [31:0] ROM_16 = 32'h7b241073;
    localparam [31:0] ROM_17 = 32'hc0002823;
    localparam [31:0] ROM_18 = 32'hfcdff06f;
    localparam [31:0] ROM_19 = 32'h7b202473;
    localparam [31:0] ROM_20 = 32'hc0002423;
    localparam [31:0] ROM_21 = 32'h7b200073;
    localparam ROM_N = 22;
    // ROM-END

    localparam [31:0] NOP = 32'h0000_0013, EBREAK = 32'h0010_0073;

    reg        dmactive, haltreq, ndm, havereset, resumeack, halted, busy, go_f, resume_f;
    reg  [2:0] cmderr;
    reg  [31:0] data0, data1;
    reg  [31:0] pb [0:7];
    reg  [31:0] ab [0:4];
    reg  [9:0] hartsel;
    reg  [1:0] auto_d;                 // abstractauto.autoexecdata
    reg  [7:0] auto_p;                 // abstractauto.autoexecprogbuf
    reg  [31:0] last_cmd;              // lenh tru tuong gan nhat (chay lai khi autoexec)
    wire       sel0 = (hartsel == 10'd0);
    assign halt_req = haltreq & dmactive & sel0;
    assign ndmreset = ndm & dmactive;

    // ---- chuong trinh tru tuong ----
    function [31:0] enc_sw(input [4:0] rs2);  enc_sw = {7'h58, rs2, 5'd0, 3'd2, 5'd0, 7'h23}; endfunction        // sw rs2, -0x500(x0)
    function [31:0] enc_lw(input [4:0] rd);   enc_lw = {12'hB00, 5'd0, 3'd2, rd, 7'h03};       endfunction        // lw rd, -0x500(x0)
    function [31:0] enc_csrw(input [11:0] c, input [4:0] rs1); enc_csrw = {c, rs1, 3'd1, 5'd0, 7'h73}; endfunction
    function [31:0] enc_csrr(input [4:0] rd, input [11:0] c);  enc_csrr = {c, 5'd0, 3'd2, rd, 7'h73}; endfunction

    // autoexec: truy cap data_i / progbuf_i (doc hoac ghi) co bit tuong ung chay lai lenh gan nhat sau truy cap do
    wire        auto_trig = dmi_valid & ((((dmi_addr == 7'h04) & auto_d[0]) | ((dmi_addr == 7'h05) & auto_d[1])) |
                                         ((dmi_addr[6:3] == 4'b0100) & auto_p[dmi_addr[2:0]]));
    wire [31:0] cmd     = auto_trig ? last_cmd : dmi_wdata;
    wire        c_trans = cmd[17], c_write = cmd[16], c_post = cmd[18], c_pinc = cmd[19];
    wire [2:0]  c_size  = cmd[22:20];
    wire [15:0] c_reg   = cmd[15:0];
    wire        c_gpr   = (c_reg[15:5] == 11'h080);                    // 0x1000-0x101F
    wire        c_csr   = (c_reg[15:12] == 4'h0);
    wire        cmd_wr  = (dmi_valid & dmi_write & (dmi_addr == 7'h17)) | auto_trig;
    wire        cmd_ok  = (cmd[31:24] == 8'd0) & (~c_trans | ((c_size == 3'd2) & ~c_pinc & (c_gpr | c_csr)));

    integer i;
    reg [31:0] a0, a1, a2, a3;
    always @* begin
        a0 = NOP; a1 = NOP; a2 = NOP; a3 = NOP;
        if (c_trans) begin
            if (c_gpr) begin
                if (c_write) a0 = (c_reg[4:0] == 5'd0) ? NOP : enc_lw(c_reg[4:0]);
                else         a0 = enc_sw(c_reg[4:0]);
            end else begin                                             // CSR: dung s0 lam thanh ghi tam, cat vao dscratch1
                a0 = enc_csrw(12'h7B3, 5'd8);
                a1 = c_write ? enc_lw(5'd8) : enc_csrr(5'd8, c_reg[11:0]);
                a2 = c_write ? enc_csrw(c_reg[11:0], 5'd8) : enc_sw(5'd8);
                a3 = enc_csrr(5'd8, 12'h7B3);
            end
        end
    end

    // ---- DMI ----
    wire dw = dmi_valid & dmi_write;
    wire dr = dmi_valid & ~dmi_write;
    wire is_data = (dmi_addr == 7'h04) | (dmi_addr == 7'h05);
    wire is_pb   = (dmi_addr[6:3] == 4'b0100);                        // 0x20-0x27
    always @* begin
        case (dmi_addr)
            7'h04: dmi_rdata = data0;
            7'h05: dmi_rdata = data1;
            7'h10: dmi_rdata = {6'd0, hartsel, 14'd0, ndm, dmactive};
            7'h11: dmi_rdata = {9'd0, 1'b1 /*impebreak*/, 2'b00, havereset & sel0, havereset & sel0,
                                resumeack & sel0, resumeack & sel0, ~sel0, ~sel0, 2'b00,
                                ~halted & sel0, ~halted & sel0, halted & sel0, halted & sel0, 1'b1 /*authenticated*/,
                                3'b000, 4'd2 /*version 0.13*/};
            7'h12: dmi_rdata = 32'h0010_0000;                          // hartinfo: nscratch = 1, du lieu qua thanh ghi data
            7'h16: dmi_rdata = {3'd0, 5'd8 /*progbufsize*/, 11'd0, busy, 1'b0, cmderr, 4'd0, 4'd2 /*datacount*/};
            7'h17: dmi_rdata = 32'd0;
            7'h18: dmi_rdata = {8'd0, auto_p, 4'd0, 10'd0, auto_d};
            7'h40: dmi_rdata = {31'd0, halted & sel0};
            default: dmi_rdata = is_pb ? pb[dmi_addr[2:0]] : 32'd0;
        endcase
    end
    // ---- hop thu va bus hart ----
    wire        h_reg   = h_daddr[31:11] == 21'h1FFFFF;
    wire [10:0] h_off   = h_daddr[10:0];
    wire        mb_we   = h_dwe & (h_off[10:8] == 3'b100);             // hop thu o +0x400..
    wire [2:0]  mb_sel  = h_off[4:2];
    always @* begin
        h_idata = NOP;
        case (h_iaddr[10:2])
            9'd0: h_idata = ROM_00;  9'd1: h_idata = ROM_01;  9'd2: h_idata = ROM_02;  9'd3: h_idata = ROM_03;
            9'd4: h_idata = ROM_04;  9'd5: h_idata = ROM_05;  9'd6: h_idata = ROM_06;  9'd7: h_idata = ROM_07;
            9'd8: h_idata = ROM_08;  9'd9: h_idata = ROM_09;  9'd10: h_idata = ROM_10; 9'd11: h_idata = ROM_11;
            9'd12: h_idata = ROM_12; 9'd13: h_idata = ROM_13; 9'd14: h_idata = ROM_14; 9'd15: h_idata = ROM_15;
            9'd16: h_idata = ROM_16; 9'd17: h_idata = ROM_17; 9'd18: h_idata = ROM_18; 9'd19: h_idata = ROM_19;
            9'd20: h_idata = ROM_20; 9'd21: h_idata = ROM_21;
            9'd128: h_idata = ab[0]; 9'd129: h_idata = ab[1]; 9'd130: h_idata = ab[2]; 9'd131: h_idata = ab[3];
            9'd132: h_idata = ab[4];
            9'd133: h_idata = pb[0]; 9'd134: h_idata = pb[1]; 9'd135: h_idata = pb[2]; 9'd136: h_idata = pb[3];
            9'd137: h_idata = pb[4]; 9'd138: h_idata = pb[5]; 9'd139: h_idata = pb[6]; 9'd140: h_idata = pb[7];
            9'd141: h_idata = EBREAK;
            default: h_idata = NOP;
        endcase
    end
    always @* begin
        h_drdata = 32'd0;
        if (h_off[10:2] == 9'd192)  h_drdata = data0;                  // +0x300
        if (h_off[10:2] == 9'd193)  h_drdata = data1;                  // +0x304
        if (h_off == 11'h420)       h_drdata = resume_f ? 32'd2 : (go_f ? 32'd1 : 32'd0);
    end
    wire [31:0] wmask = {{8{h_dwstrb[3]}}, {8{h_dwstrb[2]}}, {8{h_dwstrb[1]}}, {8{h_dwstrb[0]}}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmactive <= 1'b0; haltreq <= 1'b0; ndm <= 1'b0; havereset <= 1'b1; resumeack <= 1'b0; halted <= 1'b0;
            busy <= 1'b0; go_f <= 1'b0; resume_f <= 1'b0; cmderr <= 3'd0; data0 <= 32'd0; data1 <= 32'd0; hartsel <= 10'd0; auto_d <= 2'd0; auto_p <= 8'd0; last_cmd <= 32'd0;
            for (i = 0; i < 8; i = i + 1) pb[i] <= 32'd0;
            for (i = 0; i < 5; i = i + 1) ab[i] <= NOP;
        end else begin
            if (hart_reset_ack) begin havereset <= 1'b1; halted <= 1'b0; busy <= 1'b0; go_f <= 1'b0; resume_f <= 1'b0; end
            // hop thu cua hart
            if (h_reg & mb_we) begin
                case (mb_sel)
                    3'd0: halted <= 1'b1;
                    3'd1: go_f <= 1'b0;
                    3'd2: begin resume_f <= 1'b0; halted <= 1'b0; resumeack <= 1'b1; end
                    3'd3: busy <= 1'b0;
                    3'd4: begin busy <= 1'b0; if (cmderr == 3'd0) cmderr <= 3'd3; end
                    default: ;
                endcase
            end
            if (h_reg & h_dwe & (h_off[10:2] == 9'd192)) data0 <= (data0 & ~wmask) | (h_dwdata & wmask);
            if (h_reg & h_dwe & (h_off[10:2] == 9'd193)) data1 <= (data1 & ~wmask) | (h_dwdata & wmask);
            if (dr & busy & (is_data | is_pb) & (cmderr == 3'd0)) cmderr <= 3'd1;   // doc data / progbuf khi dang chay lenh
            if (dmi_valid & ~dmactive & ~(dw & (dmi_addr == 7'h10) & dmi_wdata[0])) begin
                // dmactive = 0: moi ghi (tru dmcontrol.dmactive = 1) bi bo
            end else if (dw) begin
                case (dmi_addr)
                    7'h10: begin
                        dmactive <= dmi_wdata[0];
                        if (!dmi_wdata[0]) begin haltreq <= 1'b0; ndm <= 1'b0; hartsel <= 10'd0; cmderr <= 3'd0; resumeack <= 1'b0; end
                        else begin
                            haltreq <= dmi_wdata[31]; ndm <= dmi_wdata[1]; hartsel <= dmi_wdata[25:16];
                            if (dmi_wdata[28]) havereset <= 1'b0;
                            if (dmi_wdata[30] & ~dmi_wdata[31] & halted & ~busy & (dmi_wdata[25:16] == 10'd0)) begin
                                resume_f <= 1'b1; resumeack <= 1'b0;
                            end
                        end
                    end
                    7'h04: if (!busy) data0 <= dmi_wdata; else if (cmderr == 3'd0) cmderr <= 3'd1;
                    7'h05: if (!busy) data1 <= dmi_wdata; else if (cmderr == 3'd0) cmderr <= 3'd1;
                    7'h16: if (!busy) cmderr <= cmderr & ~dmi_wdata[10:8]; else if (cmderr == 3'd0) cmderr <= 3'd1;
                    7'h18: if (!busy) begin auto_d <= dmi_wdata[1:0]; auto_p <= dmi_wdata[23:16]; end
                    default: if (is_pb) begin
                        if (!busy) pb[dmi_addr[2:0]] <= dmi_wdata; else if (cmderr == 3'd0) cmderr <= 3'd1;
                    end
                endcase
            end
            // lenh tru tuong (ghi command hoac autoexec)
            if (dmactive & cmd_wr) begin
                if (busy) begin if (cmderr == 3'd0) cmderr <= 3'd1; end
                else if (cmderr == 3'd0) begin
                    if (!cmd_ok) cmderr <= 3'd2;
                    else if (!halted | resume_f) cmderr <= 3'd4;
                    else begin
                        if (!auto_trig) last_cmd <= dmi_wdata;
                        if (c_trans | c_post) begin
                            ab[0] <= a0; ab[1] <= a1; ab[2] <= a2; ab[3] <= a3; ab[4] <= c_post ? NOP : EBREAK;
                            busy <= 1'b1; go_f <= 1'b1;
                        end
                    end
                end
            end
        end
    end
endmodule
