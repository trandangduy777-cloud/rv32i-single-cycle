// Ghep chung minh bo nhan/chia vao pipeline: ALTOPS chi duoc doi GIA TRI ket qua, khong doi THOI GIAN (done -> ex_stall).
// Ba bo rv32m cung cau hinh voi pipeline (PREP=1, STEPS=2, MUL_LAT=2), cung req/funct3 va cung reset:
//   u_r1 (RTL that, toan hang a1,b1), u_r2 (RTL that, toan hang a2,b2 tuy y KHAC) va u_alt (ban ALTOPS, toan hang a1,b1).
// Khang dinh: done cua ca ba luon bang nhau  =>  (1) thoi gian cua RTL that khong phu thuoc gia tri toan hang (ke ca chia cho 0,
// so am, INT_MIN / -1), (2) ban ALTOPS co dung thoi gian cua RTL that, nen cac chung minh riscv-formal chay voi ALTOPS
// ap dung cho dung lich stall cua RTL that. Gia tri ket qua cua RTL that duoc chung minh rieng (mul/formal, formal/div).
module stitch_harness (
    input        clk,
    input        rst_n,
    input        req,
    input  [2:0] funct3,
    input [31:0] a1, b1, a2, b2
);
    wire d_r1, d_r2, d_alt;
    wire [31:0] y_r1, y_r2, y_alt;
    rv32m     #(.PREP(1), .STEPS(2), .MUL_LAT(2)) u_r1  (.clk(clk), .rst_n(rst_n), .req(req), .funct3(funct3), .a(a1), .b(b1), .done(d_r1),  .result(y_r1));
    rv32m     #(.PREP(1), .STEPS(2), .MUL_LAT(2)) u_r2  (.clk(clk), .rst_n(rst_n), .req(req), .funct3(funct3), .a(a2), .b(b2), .done(d_r2),  .result(y_r2));
    rv32m_alt #(.PREP(1), .STEPS(2), .MUL_LAT(2)) u_alt (.clk(clk), .rst_n(rst_n), .req(req), .funct3(funct3), .a(a1), .b(b1), .done(d_alt), .result(y_alt));

    reg init = 1'b0;
    always @(posedge clk) init <= 1'b1;
    always @* if (!init) assume (!rst_n);              // bat dau tu reset, nhu phan cung
    // req giu khong doi den khi done (pipeline giu idex_mext trong luc stall) va lenh moi chi bat dau khi lenh truoc xong
    reg req_q = 1'b0; reg [2:0] f_q = 3'd0; reg d_q = 1'b0;
    always @(posedge clk) begin req_q <= req; f_q <= funct3; d_q <= d_r1; end
    always @* if (init && rst_n && req_q && !d_q) assume (req && funct3 == f_q);
    always @* if (init && rst_n) begin
        assert (d_r1 == d_r2);
        assert (d_r1 == d_alt);
    end
endmodule
