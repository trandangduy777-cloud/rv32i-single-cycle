// Dinh cho flow: pipeline RV32IM bat lenh nen C (ENABLE_C = 1), bo nho to hop ben ngoai nhu ban flow cu.
// Muc dich: do anh huong cua bo giai nen lenh C (nam o IF) len dien tich va duong toi han.
module rv32imc_top (
    input  wire        clk,
    input  wire        rst_n,
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    output wire        dmem_we,
    output wire        dmem_re,
    input  wire [31:0] dmem_rdata,
    input  wire        irq_timer,
    input  wire        irq_soft,
    input  wire        irq_ext,
    output wire        icache_flush
);
    rv32im_pipeline #(.ENABLE_C(1)) u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data), .imem_ready(1'b1),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_re(dmem_re), .dmem_rdata(dmem_rdata), .dmem_ready(1'b1),
        .icache_flush(icache_flush),
        .irq_timer(irq_timer), .irq_soft(irq_soft), .irq_ext(irq_ext)
    );
endmodule
