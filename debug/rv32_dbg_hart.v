// Phan debug phia lop (hart) cho rv32im_pipeline.v khi bien dich voi -DDBG (RISC-V Debug spec 0.13.2, hart M-mode, SU = 0).
//  - Che do debug (D-mode): vao khi co yeu cau halt (haltreq cua DM), EBREAK khi dcsr.ebreakm = 1, trigger co action = 1,
//    hoac dung 1 lenh sau khi ra khoi D-mode voi dcsr.step = 1. Lenh o EX luc do KHONG thuc thi (giong ngat): dpc = pc cua no,
//    dcsr.cause ghi nguyen nhan, pc nhay toi ROM debug (rv32_dm.v). Trong D-mode: ngat bi che, exception / EBREAK nhay toi
//    ROM (DBG_BASE + 8 / + 4) ma khong ghi mepc / mcause / mtval; DRET (0x7B200073) tra ve pc = dpc va roi D-mode.
//  - CSR: dcsr 0x7B0, dpc 0x7B1, dscratch0/1 0x7B2/0x7B3 (chi truy cap duoc trong D-mode, ngoai D-mode la lenh bat hop le),
//    trigger kieu mcontrol (type 2): tselect 0x7A0, tdata1 0x7A1, tdata2 0x7A2, tinfo 0x7A4; NT = 2 trigger, khop dia chi
//    (match = 0 bang, 1 NAPOT) cho fetch (execute), load, store; action 0 = exception breakpoint (mcause 3), 1 = vao D-mode
//    (chi khi dmode = 1, dmode chi ghi duoc trong D-mode). Trigger tat trong D-mode.
module rv32_dbg_hart #(
    parameter ENABLE_C = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        halt_req,       // tu DM (muc)
    output reg         dbg_mode,
    // tang EX
    input  wire        ex_can,         // lenh o EX hop le va co the bi chan o chu ky nay (khong dong bang, khong M / WFI dang chay)
    input  wire        ex_done,        // lenh o EX hoan tat (hoac trap) chu ky nay
    input  wire [31:0] ex_pc,
    input  wire        ex_ebreak,
    input  wire        ex_load,
    input  wire        ex_store,
    input  wire [31:0] ex_ea,
    input  wire        ex_dret,        // DRET hop le o EX, khong dong bang
    output wire        take,           // vao D-mode: lenh o EX khong thuc thi, redirect toi ROM
    output wire        trig_exc,       // trigger action 0: exception breakpoint cho lenh o EX
    output wire        step_mask,      // dang single-step ngoai D-mode: che ngat (stepie = 0)
    output wire [31:0] dret_pc,
    // CSR
    input  wire [11:0] csr_addr,
    input  wire        csr_acc,        // lenh CSR hop le o EX (de bao truy cap bat hop le)
    input  wire        csr_wr,
    input  wire [31:0] csr_wdata,
    output reg  [31:0] csr_rdata,
    output wire        csr_ill
);
    localparam NT = 2;
    reg        ebreakm, step_en, step_halt;
    reg  [2:0] cause;
    reg  [31:1] dpc_r;
    reg  [31:0] dscr0, dscr1;
    reg        tsel;
    reg  [NT-1:0] t_hit, t_dmode, t_m, t_ex, t_st, t_ld, t_match, t_act;
    reg  [31:0] t_addr [0:NT-1];

    wire [31:0] dpc_v = {dpc_r[31:2], dpc_r[1] & (ENABLE_C != 0), 1'b0};
    assign dret_pc   = dpc_v;
    assign step_mask = step_en & ~dbg_mode;

    // ---- trigger ----
    function amatch(input [31:0] a, input [31:0] t, input napot);
        reg [31:0] mask;
        begin
            mask   = t ^ (t + 32'd1);
            amatch = napot ? (((a ^ t) & ~mask) == 32'd0) : (a == t);
        end
    endfunction
    reg [NT-1:0] fire;
    integer i;
    always @* begin
        for (i = 0; i < NT; i = i + 1)
            fire[i] = ex_can & ~dbg_mode & t_m[i] &
                      ((t_ex[i] & amatch(ex_pc, t_addr[i], t_match[i])) |
                       (ex_load & t_ld[i] & amatch(ex_ea, t_addr[i], t_match[i])) |
                       (ex_store & t_st[i] & amatch(ex_ea, t_addr[i], t_match[i])));
    end
    wire trig_dbg = |(fire & t_act & t_dmode);
    assign trig_exc = (|fire) & ~trig_dbg;

    // ---- vao D-mode ----
    wire w_ebreak = ex_can & ex_ebreak & ebreakm;
    wire w_halt   = ex_can & halt_req;
    wire w_step   = ex_can & step_halt;
    assign take = ~dbg_mode & (trig_dbg | w_ebreak | w_halt | w_step);
    wire [2:0] take_cause = trig_dbg ? 3'd2 : w_ebreak ? 3'd1 : w_halt ? 3'd3 : 3'd4;

    // ---- CSR ----
    wire is_d = (csr_addr[11:2] == 10'h1EC);                       // 0x7B0..0x7B3
    assign csr_ill = csr_acc & is_d & ~dbg_mode;
    wire [31:0] tdata1 = {4'd2, t_dmode[tsel], 6'd0, t_hit[tsel], 4'd0, t_act[tsel] ? 4'd1 : 4'd0,
                          1'b0, t_match[tsel] ? 4'd1 : 4'd0, t_m[tsel], 3'b0, t_ex[tsel], t_st[tsel], t_ld[tsel]};
    always @* begin
        case (csr_addr)
            12'h7A0: csr_rdata = {31'd0, tsel};
            12'h7A1: csr_rdata = tdata1;
            12'h7A2: csr_rdata = t_addr[tsel];
            12'h7A4: csr_rdata = 32'h0000_0004;                      // tinfo: chi ho tro type 2
            12'h7B0: csr_rdata = {4'd4, 12'd0, ebreakm, 3'b0, 3'b0, cause, 1'b0, 1'b0, 1'b0, step_en, 2'b11};
            12'h7B1: csr_rdata = dpc_v;
            12'h7B2: csr_rdata = dscr0;
            12'h7B3: csr_rdata = dscr1;
            default: csr_rdata = 32'd0;
        endcase
    end
    // dmode = 1 chi ghi duoc o D-mode; trigger dmode = 1 khong ghi duoc ngoai D-mode
    wire t_wok = dbg_mode | ~t_dmode[tsel];
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_mode <= 1'b0; ebreakm <= 1'b0; step_en <= 1'b0; step_halt <= 1'b0; cause <= 3'd0; dpc_r <= 31'd0;
            dscr0 <= 32'd0; dscr1 <= 32'd0; tsel <= 1'b0;
            t_hit <= 0; t_dmode <= 0; t_m <= 0; t_ex <= 0; t_st <= 0; t_ld <= 0; t_match <= 0; t_act <= 0;
            for (k = 0; k < NT; k = k + 1) t_addr[k] <= 32'd0;
        end else begin
            for (k = 0; k < NT; k = k + 1) if (fire[k]) t_hit[k] <= 1'b1;
            if (~dbg_mode & step_en & ex_done & ~take) step_halt <= 1'b1;
            if (take) begin
                dbg_mode <= 1'b1; cause <= take_cause; dpc_r <= ex_pc[31:1]; step_halt <= 1'b0;
            end else if (ex_dret) begin
                dbg_mode <= 1'b0; step_halt <= 1'b0;
            end
            if (csr_wr) begin
                case (csr_addr)
                    12'h7A0: if (csr_wdata < NT) tsel <= csr_wdata[0];
                    12'h7A1: if (t_wok) begin
                        t_dmode[tsel] <= dbg_mode & csr_wdata[27];
                        t_hit[tsel]   <= csr_wdata[20];
                        t_act[tsel]   <= dbg_mode & csr_wdata[27] & (csr_wdata[15:12] == 4'd1);
                        t_match[tsel] <= (csr_wdata[10:7] == 4'd1);
                        t_m[tsel]     <= csr_wdata[6];
                        t_ex[tsel]    <= csr_wdata[2];
                        t_st[tsel]    <= csr_wdata[1];
                        t_ld[tsel]    <= csr_wdata[0];
                    end
                    12'h7A2: if (t_wok) t_addr[tsel] <= csr_wdata;
                    12'h7B0: begin ebreakm <= csr_wdata[15]; step_en <= csr_wdata[2]; end
                    12'h7B1: dpc_r <= csr_wdata[31:1];
                    12'h7B2: dscr0 <= csr_wdata;
                    12'h7B3: dscr1 <= csr_wdata;
                    default: ;
                endcase
            end
        end
    end
endmodule
