// Bo giai nen lenh RV32C (mo rong C: lenh 16 bit) thanh lenh 32 bit tuong duong, mach to hop, tu viet.
// - Ho tro toan bo lenh RV32C khong dung so thuc: c.addi4spn c.lw c.sw | c.nop c.addi c.jal c.li c.addi16sp c.lui
//   c.srli c.srai c.andi c.sub c.xor c.or c.and c.j c.beqz c.bnez | c.slli c.lwsp c.jr c.mv c.ebreak c.jalr c.add c.swsp
// - Ma lenh danh rieng (reserved) va lenh so thuc (c.flw, c.fld, c.fsw, c.fsd, c.flwsp ...) -> illegal = 1 va
//   out = 32'h0000_0000 (cung la lenh khong hop le voi bo giai ma 32 bit). Gom: c.addi4spn voi nzuimm = 0,
//   c.addi16sp / c.lui voi nzimm = 0, c.lwsp voi rd = 0, c.jr voi rs1 = 0, shamt[5] = 1 (chi co o RV64),
//   c.subw/c.addw (RV64), va 16'h0000 (c.illegal).
// - Lenh HINT (vd. c.li x0, c.mv x0, c.slli voi shamt = 0) duoc giai nen binh thuong, thanh lenh ghi x0.
// - in[1:0] = 2'b11 la lenh 32 bit: out = in, illegal = 0 (bo giai ma 32 bit tu xu ly).
// Kiem chung: rvc/check_decompress.py so ca 49.152 ma lenh 16 bit voi GNU objdump.
module rv32c_decompress (
    input  wire [31:0] in,
    output reg  [31:0] out,
    output reg         illegal
);
    wire [15:0] c = in[15:0];
    wire [2:0]  f3  = c[15:13];
    wire [4:0]  rd  = c[11:7];             // rd / rs1 day du
    wire [4:0]  rs2 = c[6:2];
    wire [4:0]  rdp  = {2'b01, c[4:2]};    // rd' / rs2' (x8-x15)
    wire [4:0]  rs1p = {2'b01, c[9:7]};    // rs1' / rd'

    // ---- truong immediate cua tung dang ----
    wire [9:0]  nzuimm_4spn = {c[10:7], c[12:11], c[5], c[6], 2'b00};          // c.addi4spn
    wire [6:0]  uimm_lw     = {c[5], c[12:10], c[6], 2'b00};                     // c.lw / c.sw
    wire [5:0]  imm6        = {c[12], c[6:2]};                                   // c.addi c.li c.andi, shamt
    wire [11:0] imm_j       = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};  // c.j / c.jal
    wire [9:0]  nzimm_16sp  = {c[12], c[4:3], c[5], c[2], c[6], 4'b0000};        // c.addi16sp
    wire [8:0]  imm_b       = {c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};     // c.beqz / c.bnez
    wire [7:0]  uimm_lwsp   = {c[3:2], c[12], c[6:4], 2'b00};
    wire [7:0]  uimm_swsp   = {c[8:7], c[12:9], 2'b00};

    // ---- ma hoa lenh 32 bit ----
    function [31:0] enc_i(input [11:0] imm, input [4:0] rs1, input [2:0] fn3, input [4:0] rdx, input [6:0] op);
        enc_i = {imm, rs1, fn3, rdx, op};
    endfunction
    function [31:0] enc_s(input [11:0] imm, input [4:0] rs2x, input [4:0] rs1, input [2:0] fn3);
        enc_s = {imm[11:5], rs2x, rs1, fn3, imm[4:0], 7'b0100011};
    endfunction
    function [31:0] enc_r(input [6:0] fn7, input [4:0] rs2x, input [4:0] rs1, input [2:0] fn3, input [4:0] rdx);
        enc_r = {fn7, rs2x, rs1, fn3, rdx, 7'b0110011};
    endfunction
    function [31:0] enc_b(input [12:0] imm, input [4:0] rs1, input [2:0] fn3);   // so voi x0
        enc_b = {imm[12], imm[10:5], 5'd0, rs1, fn3, imm[4:1], imm[11], 7'b1100011};
    endfunction
    function [31:0] enc_j(input [20:0] imm, input [4:0] rdx);
        enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rdx, 7'b1101111};
    endfunction

    localparam OP_IMM = 7'b0010011, LOAD = 7'b0000011, JALR = 7'b1100111, LUI = 7'b0110111;

    always @* begin
        out     = 32'h0000_0000;
        illegal = 1'b0;
        case (c[1:0])
            // ---------------- quadrant 0 ----------------
            2'b00: case (f3)
                3'b000: begin                                                    // c.addi4spn
                    if (nzuimm_4spn == 10'd0) illegal = 1'b1;
                    else out = enc_i({2'b00, nzuimm_4spn}, 5'd2, 3'b000, rdp, OP_IMM);
                end
                3'b010: out = enc_i({5'd0, uimm_lw}, rs1p, 3'b010, rdp, LOAD);   // c.lw
                3'b110: out = enc_s({5'd0, uimm_lw}, rdp, rs1p, 3'b010);         // c.sw
                default: illegal = 1'b1;                                         // so thuc / danh rieng
            endcase

            // ---------------- quadrant 1 ----------------
            2'b01: case (f3)
                3'b000: out = enc_i({{6{imm6[5]}}, imm6}, rd, 3'b000, rd, OP_IMM);   // c.addi / c.nop
                3'b001: out = enc_j({{9{imm_j[11]}}, imm_j}, 5'd1);                  // c.jal (RV32)
                3'b010: out = enc_i({{6{imm6[5]}}, imm6}, 5'd0, 3'b000, rd, OP_IMM); // c.li
                3'b011: begin
                    if (rd == 5'd2) begin                                            // c.addi16sp
                        if (nzimm_16sp == 10'd0) illegal = 1'b1;
                        else out = enc_i({{2{nzimm_16sp[9]}}, nzimm_16sp}, 5'd2, 3'b000, 5'd2, OP_IMM);
                    end else begin                                                   // c.lui
                        if (imm6 == 6'd0) illegal = 1'b1;
                        else out = {{14{imm6[5]}}, imm6, rd, LUI};
                    end
                end
                3'b100: case (c[11:10])
                    2'b00, 2'b01: begin                                              // c.srli / c.srai
                        if (c[12]) illegal = 1'b1;                                   // shamt[5] = 1: chi RV64
                        else out = enc_i({1'b0, c[10], 5'b00000, c[6:2]}, rs1p, 3'b101, rs1p, OP_IMM);
                    end
                    2'b10: out = enc_i({{6{imm6[5]}}, imm6}, rs1p, 3'b111, rs1p, OP_IMM);   // c.andi
                    2'b11: begin
                        if (c[12]) illegal = 1'b1;                                   // c.subw / c.addw (RV64)
                        else case (c[6:5])
                            2'b00: out = enc_r(7'b0100000, rdp, rs1p, 3'b000, rs1p);   // c.sub
                            2'b01: out = enc_r(7'b0000000, rdp, rs1p, 3'b100, rs1p);   // c.xor
                            2'b10: out = enc_r(7'b0000000, rdp, rs1p, 3'b110, rs1p);   // c.or
                            2'b11: out = enc_r(7'b0000000, rdp, rs1p, 3'b111, rs1p);   // c.and
                        endcase
                    end
                endcase
                3'b101: out = enc_j({{9{imm_j[11]}}, imm_j}, 5'd0);                  // c.j
                3'b110: out = enc_b({{4{imm_b[8]}}, imm_b}, rs1p, 3'b000);           // c.beqz
                3'b111: out = enc_b({{4{imm_b[8]}}, imm_b}, rs1p, 3'b001);           // c.bnez
            endcase

            // ---------------- quadrant 2 ----------------
            2'b10: case (f3)
                3'b000: begin                                                        // c.slli
                    if (c[12]) illegal = 1'b1;
                    else out = enc_i({7'b0000000, c[6:2]}, rd, 3'b001, rd, OP_IMM);
                end
                3'b010: begin                                                        // c.lwsp
                    if (rd == 5'd0) illegal = 1'b1;
                    else out = enc_i({4'd0, uimm_lwsp}, 5'd2, 3'b010, rd, LOAD);
                end
                3'b100: begin
                    if (!c[12]) begin
                        if (rs2 == 5'd0) begin                                       // c.jr
                            if (rd == 5'd0) illegal = 1'b1;
                            else out = enc_i(12'd0, rd, 3'b000, 5'd0, JALR);
                        end else out = enc_r(7'b0000000, rs2, 5'd0, 3'b000, rd);     // c.mv
                    end else begin
                        if (rs2 == 5'd0) begin
                            if (rd == 5'd0) out = 32'h0010_0073;                     // c.ebreak
                            else out = enc_i(12'd0, rd, 3'b000, 5'd1, JALR);         // c.jalr
                        end else out = enc_r(7'b0000000, rs2, rd, 3'b000, rd);       // c.add
                    end
                end
                3'b110: out = enc_s({4'd0, uimm_swsp}, rs2, 5'd2, 3'b010);           // c.swsp
                default: illegal = 1'b1;                                             // so thuc
            endcase

            // ---------------- lenh 32 bit ----------------
            default: out = in;
        endcase
        if (illegal) out = 32'h0000_0000;
    end
endmodule
