// RAM cua SoC: doc to hop, ghi dong bo theo tung byte (wstrb).
module soc_ram #(
    parameter WORDS = 4096
) (
    input  wire        clk,
    input  wire        sel,
    input  wire [31:0] addr,
    input  wire        we,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output wire [31:0] rdata
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
endmodule
