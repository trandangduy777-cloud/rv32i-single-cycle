// Bo de 2: cay rv32_csa_tree giu tong cac hang: sum + carry = tong R hang (mod 2^P), voi moi gia tri cua cac hang.
// Bo cong 3:2 duoc thay bang mo hinh truu tuong csa_abs (doc de -overwrite rv32_csa32): c tuy y (anyseq), s = x + y + z - c.
// Mo hinh nay chua moi hanh vi thoa s + c = x + y + z, trong do co rv32_csa32 that (bo de 1), nen ket qua dung cho cay that.
// Bo de nay kiem phan noi day cua cay (moi hang vao dung mot bo cong hoac chuyen thang, khong mat, khong lap).
module rv32_csa32 #(parameter P = 66) (input [P-1:0] x, y, z, output [P-1:0] s, c);
    (* anyseq *) wire [P-1:0] cf;
    assign c = cf;
    assign s = x + y + z - cf;
endmodule

module l2_tree #(parameter R = 18, parameter P = 66) (input [R*P-1:0] rows);
    wire [P-1:0] sum, carry;
    rv32_csa_tree #(.R(R), .P(P)) dut (.rows(rows), .sum(sum), .carry(carry));
    reg [P-1:0] tot;
    integer i;
    always @* begin
        tot = 0;
        for (i = 0; i < R; i = i + 1) tot = tot + rows[i*P +: P];
        assert (sum + carry == tot);
    end
endmodule
