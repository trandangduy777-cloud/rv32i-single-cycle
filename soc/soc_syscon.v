// SYSCON: thanh ghi he thong nho (addr = offset[4:2]):
//   0x00 ID       R  0x52563C01 (RV, SoC, ban 1)    0x04 SCRATCH R/W 32 bit (kiem tra duong ghi/doc theo byte)
//   0x08 EXIT     W  ghi bat ky gia tri nao: chot exit_code, dat exit_valid (testbench / chan ngoai doc de dung chay). R: exit_code
//   0x0C BUSERR   R  so lan truy cap sai cua bus (doc ngoai vung, ghi ngoai vung hoac ghi ROM), bao hoa o 0xFFFF_FFFF; W: xoa ve 0
module soc_syscon (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sel,
    input  wire [4:2]  addr,
    input  wire        we,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        bus_err,
    output wire        exit_valid,
    output wire [31:0] exit_code
);
    reg [31:0] scratch, ecode, berr;
    reg        evalid;
    wire [31:0] wmask = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};
    wire wr = sel & we;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scratch <= 32'd0; ecode <= 32'd0; evalid <= 1'b0; berr <= 32'd0; end
        else begin
            if (wr && addr == 3'd1) scratch <= (scratch & ~wmask) | (wdata & wmask);
            if (wr && addr == 3'd2) begin ecode <= wdata; evalid <= 1'b1; end
            if (wr && addr == 3'd3) berr <= 32'd0;
            else if (bus_err && berr != 32'hFFFF_FFFF) berr <= berr + 32'd1;
        end
    end

    always @* begin
        case (addr)
            3'd0:    rdata = 32'h5256_3C01;
            3'd1:    rdata = scratch;
            3'd2:    rdata = ecode;
            3'd3:    rdata = berr;
            default: rdata = 32'd0;
        endcase
    end
    assign exit_valid = evalid;
    assign exit_code  = ecode;
endmodule
