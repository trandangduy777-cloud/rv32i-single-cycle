// RAM cua SoC: doc to hop, ghi dong bo theo tung byte (wstrb). Cong lenh (i_addr chia het cho 2, tra 32 bit, lenh nen vat qua ranh gioi tu duoc)
// cho phep chay chuong trinh nap vao RAM luc chay; sau khi ghi lenh phai co FENCE.I (loi nap lai tu lenh ke tiep).
module soc_ram #(
    parameter WORDS = 4096
) (
    input  wire        clk,
    input  wire        sel,
    input  wire [31:0] addr,
    input  wire        we,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    input  wire [31:0] i_addr,
    output wire [31:0] i_data
);
    localparam AW = $clog2(WORDS);
    reg [31:0] mem [0:WORDS-1];

    integer k;
    initial for (k = 0; k < WORDS; k = k + 1) mem[k] = 32'd0;

    wire [AW-1:0] w = addr[AW+1:2];
    always @(posedge clk) begin
        if (sel & we) begin
            if (wstrb[0]) mem[w][7:0]   <= wdata[7:0];
            if (wstrb[1]) mem[w][15:8]  <= wdata[15:8];
            if (wstrb[2]) mem[w][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[w][31:24] <= wdata[31:24];
        end
    end
    assign rdata = mem[w];
    wire [AW-1:0] iw0 = i_addr[AW+1:2];
    wire [AW-1:0] iw1 = iw0 + {{(AW-1){1'b0}}, 1'b1};
    assign i_data = i_addr[1] ? {mem[iw1][15:0], mem[iw0][31:16]} : mem[iw0];
endmodule
