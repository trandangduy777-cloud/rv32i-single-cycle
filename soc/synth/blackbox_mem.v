// Chi dung cho tong hop dien tich: ROM va RAM la mang flip-flop 16 KB moi cai (khong co macro SRAM), nen dat o dang blackbox de dien tich
// bao cao la cua loi + bus + ngoai vi. Cung cong va tham so voi soc_rom.v / soc_ram.v.
(* blackbox *) module soc_rom #(parameter WORDS = 4096, parameter INIT_FILE = "") (
    input  wire [31:0] i_addr, output wire [31:0] i_data, input  wire [31:0] d_addr, output wire [31:0] d_data);
endmodule
(* blackbox *) module soc_ram #(parameter WORDS = 4096) (
    input  wire clk, input  wire sel, input  wire [31:0] addr, input  wire we, input  wire [3:0] wstrb, input  wire [31:0] wdata, output wire [31:0] rdata, input wire [31:0] i_addr, output wire [31:0] i_data);
endmodule
