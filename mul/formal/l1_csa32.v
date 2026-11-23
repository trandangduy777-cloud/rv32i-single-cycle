// Bo de 1: bo cong 3:2 giu tong: s + c = x + y + z (mod 2^P), voi moi x, y, z.
module l1_csa32 #(parameter P = 66) (input [P-1:0] x, y, z);
    wire [P-1:0] s, c;
    rv32_csa32 #(.P(P)) dut (.x(x), .y(y), .z(z), .s(s), .c(c));
    always @* assert (s + c == x + y + z);
endmodule
