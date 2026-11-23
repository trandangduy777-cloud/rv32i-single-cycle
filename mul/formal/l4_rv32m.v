// Bo de 4: phan noi bo nhan song song vao rv32m (chon dau cho MULH / MULHSU / MULHU, chon nua ket qua, duong 1 va 2 chu ky).
// rv32_mul_csa duoc thay bang mo hinh: sum + carry = a * b co dau (2W bit), carry tuy y. Day dung la dinh ly da chung minh
// (bo de 1-3 + algebra.py), va mo hinh chua moi cach chia sum / carry, nen ket qua dung cho bo nhan that.
// Kich ban: chu ky 0 reset, chu ky 1 co lenh nhan (funct3, a, b tuy y) khi bo nhan/chia o IDLE. Moi thanh ghi khac
// (p, m, ...) khong duoc reset deu tuy y trong solver. Kiem: LAT = 1 xong ngay chu ky 1; LAT = 2 chua xong o chu ky 1,
// xong o chu ky 2 voi ket qua dung du dau vao chu ky 2 tuy y. Ket qua phai bang dac ta RISC-V (xem ham spec).
module rv32_mul_csa #(parameter W = 33) (input [W-1:0] a, input [W-1:0] b, output [2*W-1:0] sum, output [2*W-1:0] carry);
    (* anyseq *) wire [2*W-1:0] cf;
    wire [2*W-1:0] pr = {{W{a[W-1]}}, a} * {{W{b[W-1]}}, b};
    assign carry = cf;
    assign sum   = pr - cf;
endmodule

module l4_rv32m #(parameter LAT = 1) (input clk, input req, input [2:0] funct3, input [31:0] a, input [31:0] b);
    reg [2:0] step = 3'd0;
    always @(posedge clk) if (step != 3'd7) step <= step + 3'd1;
    wire        done;
    wire [31:0] result;
    rv32m #(.PREP(1), .STEPS(2), .MUL_LAT(LAT)) dut (.clk(clk), .rst_n(step != 3'd0), .req(req), .funct3(funct3),
                                                      .a(a), .b(b), .done(done), .result(result));
    // Dac ta viet bang tich 66 bit cua toan hang mo rong theo dung ISA (co dau voi MULH / MULHSU, khong dau con lai):
    // 32 / 64 bit thap cua tich mo rong rong hon bang tich 32 / 64 bit (dong cau vanh mod 2^k), nen day dung la dac ta
    // MUL = (x*y)[31:0], MULH = (sext x * sext y)[63:32], MULHSU = (sext x * zext y)[63:32], MULHU = (zext x * zext y)[63:32].
    // Viet cung kich thuoc voi mo hinh giup solver khong phai bit-blast phep nhan; dieu duoc kiem la chon dau, chon nua
    // ket qua va thoi diem (done).
    function [31:0] spec(input [2:0] f, input [31:0] x, input [31:0] y);
        reg        xs, ys;
        reg [65:0] pr;
        begin
            xs = (f == 3'b001 || f == 3'b010) && x[31];          // MULH, MULHSU: x co dau
            ys = (f == 3'b001) && y[31];                         // MULH: y co dau
            pr = {{34{xs}}, x} * {{34{ys}}, y};
            spec = (f == 3'b000) ? pr[31:0] : pr[63:32];
        end
    endfunction
    reg [2:0]  f1;
    reg [31:0] a1, b1;
    always @(posedge clk) if (step == 3'd1) begin f1 <= funct3; a1 <= a; b1 <= b; end
    always @* begin
        if (step == 3'd1) assume (req && !funct3[2]);
        if (LAT == 1 && step == 3'd1) assert (done && result == spec(funct3, a, b));
        if (LAT == 2 && step == 3'd1) assert (!done);
        if (LAT == 2 && step == 3'd2) assert (done && result == spec(f1, a1, b1));
    end
endmodule
