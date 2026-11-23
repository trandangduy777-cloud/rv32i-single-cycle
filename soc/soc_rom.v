// ROM cua SoC: doc to hop, 2 cong doc. Cong lenh nhan dia chi chia het cho 2 va tra 32 bit bat dau tu do (lenh nen C co the vat qua ranh gioi tu),
// cong du lieu doc 1 tu. Khong co cong ghi: noi dung nap luc khoi tao ($readmemh tu INIT_FILE, hoac testbench nap vao `mem`).
module soc_rom #(
    parameter WORDS     = 4096,
    parameter INIT_FILE = ""
) (
    input  wire [31:0] i_addr,
    output wire [31:0] i_data,
    input  wire [31:0] d_addr,
    output wire [31:0] d_data
);
    localparam AW = $clog2(WORDS);
    reg [31:0] mem [0:WORDS-1];

    integer k;
    initial begin
        for (k = 0; k < WORDS; k = k + 1) mem[k] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    wire [AW-1:0] iw0 = i_addr[AW+1:2];
    wire [AW-1:0] iw1 = iw0 + {{(AW-1){1'b0}}, 1'b1};
    assign i_data = i_addr[1] ? {mem[iw1][15:0], mem[iw0][31:16]} : mem[iw0];
    assign d_data = mem[d_addr[AW+1:2]];
endmodule
