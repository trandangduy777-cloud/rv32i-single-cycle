// Kiem tra rv32_mul_csa: tich = sum + carry (lay 2W bit) phai bang $signed(a) * $signed(b).
// -DW=<bit>. W <= 10: thu het moi cap (a, b); W lon: cac gia tri bien (0, +-1, lon nhat, nho nhat, xen ke bit, mot bit
// 1, mot bit 0) ghep voi nhau, cong them +n=<so cap ngau nhien>.
// In "[MUL] PASS ..." hoac "[MUL] FAIL ..." (cap dau tien sai).
`timescale 1ns/1ps
`ifndef W
`define W 33
`endif
module tb_mul;
    localparam W = `W;
    reg  [W-1:0]   a, b;
    wire [2*W-1:0] s, c;
    rv32_mul_csa #(.W(W)) dut (.a(a), .b(b), .sum(s), .carry(c));

    reg  [2*W-1:0] got, exp;
    integer        n_chk = 0, nr, i, j, seed;
    reg  [W-1:0]   corner [0:63];
    integer        nc;

    task chk;
        begin
            #1;
            got = s + c;
            exp = $signed(a) * $signed(b);
            n_chk = n_chk + 1;
            if (got !== exp) begin
                $display("[MUL] FAIL W=%0d: a=%h b=%h tich=%h, dung la %h", W, a, b, got, exp);
                $finish;
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("n=%d", nr)) nr = 200000;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (W <= 10) begin
            for (i = 0; i < (1 << W); i = i + 1)
                for (j = 0; j < (1 << W); j = j + 1) begin
                    a = i; b = j; chk;
                end
        end else begin
            nc = 0;
            corner[nc] = 0; nc = nc + 1;
            corner[nc] = 1; nc = nc + 1;
            corner[nc] = {W{1'b1}}; nc = nc + 1;                     // -1
            corner[nc] = {1'b0, {(W-1){1'b1}}}; nc = nc + 1;         // lon nhat
            corner[nc] = {1'b1, {(W-1){1'b0}}}; nc = nc + 1;         // nho nhat
            corner[nc] = {1'b1, {(W-1){1'b0}}} + 1; nc = nc + 1;
            for (i = 0; i < W; i = i + 1) begin corner[nc] = {{(W-1){1'b0}}, 1'b1} << i; nc = nc + 1; end
            for (i = 0; i < W; i = i + 3) begin corner[nc] = ~({{(W-1){1'b0}}, 1'b1} << i); nc = nc + 1; end
            nc = (nc > 62) ? 62 : nc;
            corner[nc] = {(W+1)/2{2'b01}}; corner[nc+1] = {(W+1)/2{2'b10}}; nc = nc + 2;
            for (i = 0; i < nc; i = i + 1)
                for (j = 0; j < nc; j = j + 1) begin
                    a = corner[i]; b = corner[j]; chk;
                end
            for (i = 0; i < nr; i = i + 1) begin
                a = {$random(seed), $random(seed)};
                b = {$random(seed), $random(seed)};
                // mot phan ba so cap: lam toan hang nho hoac gan bien de cac nhom Booth dac biet xuat hien nhieu
                if (i % 3 == 1) a = a >>> ($random(seed) & 31);
                if (i % 3 == 2) b = {W{b[W-1]}} ^ (b >> ($random(seed) & 31));
                chk;
            end
        end
        $display("[MUL] PASS W=%0d: %0d cap", W, n_chk);
        $finish;
    end
endmodule
