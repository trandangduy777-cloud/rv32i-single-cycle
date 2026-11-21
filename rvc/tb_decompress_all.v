// In ket qua giai nen cua ca 65.536 gia tri 16 bit (dung cho check_decompress.py)
module tb_decompress_all;
    reg  [31:0] in;
    wire [31:0] out;
    wire        illegal;
    rv32c_decompress u (.in(in), .out(out), .illegal(illegal));
    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1) begin
            in = {16'h0000, i[15:0]};
            #1 $display("%04x %08x %0d", i[15:0], out, illegal);
        end
        $finish;
    end
endmodule
