// Bus / interconnect anh xa bo nho cua SoC: giai ma dia chi cong du lieu cua loi, chon du lieu doc, phat hien truy cap sai.
// Ban do dia chi (xem README):
//   0x0000_0000  ROM    16 KB (chi doc; lenh va du lieu)        0x1000_0000  RAM    16 KB (du lieu va lenh)
//   0x0200_0000  CLINT  32 B (rv32_mtimer)                      0x2000_0000  UART   4 KB
//   0x2000_1000  GPIO   4 KB                                    0x2000_2000  SYSCON 4 KB
//   0x0C00_0000  PLIC   4 MB (soc_plic)
// Doc ngoai vung anh xa tra 0; ghi ngoai vung bi bo qua. Ghi vao ROM cung bi bo qua. Ca hai bao qua bus_err (SYSCON dem).
// Cong lenh (fetch) doc duoc ROM va RAM; fetch ngoai hai vung do tra 0 (lenh 16 bit 0x0000 la lenh khong hop le, loi bat trap).
module soc_bus #(
    parameter ROM_AW = 14,       // log2 so byte cua ROM
    parameter RAM_AW = 14,
    parameter CLINT_STD = 0      // 1: CLINT theo bo cuc chuan (cua so 64 KB: msip 0x0000, mtimecmp 0x4000, mtime 0xBFF8), dung cho OpenSBI / Linux
) (
    input  wire [31:0] daddr,
    input  wire        dwe,
    input  wire        dre,
    output wire        sel_rom,
    output wire        sel_ram,
    output wire        sel_clint,
    output wire        clint_hit,       // truy cap trung mot thanh ghi cua CLINT (bo cuc chuan: dia chi trong cua so ma khong phai thanh ghi thi khong trung)
    output wire [4:2]  clint_ra,        // chi so thanh ghi cua rv32_mtimer (0 mtime lo, 1 mtime hi, 2 mtimecmp lo, 3 mtimecmp hi, 4 msip)
    output wire        sel_uart,
    output wire        sel_gpio,
    output wire        sel_sys,
    output wire        sel_plic,
    input  wire [31:0] rom_rd,
    input  wire [31:0] ram_rd,
    input  wire [31:0] clint_rd,
    input  wire [31:0] uart_rd,
    input  wire [31:0] gpio_rd,
    input  wire [31:0] sys_rd,
    input  wire [31:0] plic_rd,
    output wire [31:0] rdata,
    output wire        bus_err,
    input  wire [31:0] iaddr,
    output wire        i_sel_rom,
    output wire        i_sel_ram
);
    localparam [31:0] RAM_BASE = 32'h1000_0000;

    assign sel_rom   = (daddr[31:ROM_AW] == {(32-ROM_AW){1'b0}});
    assign sel_ram   = (daddr[31:RAM_AW] == RAM_BASE[31:RAM_AW]);
    // CLINT: bo cuc rieng (32 byte, mtime o 0x0) hoac bo cuc chuan 64 KB (CLINT_STD = 1)
    assign sel_clint = (CLINT_STD != 0) ? (daddr[31:16] == 16'h0200) : (daddr[31:5] == 27'h0100000);        // 0x0200_0000
    wire [13:0] c_off = daddr[15:2];
    wire std_msip = (c_off == 14'h0000), std_cl = (c_off == 14'h1000), std_ch = (c_off == 14'h1001),
         std_tl = (c_off == 14'h2FFE),   std_th = (c_off == 14'h2FFF);
    assign clint_hit = (CLINT_STD != 0) ? (sel_clint & (std_msip | std_cl | std_ch | std_tl | std_th)) : sel_clint;
    assign clint_ra  = (CLINT_STD == 0) ? daddr[4:2] : std_msip ? 3'd4 : std_cl ? 3'd2 : std_ch ? 3'd3 : std_tl ? 3'd0 : 3'd1;
    assign sel_uart  = (daddr[31:12] == 20'h20000);
    assign sel_gpio  = (daddr[31:12] == 20'h20001);
    assign sel_sys   = (daddr[31:12] == 20'h20002);
    assign sel_plic  = (daddr[31:22] == 10'h030);            // 0x0C00_0000, 4 MB

    assign rdata = ({32{sel_rom}}   & rom_rd)   | ({32{sel_ram}}  & ram_rd)  | ({32{clint_hit}} & clint_rd) |
                   ({32{sel_uart}}  & uart_rd)  | ({32{sel_gpio}} & gpio_rd) | ({32{sel_sys}}   & sys_rd) | ({32{sel_plic}} & plic_rd);

    wire any_sel = sel_rom | sel_ram | sel_clint | sel_uart | sel_gpio | sel_sys | sel_plic;
    assign bus_err = ((dre | dwe) & ~any_sel) | (dwe & sel_rom);

    assign i_sel_rom = (iaddr[31:ROM_AW] == {(32-ROM_AW){1'b0}});
    assign i_sel_ram = (iaddr[31:RAM_AW] == RAM_BASE[31:RAM_AW]);
endmodule
