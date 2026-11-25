// Chi dung cho tong hop dien tich SoC AXI4: ROM va RAM (axi_mem) la mang flip-flop 16 KB moi cai (chua co macro SRAM) nen dat o dang blackbox. Cung cong va tham so voi soc/axi/axi_mem.v.
(* blackbox *) module axi_mem #(parameter WORDS = 4096, parameter ROM = 0, parameter IDW = 6, parameter RLAT = 0, parameter STALL = 0, parameter BDLY = 0, parameter [15:0] SEED = 16'hACE1, parameter INIT_FILE = "") (
    input  wire clk, input wire rst_n,
    input  wire [IDW-1:0] awid, input wire [31:0] awaddr, input wire [7:0] awlen, input wire [2:0] awsize, input wire [1:0] awburst, input wire awvalid, output wire awready,
    input  wire [31:0] wdata, input wire [3:0] wstrb, input wire wlast, input wire wvalid, output wire wready,
    output wire [IDW-1:0] bid, output wire [1:0] bresp, output wire bvalid, input wire bready,
    input  wire [IDW-1:0] arid, input wire [31:0] araddr, input wire [7:0] arlen, input wire [2:0] arsize, input wire [1:0] arburst, input wire arvalid, output wire arready,
    output wire [IDW-1:0] rid, output wire [31:0] rdata, output wire [1:0] rresp, output wire rlast, output wire rvalid, input wire rready);
endmodule
