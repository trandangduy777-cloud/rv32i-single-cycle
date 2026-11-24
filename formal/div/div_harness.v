// Harness chung minh bo chia cua rv32m (cac assert nam trong rv32m, trong `ifdef RISCV_FORMAL_DIV): lenh chia tu chu ky 1
// sau reset, toan hang tuy y, req co the giu nguyen hoac tha tuy y, toan hang doi tuy y sau chu ky dau.
module div_harness #(parameter PREP = 1, parameter STEPS = 2) (input clk, input req, input [2:0] funct3, input [31:0] a, input [31:0] b);
    reg [5:0] step = 6'd0;
    always @(posedge clk) if (step != 6'd63) step <= step + 6'd1;
    wire        done;
    wire [31:0] result;
    rv32m #(.PREP(PREP), .STEPS(STEPS), .MUL_LAT(0)) dut (.clk(clk), .rst_n(step != 6'd0), .req(req), .funct3(funct3),
                                                            .a(a), .b(b), .done(done), .result(result));
    always @* begin
        if (step == 6'd1) assume (req && funct3[2]);      // lenh chia dau tien (DIV, DIVU, REM, REMU)
    end
endmodule
