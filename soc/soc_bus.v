// Bus / interconnect anh xa bo nho cua SoC: giai ma dia chi cong du lieu cua loi, chon du lieu doc, phat hien truy cap sai.
// Ban do dia chi (xem README):
//   0x0000_0000  ROM    16 KB (chi doc; lenh va du lieu)        0x1000_0000  RAM    16 KB (du lieu va lenh)
//   0x0200_0000  CLINT  32 B (rv32_mtimer)                      0x2000_0000  UART   4 KB
//   0x2000_1000  GPIO   4 KB                                    0x2000_2000  SYSCON 4 KB
// Doc ngoai vung anh xa tra 0; ghi ngoai vung bi bo qua. Ghi vao ROM cung bi bo qua. Ca hai bao qua bus_err (SYSCON dem).
// Cong lenh (fetch) doc duoc ROM va RAM; fetch ngoai hai vung do tra 0 (lenh 16 bit 0x0000 la lenh khong hop le, loi bat trap).
module soc_bus #(
    parameter ROM_AW = 14,       // log2 so byte cua ROM
    parameter RAM_AW = 14
) (
    input  wire [31:0] daddr,
    input  wire        dwe,
    input  wire        dre,
    output wire        sel_rom,
    output wire        sel_ram,
    output wire        sel_clint,
    output wire        sel_uart,
    output wire        sel_gpio,
    output wire        sel_sys,
    input  wire [31:0] rom_rd,
    input  wire [31:0] ram_rd,
    input  wire [31:0] clint_rd,
    input  wire [31:0] uart_rd,
    input  wire [31:0] gpio_rd,
    input  wire [31:0] sys_rd,
    output wire [31:0] rdata,
    output wire        bus_err,
    input  wire [31:0] iaddr,
    output wire        i_sel_rom,
    output wire        i_sel_ram
);
    localparam [31:0] RAM_BASE = 32'h1000_0000;

    assign sel_rom   = (daddr[31:ROM_AW] == {(32-ROM_AW){1'b0}});
    assign sel_ram   = (daddr[31:RAM_AW] == RAM_BASE[31:RAM_AW]);
    assign sel_clint = (daddr[31:5]  == 27'h0100000);        // 0x0200_0000, 32 byte
    assign sel_uart  = (daddr[31:12] == 20'h20000);
    assign sel_gpio  = (daddr[31:12] == 20'h20001);
    assign sel_sys   = (daddr[31:12] == 20'h20002);

    assign rdata = ({32{sel_rom}}   & rom_rd)   | ({32{sel_ram}}  & ram_rd)  | ({32{sel_clint}} & clint_rd) |
                   ({32{sel_uart}}  & uart_rd)  | ({32{sel_gpio}} & gpio_rd) | ({32{sel_sys}}   & sys_rd);

    wire any_sel = sel_rom | sel_ram | sel_clint | sel_uart | sel_gpio | sel_sys;
    assign bus_err = ((dre | dwe) & ~any_sel) | (dwe & sel_rom);

    assign i_sel_rom = (iaddr[31:ROM_AW] == {(32-ROM_AW){1'b0}});
    assign i_sel_ram = (iaddr[31:RAM_AW] == RAM_BASE[31:RAM_AW]);
endmodule
