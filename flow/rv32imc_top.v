// Dinh cho flow: pipeline RV32IM bat lenh nen C (ENABLE_C = 1), bo nho to hop ben ngoai nhu ban flow cu.
// Muc dich: do anh huong cua bo giai nen lenh C (nam o IF) len dien tich va duong toi han.
// Cac tham so duoi day chuyen thang xuong rv32im_pipeline de LibreLane (SYNTH_PARAMETERS, chparam tren module dinh)
// chon cau hinh: mac dinh = cau hinh mac dinh cua pipeline (khong S/U, khong MMU, khong TAGE, khong Zb*).
module rv32imc_top #(
    parameter SU = 0, MMU = 0, TAGE = 0, MISALIGNED = 0,
    parameter ZBA = 0, ZBB = 0, ZBS = 0, ZBC = 0, ZICOND = 0,
    // phat doi: DUAL = 1 can ENABLE_C = 0, PMP_N = 0 va -DDUAL_FETCH (them cong imem_data2)
    parameter ENABLE_C = 1, DUAL = 0, PMP_N = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,
`ifdef DUAL_FETCH
    input  wire [31:0] imem_data2,
`endif
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
    rv32im_pipeline #(.ENABLE_C(ENABLE_C), .DUAL(DUAL), .PMP_N(PMP_N), .SU(SU), .MMU(MMU), .TAGE(TAGE), .MISALIGNED(MISALIGNED),
                      .ZBA(ZBA), .ZBB(ZBB), .ZBS(ZBS), .ZBC(ZBC), .ZICOND(ZICOND)) u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data), .imem_ready(1'b1),
`ifdef DUAL_FETCH
        .imem_data2(imem_data2),
`endif
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_re(dmem_re), .dmem_rdata(dmem_rdata), .dmem_ready(1'b1),
        .icache_flush(icache_flush),
        .irq_timer(irq_timer), .irq_soft(irq_soft), .irq_ext(irq_ext)
    );
endmodule
