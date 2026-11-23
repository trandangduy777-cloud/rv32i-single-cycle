// Bo de 3: hang tich rieng cua rv32_booth_pp. Voi moi a, b (W bit co dau), A = a mo rong dau len P = 2W bit, va voi
// nhom I (tham so; script chay lan luot I = 0..N-1):
//   hang[I] + (bit 2I cua hang hieu chinh) = d_I * A * 4^I (mod 2^P),   d_I = -2*b[2I+1] + b[2I] + b[2I-1]
// (b[-1] = 0, b[k] = b[W-1] khi k >= W). d_I duoc tinh bang so hoc tu 3 bit cua b (khong chep bang chon cua RTL), roi
// d_I * A viet thanh 0 / A / 2A / -A / -2A theo gia tri cua d_I.
// Voi I = N (tham so CORR = 1): hang hieu chinh bang tong cac bit 2i (i < N) cua chinh no, khong co bit nao khac.
module l3_booth #(parameter W = 33, parameter I = 0, parameter CORR = 0) (input [W-1:0] a, input [W-1:0] b);
    localparam N = (W + 2) / 2;
    localparam P = 2 * W;
    wire [(N+1)*P-1:0] rows;
    rv32_booth_pp #(.W(W)) dut (.a(a), .b(b), .rows(rows));

    function bit_b(input integer k);
        bit_b = (k < 0) ? 1'b0 : (k < W) ? b[k] : b[W-1];
    endfunction

    wire [P-1:0]        A    = {{W{a[W-1]}}, a};
    wire [P-1:0]        corr = rows[N*P +: P];
    wire signed [3:0]   d    = -2 * $signed({3'b0, bit_b(2*I+1)}) + $signed({3'b0, bit_b(2*I)}) + $signed({3'b0, bit_b(2*I-1)});
    wire [P-1:0]        dA   = (d == 1) ? A : (d == 2) ? (A << 1) : (d == -1) ? (0 - A) : (d == -2) ? (0 - (A << 1)) : 0;
    wire [P-1:0]        one  = {{(P-1){1'b0}}, 1'b1};
    reg  [P-1:0]        mask, csum;
    integer i;
    always @* begin
        if (CORR) begin
            mask = 0; csum = 0;
            for (i = 0; i < N; i = i + 1) begin
                mask = mask | (one << (2*i));
                csum = csum + (corr & (one << (2*i)));
            end
            assert ((corr & ~mask) == 0);
            assert (corr == csum);
        end else begin
            assert (d >= -2 && d <= 2);
            assert (rows[I*P +: P] + (corr & (one << (2*I))) == dA << (2*I));
        end
    end
endmodule
