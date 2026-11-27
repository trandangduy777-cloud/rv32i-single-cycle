// Mo hinh hanh vi cua macro SRAM IHP SG13G2 theo GIAO DIEN GIA DINH cua rv32_ram.v (A_CLK, A_MEN, A_WEN, A_REN, A_ADDR, A_DIN, A_DLY, A_BM mat na theo bit,
// A_DOUT dang ky, cac chan A_BIST_* khong dung). Chi de kiem logic ghep cua rv32_ram (chon nua tu, mat na, do tre) trong mo phong; KHONG phai mo hinh cua IHP:
// tren may co PDK, thay bang libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_*.v va doi chieu ten / do rong cong.
`define IHP_STUB(NAME, ROWS, AWID) \
module NAME (input A_CLK, input A_MEN, input A_WEN, input A_REN, input [AWID-1:0] A_ADDR, input [63:0] A_DIN, input A_DLY, input [63:0] A_BM, output reg [63:0] A_DOUT, \
             input A_BIST_CLK, input A_BIST_EN, input A_BIST_MEN, input A_BIST_WEN, input A_BIST_REN, input [AWID-1:0] A_BIST_ADDR, input [63:0] A_BIST_DIN, input [63:0] A_BIST_BM); \
    reg [63:0] mem [0:ROWS-1]; \
    always @(posedge A_CLK) if (A_MEN) begin \
        if (A_WEN) mem[A_ADDR] <= (mem[A_ADDR] & ~A_BM) | (A_DIN & A_BM); \
        else if (A_REN) A_DOUT <= mem[A_ADDR]; \
    end \
endmodule
`IHP_STUB(RM_IHPSG13_1P_256x64_c2_bm_bist, 256, 8)
`IHP_STUB(RM_IHPSG13_1P_512x64_c2_bm_bist, 512, 9)
`IHP_STUB(RM_IHPSG13_1P_1024x64_c2_bm_bist, 1024, 10)
`IHP_STUB(RM_IHPSG13_1P_2048x64_c2_bm_bist, 2048, 11)
