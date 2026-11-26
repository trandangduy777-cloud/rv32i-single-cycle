// SVA cho rv32im_pipeline (bind, khong sua RTL). Ten assertion bat dau bang PL_.
module sva_pipeline #(parameter IRQ_MAX = 96) (
    input logic clk, rst_n,
    input logic [31:0] pc, redirect_pc_q, trap_pc,
    input logic rt_trap,
    input logic redirect_q, frz, ifid_valid, idex_valid_r, idex_valid, exmem_valid, exmem_rd_we, exmem_load, exmem_store, exmem_fence,
    input logic trap_ex, irq_take, irq_any, wb_we, wb_commit, mstatus_mie, trap_q,
    input logic [4:0] memwb_rd, rs1, rs2,
    input logic memwb_valid, memwb_rd_we, id_fa_mem, id_fa_wb, id_fb_mem, id_fb_wb
);
    // ---- x0 khong bao gio bi ghi ----
    PL_no_wb_x0: assert property (@(posedge clk) disable iff (!rst_n) (memwb_valid && memwb_rd_we && memwb_rd == 5'd0) |-> !wb_we)
        else $error("SVA PL_no_wb_x0: lenh ghi x0 van duoc ghi vao tep thanh ghi o WB");
    PL_no_fwd_x0_a: assert property (@(posedge clk) disable iff (!rst_n) (id_fa_mem || id_fa_wb) |-> rs1 != 5'd0)
        else $error("SVA PL_no_fwd_x0_a: forward cho toan hang x0 (rs1)");
    PL_no_fwd_x0_b: assert property (@(posedge clk) disable iff (!rst_n) (id_fb_mem || id_fb_wb) |-> rs2 != 5'd0)
        else $error("SVA PL_no_fwd_x0_b: forward cho toan hang x0 (rs2)");

    // ---- redirect huy dung lenh: ngay sau khi redirect duoc ap, lenh o IF/ID va EX bi huy, pc nhay dung
    //      (trap: dich la trap_pc, tinh tu thanh ghi rt_* mot chu ky sau trap_ex, khong qua redirect_pc_q) ----
    PL_redirect_pc: assert property (@(posedge clk) disable iff (!rst_n) (redirect_q && !frz) |=> pc == $past(rt_trap ? trap_pc : redirect_pc_q))
        else $error("SVA PL_redirect_pc: pc khong nhay toi dich redirect");
    PL_redirect_kill_ifid: assert property (@(posedge clk) disable iff (!rst_n) (redirect_q && !frz) |=> !ifid_valid)
        else $error("SVA PL_redirect_kill_ifid: lenh o IF/ID nham duong khong bi huy");
    PL_redirect_kill_ex: assert property (@(posedge clk) disable iff (!rst_n) (redirect_q && !frz) |=> (!exmem_valid && !idex_valid_r))
        else $error("SVA PL_redirect_kill_ex: lenh o EX nham duong khong bi huy (di xuong MEM hoac nam lai o ID/EX)");
    PL_redirect_no_valid: assert property (@(posedge clk) disable iff (!rst_n) redirect_q |-> !idex_valid)
        else $error("SVA PL_redirect_no_valid: idex_valid khi redirect_q");

    // ---- lenh gay trap / bi ngat khong duoc ghi thanh ghi, bo nho, khong sinh FENCE ----
    PL_trap_no_side_effect: assert property (@(posedge clk) disable iff (!rst_n)
        (trap_ex && !frz) |=> (!exmem_rd_we && !exmem_store && !exmem_load && !exmem_fence))
        else $error("SVA PL_trap_no_side_effect: lenh gay trap van di xuong MEM voi tac dung phu");

    // ---- ngat khong mat: ngat da bat (mstatus.MIE & mip & mie) phai duoc nhan trong IRQ_MAX chu ky khong dong bang ----
    int unsigned wait_irq = 0, max_wait = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wait_irq <= 0;
        else if (irq_take || !irq_any) wait_irq <= 0;
        else if (!frz) begin
            wait_irq <= wait_irq + 1;
            if (wait_irq + 1 > max_wait) max_wait <= wait_irq + 1;
        end
    end
    PL_irq_not_lost: assert property (@(posedge clk) disable iff (!rst_n) wait_irq <= IRQ_MAX)
        else $error("SVA PL_irq_not_lost: ngat dang cho qua %0d chu ky khong bi nhan", IRQ_MAX);
    // khi ngat duoc nhan thi trap_q (ghi mepc / mcause) phai theo sau 1 chu ky
    PL_irq_traps: assert property (@(posedge clk) disable iff (!rst_n) (irq_take && !frz) |=> trap_q)
        else $error("SVA PL_irq_traps: nhan ngat nhung khong ghi trap (mepc / mcause)");

    final $display("SVA_STAT pipeline: ngat cho nhan lau nhat %0d chu ky khong dong bang (gioi han %0d)", max_wait, IRQ_MAX);
    cover property (@(posedge clk) disable iff (!rst_n) redirect_q && !frz);
    cover property (@(posedge clk) disable iff (!rst_n) trap_ex && !frz);
    cover property (@(posedge clk) disable iff (!rst_n) irq_take);
    cover property (@(posedge clk) disable iff (!rst_n) irq_any && !irq_take);
    cover property (@(posedge clk) disable iff (!rst_n) wb_we);
endmodule

bind rv32im_pipeline sva_pipeline u_sva_pl (.clk(clk), .rst_n(rst_n), .pc(pc), .redirect_pc_q(redirect_pc_q), .trap_pc(trap_pc), .rt_trap(rt_trap), .redirect_q(redirect_q),
    .frz(frz), .ifid_valid(ifid_valid), .idex_valid_r(idex_valid_r), .idex_valid(idex_valid), .exmem_valid(exmem_valid), .exmem_rd_we(exmem_rd_we),
    .exmem_load(exmem_load), .exmem_store(exmem_store), .exmem_fence(exmem_fence), .trap_ex(trap_ex), .irq_take(irq_take), .irq_any(irq_any),
    .wb_we(wb_we), .wb_commit(wb_commit), .mstatus_mie(mstatus_mie), .trap_q(trap_q), .memwb_rd(memwb_rd), .rs1(rs1), .rs2(rs2), .memwb_valid(memwb_valid), .memwb_rd_we(memwb_rd_we),
    .id_fa_mem(id_fa_mem), .id_fa_wb(id_fa_wb), .id_fb_mem(id_fb_mem), .id_fb_wb(id_fb_wb));
