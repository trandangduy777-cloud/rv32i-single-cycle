// RV32IM pipeline 5 tang + Zicsr co ban + trap (che do Machine), tu viet
// - Cung cong voi rv32i_core / rv32i_pipeline. Bo nho lenh va du lieu nam ngoai, doc combinational, ghi dong bo.
// - Lenh: RV32I, FENCE/FENCE.I (NOP), ECALL, EBREAK, MRET, CSRRW/S/C(I), phan mo rong M (MUL..REMU)
// - CSR va trap: xu ly o tang EX, theo dung thu tu chuong trinh. Trap/MRET gui lenh redirect nhu nhanh
//   (huy 2 lenh dang o IF va ID). Lenh gay trap khong ghi thanh ghi/bo nho, mepc = pc cua lenh do.
// - Hazard dieu khien: giong rv32i_pipeline. JAL nhay som o ID (mat 1 chu ky); nhanh co dieu kien duoc doan o ID
//   bang bang dem 2 bit (BHT_N muc), doan sai phat hien o EX (mat 2 chu ky); JALR, trap, MRET quyet dinh o EX.
//   Dich nhay som tinh dung o ID nen doan sai chi gay cham. Bang dem cap nhat tre 1 chu ky qua thanh ghi o EX/MEM.
// - M: don vi nhan/chia lap (module rv32m cua rv32i_core.v). Lenh M dung o EX, dong bang IF/ID/EX den khi xong;
//   MEM/WB tiep tuc chay, EX/MEM nhan bong bay.
// - Hazard du lieu: forwarding EX/MEM va MEM/WB -> EX, bypass WB -> ID, load-use dung 1 chu ky
// - Ngat: irq_ext (MEIP), irq_soft (MSIP), irq_timer (MTIP), muc cao, giu cho toi khi phan mem xoa nguon ngat.
//   Ngat duoc nhan o EX khi mstatus.MIE = 1 va bit tuong ung trong mie bat: lenh dang o EX khong thuc thi,
//   mepc = pc cua lenh do, mcause = 0x8000000B / 0x80000003 / 0x80000007 (uu tien theo thu tu nay), nhay toi mtvec
//   giong trap (mtvec.MODE = 1: toi BASE + 4 * ma nguyen nhan, exception van ve BASE). Lenh M dang chay khong bi ngat (ngat cho lenh ke tiep). mip (0x344) chi doc, phan anh cac chan ngat.
// - WFI: dung o EX (dong bang IF/ID/EX nhu lenh M) cho toi khi (mip & mie) != 0, bat ke mstatus.MIE. Ngat khong
//   nhan tren chinh lenh WFI ma tren lenh ke tiep, nen mepc = pc cua WFI + 4.
// - Cac tin hieu memwb_* duoc testbench doc truc tiep (tang commit) de in vet
// - Mo rong C (ENABLE_C = 1): lenh 16 bit duoc giai nen o IF (rv32c_decompress.v) thanh lenh 32 bit tuong duong, nen
//   ID/EX/MEM/WB khong doi. pc tang 2 hoac 4; dia chi lien ket cua JAL/JALR va dich "chay tiep" khi doan sai la
//   pc + 2 voi lenh nen. Dich nhay chi can chia het cho 2 nen khong con trap lech dia chi lenh. Bo nho lenh phai tra
//   ve 32 bit bat dau tu dia chi imem_addr chia het cho 2 (vd. 2 bank 16 bit xen ke chan / le), vi lenh 32 bit co the
//   nam vat qua ranh gioi tu. mtval cua lenh nen khong hop le la 16 bit goc. ENABLE_C = 0: giong het ban cu.
// - Bo nho co do tre (cache, bus): imem_ready = 0 nghia la imem_data chua co cho imem_addr: IF giu pc va dua bong
//   bay vao ID. dmem_ready = 0 khi lenh o MEM dang load (dmem_re), store (dmem_we) hoac FENCE/FENCE.I
//   (dmem_fence, cho bo dem ghi cua cache du lieu rong): ca pipeline dong bang
//   (frz), ke ca MEM/WB, va moi tac dung o EX (redirect, trap, ghi CSR, nhan ngat, cap nhat bang dem nhanh) bi chan
//   cho toi khi lenh o MEM xong. WB ghi lai cung gia tri moi chu ky dong bang (khong doi ket qua); wb_commit danh
//   dau dung 1 chu ky cho moi lenh hoan tat. Bo nho to hop: noi imem_ready = dmem_ready = 1 (giong het ban cu).
//   Cache trong rv32_icache.v / rv32_dcache.v.
// Can bien dich cung rv32i_core.v (de lay module rv32m) va rv32c_decompress.v.
module rv32im_pipeline #(
    parameter [31:0] RESET_PC = 32'h0000_0000,  // dia chi lenh dau tien sau reset (chia het cho 4, hoac 2 khi ENABLE_C)
    parameter        ENABLE_C = 0,               // 1: ho tro lenh nen 16 bit (mo rong C)
    parameter        MISALIGNED = 0,             // 1: load/store lech dia chi chay bang phan cung thay vi trap
    // Du doan nhanh (xem phan "Du doan nhanh"): BTB_N = 0 va RAS_N = 0 va GHR_BITS = 0 la bo du doan cu (bang dem o ID)
    parameter        BTB_N      = 16,            // so muc BTB (luy thua 2, 0 = khong co): du doan dich ngay o IF
    parameter        RAS_N      = 4,             // so muc ngan xep dia chi tra ve (0 = khong co)
    parameter        GHR_BITS   = 0,             // > 0: gshare (lich su toan cuc GHR_BITS bit XOR voi pc); 0: theo pc
    parameter        TAGE       = 0,             // 1: huong nhanh doan bang TAGE (rv32_tage.v) thay cho bang dem / gshare
    parameter        TAGE_NT    = 4,             // TAGE: so bang co tag, chi so / tag moi bang, bit chi so bang co so
    parameter        TAGE_IB    = 6,
    parameter        TAGE_TB    = 8,
    parameter        TAGE_BB    = 7,
    parameter [8*TAGE_NT-1:0] TAGE_HL = {8'd32, 8'd16, 8'd8, 8'd4},   // so bit lich su cua tung bang (bang 0 o byte thap)
    parameter        BTB_TAG    = 10,            // so bit tag cua BTB (nho -> trung nham nhieu; dung de kiem chung)
    parameter        MUL_LAT    = 2,             // nhan: 0 = lap (~18 chu ky), 1 = song song 1 chu ky, 2 = song song 2 tang
    parameter        ZICNTR     = 1,             // 1: bo dem mcycle / minstret (Zicntr) va bo dem su kien (Zihpm)
    parameter        HPM_N      = 4,             // so bo dem su kien mhpmcounter3.. that su dem (0-29; con lai doc 0)
    parameter        PMP_N      = 8,             // so muc PMP (0-16), do mien 4 byte; muc khoa (L) ap dung ca che do M
    parameter        SU         = 0,             // 1: them che do Supervisor / User (uy quyen trap, SRET, CSR S, PMP cho S/U)
    parameter        MMU        = 0,             // 1 (can SU = 1): MMU Sv32 (TLB TLB_N muc + duyet bang trang), SFENCE.VMA
    parameter        TLB_N      = 8,
    // Mo rong thao tac bit va lenh dieu kien (giai ma o ID, thuc thi 1 chu ky o EX, xem "Zba/Zbb/Zbs/Zbc/Zicond"):
    // mac dinh tat het (RTL, so lieu flow va CI cu giu nguyen); lenh cua phan mo rong dang tat la lenh bat hop le (trap 2)
    parameter        ZBA        = 0,             // sh1add sh2add sh3add
    parameter        ZBB        = 0,             // andn orn xnor clz ctz cpop sext.b sext.h zext.h min max minu maxu rol ror rori orc.b rev8
    parameter        ZBS        = 0,             // bclr bclri bext bexti binv binvi bset bseti
    parameter        ZBC        = 0,             // clmul clmulh clmulr
    parameter        ZICOND     = 0,             // czero.eqz czero.nez
    // Mo rong A (xem "Mo rong A: LR/SC va AMO"): mac dinh tat (RTL, so lieu flow va CI cu giu nguyen), misa co bit A khi bat
    parameter        A_EXT      = 0,             // 1: LR.W, SC.W, AMOSWAP/ADD/XOR/AND/OR/MIN/MAX/MINU/MAXU.W
    parameter        A_ST_CLR   = 0              // 1: store thuong cua chinh lo (va AMO) vao tu dang dat cho cung xoa dat cho; 0: giong Spike
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,
    input  wire        imem_ready,     // 1: imem_data hop le cho imem_addr trong chu ky nay

    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    output wire        dmem_we,
    output wire        dmem_re,        // lenh o MEM la load (dia chi tren dmem_addr)
    output wire        dmem_fence,     // FENCE / FENCE.I o MEM: cho bo nho du lieu ghi het store dang treo (dmem_ready)
    output wire        icache_flush,   // FENCE.I o EX: xoa cache lenh (1 chu ky); bo nho to hop: bo trong
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_ready,     // 1: load/store o MEM hoan tat trong chu ky nay (load: dmem_rdata hop le)

    input  wire        irq_timer,      // MTIP, tu bo dem mtime/mtimecmp ben ngoai (rv32_mtimer.v)
    input  wire        irq_soft,       // MSIP, thanh ghi msip cua rv32_mtimer.v
    input  wire        irq_ext         // MEIP
`ifdef RISCV_FORMAL
    // Cong RVFI (riscv-formal, 1 kenh): chi co khi bien dich voi -DRISCV_FORMAL, khong doi gi o ban thuong.
    , output wire        fv_wfi_wait     // chi cho kiem chung: WFI dang cho ngat (cho cong bang cua liveness)
    // chi cho kiem chung MISALIGNED = 1: truy cap logic cua lenh o MEM de monitor trong wrapper doi chieu voi giao dich tren bus
    , output wire        fv_m_valid, fv_m_store, fv_m_last
    , output wire [31:0] fv_m_addr, fv_m_sval, fv_m_ld
    , output wire [1:0]  fv_m_size
    , output wire        rvfi_valid
    , output wire [63:0] rvfi_order
    , output wire [31:0] rvfi_insn
    , output wire        rvfi_trap
    , output wire        rvfi_halt
    , output wire        rvfi_intr
    , output wire [1:0]  rvfi_mode
    , output wire [1:0]  rvfi_ixl
    , output wire [4:0]  rvfi_rs1_addr
    , output wire [4:0]  rvfi_rs2_addr
    , output wire [31:0] rvfi_rs1_rdata
    , output wire [31:0] rvfi_rs2_rdata
    , output wire [4:0]  rvfi_rd_addr
    , output wire [31:0] rvfi_rd_wdata
    , output wire [31:0] rvfi_pc_rdata
    , output wire [31:0] rvfi_pc_wdata
    , output wire [31:0] rvfi_mem_addr
    , output wire [3:0]  rvfi_mem_rmask
    , output wire [3:0]  rvfi_mem_wmask
    , output wire [31:0] rvfi_mem_rdata
    , output wire [31:0] rvfi_mem_wdata
`ifdef RISCV_FORMAL_CSR_MISA
    , output wire [31:0] rvfi_csr_misa_rmask
    , output wire [31:0] rvfi_csr_misa_wmask
    , output wire [31:0] rvfi_csr_misa_rdata
    , output wire [31:0] rvfi_csr_misa_wdata
`endif
`ifdef RISCV_FORMAL_CSR_MHARTID
    , output wire [31:0] rvfi_csr_mhartid_rmask
    , output wire [31:0] rvfi_csr_mhartid_wmask
    , output wire [31:0] rvfi_csr_mhartid_rdata
    , output wire [31:0] rvfi_csr_mhartid_wdata
`endif
`ifdef RISCV_FORMAL_CSR_MSTATUS
    , output wire [31:0] rvfi_csr_mstatus_rmask
    , output wire [31:0] rvfi_csr_mstatus_wmask
    , output wire [31:0] rvfi_csr_mstatus_rdata
    , output wire [31:0] rvfi_csr_mstatus_wdata
`endif
`ifdef RISCV_FORMAL_CSR_MIE
    , output wire [31:0] rvfi_csr_mie_rmask
    , output wire [31:0] rvfi_csr_mie_wmask
    , output wire [31:0] rvfi_csr_mie_rdata
    , output wire [31:0] rvfi_csr_mie_wdata
`endif
`ifdef RISCV_FORMAL_CSR_MTVEC
    , output wire [31:0] rvfi_csr_mtvec_rmask
    , output wire [31:0] rvfi_csr_mtvec_wmask
    , output wire [31:0] rvfi_csr_mtvec_rdata
    , output wire [31:0] rvfi_csr_mtvec_wdata
`endif
`ifdef RISCV_FORMAL_CSR_MSCRATCH
    , output wire [31:0] rvfi_csr_mscratch_rmask
    , output wire [31:0] rvfi_csr_mscratch_wmask
    , output wire [31:0] rvfi_csr_mscratch_rdata
    , output wire [31:0] rvfi_csr_mscratch_wdata
`endif
`ifdef RISCV_FORMAL_CSR_MEPC
    , output wire [31:0] rvfi_csr_mepc_rmask
    , output wire [31:0] rvfi_csr_mepc_wmask
    , output wire [31:0] rvfi_csr_mepc_rdata
    , output wire [31:0] rvfi_csr_mepc_wdata
`endif
`ifdef RISCV_FORMAL_CSR_MCAUSE
    , output wire [31:0] rvfi_csr_mcause_rmask
    , output wire [31:0] rvfi_csr_mcause_wmask
    , output wire [31:0] rvfi_csr_mcause_rdata
    , output wire [31:0] rvfi_csr_mcause_wdata
`endif
`ifdef RISCV_FORMAL_CSR_MTVAL
    , output wire [31:0] rvfi_csr_mtval_rmask
    , output wire [31:0] rvfi_csr_mtval_wmask
    , output wire [31:0] rvfi_csr_mtval_rdata
    , output wire [31:0] rvfi_csr_mtval_wdata
`endif
`endif
);
    localparam NOP = 32'h0000_0013;

    // ============================================================
    // Khai bao truoc cac tin hieu dung cheo giua cac tang
    // ============================================================
    wire        id_fa_mem, id_fa_wb, id_fb_mem, id_fb_wb;   // chon forwarding, tinh san o ID
    wire        stall;                 // load-use: giu IF/ID va PC, chen bong bay vao EX
    wire        ex_stall;              // lenh M dang chay o EX: dong bang IF/ID/EX
    wire        frz;                   // load/store o MEM dang cho bo nho: dong bang toan bo pipeline
    wire        redirect;              // EX: JALR, doan sai nhanh, trap hoac MRET (tin hieu muon, chi duoc DANG KY)
    wire [31:0] redirect_pc;
    // redirect khong duoc dung ngay trong chu ky dang tinh: no duoc luu vao redirect_q/redirect_pc_q va ap vao chu ky ke tiep.
    // Nho vay cay fanout cua redirect bat dau tu 1 flip-flop thay vi tu sau bo so sanh nhanh. Doi lai phat nhanh doan sai la 3 chu ky.
    reg         redirect_q;
    reg  [31:0] redirect_pc_q;
    wire        id_redirect;           // ID nhay som (JAL, hoac nhanh doan "nhay")
    wire [31:0] id_target;

    reg         memwb_valid, memwb_rd_we;
    reg  [4:0]  memwb_rd;
    reg  [31:0] memwb_val;
    wire        wb_we = memwb_valid & memwb_rd_we & (memwb_rd != 5'd0);

    // ============================================================
    // IF
    // ============================================================
    // TAGE: rv32_tage.v doc o IF cung luc voi BTB; meta (chi so, tag, provider) di qua IF/ID, ID/EX, EX/MEM toi luc cap
    // nhat (chu ky sau EX, nhu bang dem). Lich su dich o EX theo nhanh that su chay xong (khong suy doan).
    localparam TPW = $clog2(TAGE_NT + 1);
    localparam TMW = (TAGE != 0) ? 3 + 1 + 2 * TPW + TAGE_BB + TAGE_NT * (TAGE_IB + TAGE_TB) : 1;
    reg  [31:0] pc;
    reg         ifid_valid;
    reg  [31:0] ifid_pc, ifid_instr;
    reg  [31:0] ifid_raw;                  // lenh goc (16 bit nen hoac 32 bit): cho mtval va vet
    reg         ifid_c;                    // lenh o ID la lenh nen 16 bit
    reg         ifid_bp, ifid_bhit, ifid_ctr;  // du doan cua IF cho lenh o ID (xem "Du doan nhanh")
    reg  [31:0] ifid_bpt;
    reg  [5:0]  ifid_pidx;
    reg  [TMW-1:0] ifid_tmeta;             // TAGE: chi so / tag / provider luc du doan (mang toi luc cap nhat)
    reg         ifid_ipf, ifid_iaf, ifid_ipf2;     // MMU: loi dich dia chi fetch
    reg  [31:0] ifid_ppa, ifid_ppa2;               // dia chi vat ly cua lenh va cua nua sau (pc + 2)

    // ---- dich dia chi lenh (MMU = 1, satp.MODE = Sv32, che do < M): TLB tra cuu to hop tren pc ----
    // TLB truot: IF dua bong bay va xin duyet bang trang. Loi trang / loi truy cap khi duyet, hoac PTE khong cho
    // thuc thi (X, U, A): IF dua xuong mot NOP mang co loi (ifid_ipf), toi EX thi trap ma 12 / 1. Lenh 32 bit nam vat
    // qua ranh gioi trang (chi khi co C): lay 2 lan, nua sau dich rieng tu pc + 2 (giong Spike lay tung nua 16 bit).
    wire        xi;                                  // dich dia chi fetch (gan o phan CSR)
    wire        mmu_flush;
    reg         spl_q;                               // dang lay nua sau cua lenh vat trang
    reg  [15:0] spl_lo;
    reg  [31:0] spl_pa;
    wire [31:0] i_va = spl_q ? pc + 32'd2 : pc;
    wire        i_hit;
    wire [33:0] i_pa;
    wire [5:0]  i_fl;                                // {D, A, U, X, W, R}
    reg         ifr_v, ifr_af;                       // lan duyet cho fetch da loi
    reg  [31:0] ifr_va;
    wire [1:0]  priv;
    wire        i_rec  = ifr_v & (ifr_va == i_va);
    wire        i_bad  = ~i_fl[2] | ~i_fl[4] | ((priv == 2'd1) ? i_fl[3] : ~i_fl[3]);   // X, A, U (S khong chay trang U)
    wire        if_tfault = xi & ((i_hit & (i_bad | (i_pa[33:32] != 2'b00))) | i_rec);
    wire        if_taf    = i_rec ? ifr_af : ~i_bad;                 // loi truy cap (ma 1) thay vi loi trang (ma 12)
    wire        i_need    = xi & ~i_hit & ~i_rec;
    assign imem_addr = xi ? i_pa[31:0] : pc;
    wire [31:0] if_word = spl_q ? {imem_data[15:0], spl_lo} : imem_data;

    // giai nen o IF: lenh nen chi ton 1 tang mach to hop truoc thanh ghi IF/ID
    wire [31:0] if_dec;
    wire        if_dec_ill;
    wire        if_c = (ENABLE_C != 0) && !spl_q && (imem_data[1:0] != 2'b11);
    wire        spl_start = (ENABLE_C != 0) & (MMU != 0) & xi & ~spl_q & i_hit & ~if_tfault & (pc[11:1] == 11'h7FF) &
                            (imem_data[1:0] == 2'b11);
    generate if (ENABLE_C) begin : g_rvc
        rv32c_decompress u_rvc (.in(if_word), .out(if_dec), .illegal(if_dec_ill));
    end else begin : g_no_rvc
        assign if_dec = if_word;
        assign if_dec_ill = 1'b0;
    end endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc         <= RESET_PC;
            ifid_valid <= 1'b0;
        end else if (frz) begin
            // dong bang: giu nguyen pc va IF/ID
        end else if (redirect_q) begin
            pc         <= redirect_pc_q;
            ifid_valid <= 1'b0;                // huy lenh vua doc nham duong
        end else if (id_redirect & ~ex_stall) begin   // ID sua / nhay som: huy lenh vua doc o IF
            pc         <= id_redir_pc;
            ifid_valid <= 1'b0;
        end else if (stall | ex_stall) begin
            // ID hoac EX dang dung: giu lenh o IF/ID
        end else if (if_tfault) begin         // loi dich dia chi fetch: dua NOP mang co loi, giu pc (EX se trap)
            ifid_valid <= 1'b1;
        end else if (!imem_ready || i_need) begin   // cache lenh chua tra / TLB truot: giu pc, dua bong bay vao ID
            ifid_valid <= 1'b0;
        end else if (spl_start) begin         // lenh vat trang: giu nua dau, lan sau lay nua sau tu pc + 2
            ifid_valid <= 1'b0;
        end else begin
            pc         <= if_pred ? if_ptgt : pc + (if_c ? 32'd2 : 32'd4);   // BTB doan nhay: sang dich ngay
            ifid_valid <= 1'b1;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                     spl_q <= 1'b0;
        else if (frz)                                   ;
        else if (redirect_q || (id_redirect & ~ex_stall) || mmu_flush) spl_q <= 1'b0;
        else if (stall | ex_stall)                      ;
        else if (if_tfault)                             ;
        else if (!imem_ready || i_need)                 ;
        else if (spl_start)                             spl_q <= 1'b1;
        else                                            spl_q <= 1'b0;
    end
    always @(posedge clk) if (!spl_q && !frz) begin    // chi dung khi spl_q = 1, tuc gia tri cua chu ky spl_start
        spl_lo <= imem_data[15:0];
        spl_pa <= i_pa[31:0];
    end

    // Truong du lieu cua IF/ID (pc, lenh) khong bi redirect dieu khien enable: lenh bi huy da duoc danh dau bang
    // ifid_valid = 0. Nho vay tin hieu redirect (ket qua so sanh nhanh o EX) khong phai toi hang chuc flip-flop nay.
    always @(posedge clk) begin
        if (!(stall | ex_stall | frz)) begin
            ifid_pc    <= pc;
            ifid_instr <= if_tfault ? NOP : if_dec;   // lenh nen khong hop le -> 0 (bo giai ma 32 bit bao illegal)
            ifid_raw   <= if_c ? {16'd0, if_word[15:0]} : if_word;
            ifid_c     <= if_c & ~if_tfault;
            ifid_bp    <= if_pred & ~if_tfault;   // IF da nhay theo BTB
            ifid_bpt   <= if_ptgt;
            ifid_bhit  <= btb_hit;
            ifid_ctr   <= if_ctr;            // huong do bang dem doan (doc o IF)
            ifid_pidx  <= if_pidx;
            ifid_tmeta <= if_tmeta;
            ifid_ipf   <= if_tfault;         // loi dich dia chi fetch (MMU)
            ifid_iaf   <= if_taf;
            ifid_ipf2  <= spl_q;             // loi o nua sau (mtval = pc + 2)
            ifid_ppa   <= spl_q ? spl_pa : (xi ? i_pa[31:0] : pc);                  // dia chi vat ly cho PMP
            ifid_ppa2  <= spl_q ? i_pa[31:0] : ((xi ? i_pa[31:0] : pc) + 32'd2);
        end
    end

    // ============================================================
    // ID: giai ma chat (cung quy tac voi rv32i_core)
    // ============================================================
    wire [31:0] instr  = ifid_instr;
    wire [6:0]  opcode = instr[6:0];
    wire [4:0]  rd     = instr[11:7];
    wire [2:0]  funct3 = instr[14:12];
    wire [4:0]  rs1    = instr[19:15];
    wire [4:0]  rs2    = instr[24:20];

    wire is_lui    = (opcode == 7'b0110111);
    wire is_auipc  = (opcode == 7'b0010111);
    wire is_jal    = (opcode == 7'b1101111);
    wire is_jalr   = (opcode == 7'b1100111);
    wire is_branch = (opcode == 7'b1100011);
    wire is_load   = (opcode == 7'b0000011);
    wire is_store  = (opcode == 7'b0100011);
    wire is_imm    = (opcode == 7'b0010011);
    wire is_reg    = (opcode == 7'b0110011);
    wire is_fence  = (opcode == 7'b0001111);
    wire is_system = (opcode == 7'b1110011);

    wire f7_zero = (instr[31:25] == 7'b0000000);
    wire f7_alt  = (instr[31:25] == 7'b0100000);
    wire f7_m    = (instr[31:25] == 7'b0000001);

    // ---- Zba / Zbb / Zbs / Zbc / Zicond: giai ma chat theo {funct7, funct3} (va rs2 cho lenh mot ngoi) ----
    // zb_op la ma thao tac gui xuong EX; zb_*_ok = lenh hop le va phan mo rong tuong ung dang bat.
    localparam [4:0] Z_SH1ADD = 5'd0,  Z_SH2ADD = 5'd1,  Z_SH3ADD = 5'd2,  Z_ANDN = 5'd3,  Z_ORN  = 5'd4,  Z_XNOR  = 5'd5,
                     Z_CLZ    = 5'd6,  Z_CTZ    = 5'd7,  Z_CPOP   = 5'd8,  Z_SEXTB = 5'd9, Z_SEXTH = 5'd10, Z_ZEXTH = 5'd11,
                     Z_MAX    = 5'd12, Z_MAXU   = 5'd13, Z_MIN    = 5'd14, Z_MINU  = 5'd15, Z_ROL  = 5'd16, Z_ROR   = 5'd17,
                     Z_ORCB   = 5'd18, Z_REV8   = 5'd19, Z_BCLR   = 5'd20, Z_BEXT  = 5'd21, Z_BINV = 5'd22, Z_BSET  = 5'd23,
                     Z_CLMUL  = 5'd24, Z_CLMULH = 5'd25, Z_CLMULR = 5'd26, Z_CZEQZ = 5'd27, Z_CZNEZ = 5'd28;
    reg        zb_reg_ok, zb_imm_ok;
    reg [4:0]  zb_op;
    always @* begin
        zb_reg_ok = 1'b0; zb_imm_ok = 1'b0; zb_op = 5'd0;
        if (is_reg) begin
            case ({instr[31:25], funct3})
                {7'b0010000, 3'b010}: begin zb_reg_ok = (ZBA != 0); zb_op = Z_SH1ADD; end
                {7'b0010000, 3'b100}: begin zb_reg_ok = (ZBA != 0); zb_op = Z_SH2ADD; end
                {7'b0010000, 3'b110}: begin zb_reg_ok = (ZBA != 0); zb_op = Z_SH3ADD; end
                {7'b0100000, 3'b111}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_ANDN; end
                {7'b0100000, 3'b110}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_ORN; end
                {7'b0100000, 3'b100}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_XNOR; end
                {7'b0000101, 3'b100}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_MIN; end
                {7'b0000101, 3'b101}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_MINU; end
                {7'b0000101, 3'b110}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_MAX; end
                {7'b0000101, 3'b111}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_MAXU; end
                {7'b0110000, 3'b001}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_ROL; end
                {7'b0110000, 3'b101}: begin zb_reg_ok = (ZBB != 0); zb_op = Z_ROR; end
                {7'b0000100, 3'b100}: begin zb_reg_ok = (ZBB != 0) & (rs2 == 5'd0); zb_op = Z_ZEXTH; end
                {7'b0100100, 3'b001}: begin zb_reg_ok = (ZBS != 0); zb_op = Z_BCLR; end
                {7'b0100100, 3'b101}: begin zb_reg_ok = (ZBS != 0); zb_op = Z_BEXT; end
                {7'b0110100, 3'b001}: begin zb_reg_ok = (ZBS != 0); zb_op = Z_BINV; end
                {7'b0010100, 3'b001}: begin zb_reg_ok = (ZBS != 0); zb_op = Z_BSET; end
                {7'b0000101, 3'b001}: begin zb_reg_ok = (ZBC != 0); zb_op = Z_CLMUL; end
                {7'b0000101, 3'b010}: begin zb_reg_ok = (ZBC != 0); zb_op = Z_CLMULR; end
                {7'b0000101, 3'b011}: begin zb_reg_ok = (ZBC != 0); zb_op = Z_CLMULH; end
                {7'b0000111, 3'b101}: begin zb_reg_ok = (ZICOND != 0); zb_op = Z_CZEQZ; end
                {7'b0000111, 3'b111}: begin zb_reg_ok = (ZICOND != 0); zb_op = Z_CZNEZ; end
                default: ;
            endcase
        end
        if (is_imm) begin
            case ({instr[31:25], funct3})
                {7'b0110000, 3'b001}: begin                   // clz ctz cpop sext.b sext.h: chon theo rs2
                    case (rs2)
                        5'd0:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_CLZ; end
                        5'd1:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_CTZ; end
                        5'd2:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_CPOP; end
                        5'd4:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_SEXTB; end
                        5'd5:    begin zb_imm_ok = (ZBB != 0); zb_op = Z_SEXTH; end
                        default: ;
                    endcase
                end
                {7'b0110000, 3'b101}: begin zb_imm_ok = (ZBB != 0); zb_op = Z_ROR; end                 // rori
                {7'b0010100, 3'b101}: begin zb_imm_ok = (ZBB != 0) & (rs2 == 5'b00111); zb_op = Z_ORCB; end
                {7'b0110100, 3'b101}: begin zb_imm_ok = (ZBB != 0) & (rs2 == 5'b11000); zb_op = Z_REV8; end
                {7'b0100100, 3'b001}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BCLR; end                // bclri
                {7'b0100100, 3'b101}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BEXT; end                // bexti
                {7'b0110100, 3'b001}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BINV; end                // binvi
                {7'b0010100, 3'b001}: begin zb_imm_ok = (ZBS != 0); zb_op = Z_BSET; end                // bseti
                default: ;
            endcase
        end
    end
    wire id_zb = zb_reg_ok | zb_imm_ok;

    wire legal_reg    = is_reg & (f7_zero | f7_m | (f7_alt & (funct3 == 3'b000 | funct3 == 3'b101))) | zb_reg_ok;
    wire legal_imm    = is_imm & ((funct3 == 3'b001) ? f7_zero :
                                  (funct3 == 3'b101) ? (f7_zero | f7_alt) : 1'b1) | zb_imm_ok;
    wire legal_load   = is_load & (funct3 == 3'b000 | funct3 == 3'b001 | funct3 == 3'b010 |
                                   funct3 == 3'b100 | funct3 == 3'b101);
    wire legal_store  = is_store & (funct3 == 3'b000 | funct3 == 3'b001 | funct3 == 3'b010);
    wire legal_branch = is_branch & (funct3 != 3'b010 & funct3 != 3'b011);
    wire legal_jalr   = is_jalr & (funct3 == 3'b000);
    wire legal_fence  = is_fence & (funct3 == 3'b000 | funct3 == 3'b001);

    // Mo rong A: opcode AMO, funct3 = 010 (word), funct5 = instr[31:27]; aq (bit 26) va rl (bit 25) chap nhan moi gia tri
    // (loi in-order, 1 cong bo nho: moi truy cap da dung thu tu chuong trinh). LR bat buoc rs2 = 0.
    wire [4:0] id_amo_f5   = instr[31:27];
    wire is_amo_op      = (opcode == 7'b0101111) & (funct3 == 3'b010) & (A_EXT != 0);
    wire legal_lr       = is_amo_op & (id_amo_f5 == 5'b00010) & (rs2 == 5'd0);
    wire legal_sc       = is_amo_op & (id_amo_f5 == 5'b00011);
    wire legal_amo      = is_amo_op & (id_amo_f5 == 5'b00001 | id_amo_f5 == 5'b00000 | id_amo_f5 == 5'b00100 | id_amo_f5 == 5'b01100 |
                                       id_amo_f5 == 5'b01000 | id_amo_f5 == 5'b10000 | id_amo_f5 == 5'b10100 | id_amo_f5 == 5'b11000 |
                                       id_amo_f5 == 5'b11100);
    wire legal_atomic   = legal_lr | legal_sc | legal_amo;

    wire is_ecall  = (instr == 32'h0000_0073);
    wire is_ebreak = (instr == 32'h0010_0073);
    wire is_mret   = (instr == 32'h3020_0073);
    wire is_wfi    = (instr == 32'h1050_0073);
    wire is_sret   = (instr == 32'h1020_0073) & (SU != 0);
    wire is_sfence = (opcode == 7'b1110011) & (funct3 == 3'b000) & (instr[31:25] == 7'b0001001) & (rd == 5'd0) &
                     (SU != 0) & (MMU != 0);                                  // SFENCE.VMA rs1, rs2
    wire is_fencei = is_fence & (funct3 == 3'b001);     // Zifencei
    wire is_csr    = is_system & (funct3 != 3'b000) & (funct3 != 3'b100);

    // CSR co ton tai khong, co ghi duoc khong: chi phu thuoc cac bit cua lenh nen xet duoc ngay o ID
    wire [11:0] id_csr_addr = instr[31:20];
    reg         id_csr_exists;
    always @* begin
        case (id_csr_addr)
            12'h300, 12'h301, 12'h304, 12'h305, 12'h340, 12'h341, 12'h342, 12'h343, 12'h344, 12'hF11, 12'hF12, 12'hF13, 12'hF14: id_csr_exists = 1'b1;   // F11-F13: mvendorid, marchid, mimpid = 0
            default: id_csr_exists = 1'b0;
        endcase
        // Zicntr / Zihpm: mcountinhibit, mhpmevent3-31, mcycle / minstret / mhpmcounter3-31 (+h), cycle / instret /
        // hpmcounter3-31 (+h) chi doc (time khong co: bo dem thoi gian nam ngoai loi)
        if (ZICNTR != 0 && (id_csr_addr == 12'h320 || (id_csr_addr >= 12'h323 && id_csr_addr <= 12'h33F) ||
                            id_csr_addr[11:8] == 4'hB && id_csr_addr[6:5] == 2'b00 && id_csr_addr[4:0] != 5'd1 ||
                            id_csr_addr[11:8] == 4'hC && id_csr_addr[6:5] == 2'b00 && id_csr_addr[4:0] != 5'd1))
            id_csr_exists = 1'b1;
        // PMP: pmpcfg0-15 (0x3A0-0x3AF), pmpaddr0-63 (0x3B0-0x3EF); muc ngoai PMP_N doc 0 (WARL)
        if (id_csr_addr >= 12'h3A0 && id_csr_addr <= 12'h3EF) id_csr_exists = 1'b1;
        // che do S / U: sstatus sie stvec scounteren sscratch sepc scause stval sip satp, medeleg mideleg mcounteren
        if (SU != 0)
            case (id_csr_addr)
                12'h100, 12'h104, 12'h105, 12'h106, 12'h140, 12'h141, 12'h142, 12'h143, 12'h144, 12'h180,
                12'h302, 12'h303, 12'h306: id_csr_exists = 1'b1;
                default: ;
            endcase
    end
    wire id_csr_we_req = (funct3[1:0] == 2'b01) | (rs1 != 5'd0);
    wire id_csr_ro     = (id_csr_addr[11:10] == 2'b11);
    wire legal_csr     = is_csr & id_csr_exists & ~(id_csr_we_req & id_csr_ro);

    wire illegal = ~(is_lui | is_auipc | is_jal | legal_jalr | legal_branch | legal_load |
                     legal_store | legal_imm | legal_reg | legal_fence | legal_atomic |
                     is_ecall | is_ebreak | is_mret | is_wfi | is_sret | is_sfence | legal_csr);

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    wire [31:0] imm = legal_atomic        ? 32'd0 :       // dia chi = rs1
                      is_store            ? imm_s :
                      is_branch           ? imm_b :
                      (is_lui | is_auipc) ? imm_u :
                      is_jal              ? imm_j : imm_i;

    wire rd_we = is_lui | is_auipc | is_jal | legal_jalr | legal_load | legal_imm | legal_reg | legal_csr | legal_atomic;

    // toan hang nao that su duoc dung
    wire uses_rs1 = ~(is_lui | is_auipc | is_jal);
    wire uses_rs2 = is_reg | is_branch | is_store | legal_sc | legal_amo;

    // ---- Du doan nhanh ----
    // IF: BTB (BTB_N muc, anh xa truc tiep theo pc, tag 10 bit) cho biet o pc dang nap co lenh dieu khien da tung nhay
    //     va dich cua no. Neu trung BTB va (lenh la JAL/JALR, hoac la nhanh ma bang dem doan "nhay"), IF sang dich ngay
    //     trong chu ky sau: nhay doan dung khong mat chu ky nao. Lenh tra ve (loai RET) lay dich tu dinh RAS.
    //     Bang dem 2 bit (BHT, 64 muc) doc o IF; chi so = pc (GHR_BITS = 0) hoac pc XOR lich su toan cuc (gshare).
    // ID: giai ma xong nen kiem tra lai du doan cua IF (BTB co the trung nham do tag ngan, hoac cu):
    //     - IF da nhay, lenh la nhanh/JAL ma dich BTB khac pc + imm: sua sang pc + imm (mat 1 chu ky).
    //     - IF da nhay, lenh khong phai lenh dieu khien: quay ve lenh ke tiep, xoa muc BTB do.
    //     - IF khong nhay: JAL nhay o ID; nhanh ma bang dem doan "nhay" nhay o ID; lenh tra ve (JALR rs1 = ra/t0,
    //       theo bang goi y cua dac ta) nhay toi dinh RAS o ID. Moi truong hop mat 1 chu ky (nhu ban cu).
    // EX: nhanh: so huong voi du doan (dich nhay da dung tu ID). JALR: so dich that voi dich du doan (BTB hoac RAS);
    //     khac, hoac khong co du doan, thi redirect nhu cu. Vi vay du doan sai chi lam cham, khong lam sai.
    // Cap nhat (tre 1 chu ky qua EX/MEM, chi lenh that su chay o EX: khong dong bang, khong trap):
    //     bang dem va GHR theo ket qua nhanh; BTB ghi khi nhanh nhay, JAL, JALR; RAS day khi goi ham (rd = ra/t0),
    //     lay ra khi tra ve. RAS cap nhat o EX (khong suy doan) nen khong can phuc hoi khi doan sai.
    localparam BHT_BITS = 6;                                  // 64 muc x 2 bit
    localparam PCB      = (ENABLE_C != 0) ? 1 : 2;            // bit thap nhat cua pc dung lam chi so
    localparam BTB_B    = (BTB_N > 1) ? $clog2(BTB_N) : 1;
    localparam TAGB     = BTB_TAG;
    localparam RAS_B    = (RAS_N > 1) ? $clog2(RAS_N) : 1;
    localparam GB       = (GHR_BITS > 0) ? GHR_BITS : 1;
    localparam [1:0] T_BR = 2'd0, T_JAL = 2'd1, T_JALR = 2'd2, T_RET = 2'd3;

    reg  [1:0]  bht [0:(1<<BHT_BITS)-1];                      // 00/01: khong nhay, 10/11: nhay
    reg  [GB-1:0] ghr;                                        // lich su nhanh toan cuc (cap nhat o EX)

    // BTB
    reg              btb_v   [0:BTB_N-1];
    reg [TAGB-1:0]   btb_tag [0:BTB_N-1];
    reg [31:1]       btb_tgt [0:BTB_N-1];
    reg [1:0]        btb_typ [0:BTB_N-1];
    // RAS: 2 ban, moi ban la ngan xep vong (cnt = so muc hop le, bao hoa o RAS_N; top = vi tri dinh; day khi day thi
    // de len muc cu nhat).
    //  - ban kien truc (a_*): cap nhat o EX (tre 1 chu ky), chi theo lenh that su chay xong: luon dung.
    //  - ban suy doan (s_*): cap nhat o ID khi lenh goi / tra ve roi ID (giai ma chinh xac), nen lenh tra ve nap ngay
    //    sau lenh goi da thay dia chi moi. Moi lan EX redirect (doan sai, trap, ...) cac lenh tre hon bi huy, ban suy
    //    doan duoc chep lai tu ban kien truc (gom ca cap nhat dang cho cua chinh lenh redirect). Du doan dung ban suy doan.
    localparam RN = (RAS_N > 0) ? RAS_N : 1;
    reg [31:1]       a_ras [0:RN-1];
    reg [RAS_B:0]    a_cnt;
    reg [RAS_B-1:0]  a_top;
    reg [31:1]       s_ras [0:RN-1];
    reg [RAS_B:0]    s_cnt;
    reg [RAS_B-1:0]  s_top;
    wire             ras_ok  = (RAS_N > 0) && (s_cnt != 0);         // cho ID: trang thai truoc lenh o ID
    wire [31:0]      ras_val = (RAS_N > 0) ? {s_ras[s_top], 1'b0} : 32'd0;

    // ---- IF ----
    wire [BTB_B-1:0] if_bi  = pc[PCB +: BTB_B];
    wire [TAGB-1:0]  if_bt  = pc[PCB + BTB_B +: TAGB];
    wire             btb_hit = (BTB_N > 0) && btb_v[if_bi] && (btb_tag[if_bi] == if_bt);
    wire [1:0]       if_typ = btb_typ[if_bi];
    wire [BHT_BITS-1:0] if_pidx = pc[PCB +: BHT_BITS] ^ ((GHR_BITS > 0) ? ghr : {GB{1'b0}});
    wire             t_pred;                                 // TAGE (khi TAGE = 1)
    wire [TMW-1:0]   if_tmeta;
    wire             if_ctr = (TAGE != 0) ? t_pred : bht[if_pidx][1];
    wire             if_pred = btb_hit & ((if_typ != T_BR) | if_ctr) & ((if_typ != T_RET) | if_ras_ok);
    wire [31:0]      if_ptgt = (if_typ == T_RET) ? if_ras_val : {btb_tgt[if_bi], 1'b0};

    // ---- ID ----
    wire link_rd  = (rd == 5'd1) | (rd == 5'd5);
    wire link_rs1 = (rs1 == 5'd1) | (rs1 == 5'd5);
    wire id_ret   = legal_jalr & link_rs1 & ~(link_rd & (rd == rs1));     // bang goi y: lay ra RAS
    wire id_ctl   = is_jal | legal_branch | legal_jalr;
    wire [31:0] id_seq = ifid_pc + (ifid_c ? 32'd2 : 32'd4);
    assign id_target   = ifid_pc + imm;                       // imm da chon imm_b / imm_j theo opcode
    wire id_fix_tgt = ifid_bp & (is_jal | legal_branch) & (ifid_bpt != id_target);   // BTB dich sai
    wire id_fix_seq = ifid_bp & ~id_ctl;                                             // BTB trung nham
    wire id_late    = ~ifid_bp & (is_jal | (legal_branch & ifid_ctr) | (id_ret & ras_ok & (RAS_N > 0)));
    wire id_pred_taken = legal_branch & (ifid_bp | ifid_ctr);
    // du doan dich cua JALR mang xuong EX: tu BTB (IF) hoac RAS (ID)
    wire        id_jp_v = legal_jalr & (ifid_bp | (id_ret & ras_ok & (RAS_N > 0)));
    wire [31:0] id_jp_t = ifid_bp ? ifid_bpt : ras_val;
    // khi EX cung redirect thi redirect (EX) thang nho thu tu uu tien trong khoi IF, nen khong can dieu kien them o day
    assign id_redirect = ifid_valid & ~stall & (id_fix_tgt | id_fix_seq | id_late);
    wire [31:0] id_redir_pc = id_fix_seq ? id_seq : (legal_jalr ? ras_val : id_target);
    wire        id_btb_inv  = ifid_valid & ~stall & id_fix_seq;

    // ---- RAS suy doan: cap nhat khi lenh roi ID trong chu ky nay ----
    wire id_go   = ifid_valid & ~stall & ~ex_stall & ~frz & ~redirect_q;
    wire s_push  = id_go & (is_jal | legal_jalr) & link_rd;
    wire s_pop   = id_go & id_ret;
    reg  [RAS_B:0]   s_cnt_n;
    reg  [RAS_B-1:0] s_top_n;
    reg              s_we;
    reg  [RAS_B-1:0] s_widx;
    always @* begin
        s_cnt_n = s_cnt; s_top_n = s_top; s_we = 1'b0; s_widx = s_top;
        if (s_pop & s_push) begin                           // tra ve roi goi ngay (coroutine): thay dinh
            s_we = 1'b1; if (s_cnt == 0) s_cnt_n = 1;
        end else if (s_push) begin
            s_we = 1'b1; s_widx = s_top + {{(RAS_B-1){1'b0}}, (s_cnt != 0)};
            s_top_n = s_widx; if (s_cnt != RAS_N) s_cnt_n = s_cnt + 1'b1;
        end else if (s_pop && s_cnt != 0) begin
            if (s_cnt != 1) s_top_n = s_top - 1'b1;
            s_cnt_n = s_cnt - 1'b1;
        end
    end
    // IF doc trang thai hien tai cua RAS suy doan. Da thu cho IF doc trang thai SAU thao tac cua lenh dang o ID
    // (chuyen tiep dia chi vua day): so chu ky cua ca 3 benchmark khong doi (chi co loi khi ham rong, lenh dau tien la
    // lenh tra ve) ma lai dat giai ma o ID len duong pc -> pc cua IF, nen bo.
    wire        if_ras_ok  = ras_ok;
    wire [31:0] if_ras_val = ras_val;

    // register file 31 x 32, doc combinational, ghi o WB, bypass WB -> ID
    reg  [31:0] regs [1:31];
    wire [31:0] rf_rs1 = (rs1 == 5'd0)              ? 32'd0     :
                         (wb_we && memwb_rd == rs1) ? memwb_val : regs[rs1];
    wire [31:0] rf_rs2 = (rs2 == 5'd0)              ? 32'd0     :
                         (wb_we && memwb_rd == rs2) ? memwb_val : regs[rs2];

    always @(posedge clk)
        if (wb_we) regs[memwb_rd] <= memwb_val;

    // ID/EX
    reg         idex_valid_r;
    // Lenh o EX o chu ky ngay sau redirect la lenh nham duong (da vao EX truoc khi redirect duoc ap): vo hieu bang redirect_q.
    wire        idex_valid = idex_valid_r & ~redirect_q;
    reg         idex_pred_taken;                              // du doan cua nhanh dang o EX
    reg         idex_jp_v;                                    // JALR o EX co du doan dich (BTB/RAS) hay khong
    reg  [31:0] idex_jp_t;
    reg  [5:0]  idex_pidx;                                    // chi so bang dem luc du doan (gshare: kem lich su)
    reg  [TMW-1:0] idex_tmeta;
    reg  [31:0] idex_pc, idex_instr, idex_rs1_val, idex_rs2_val, idex_imm;
    reg  [4:0]  idex_rs1, idex_rs2, idex_rd;
    reg  [2:0]  idex_funct3;
    reg         idex_f7_5;
    reg         idex_c;                                       // lenh o EX la lenh nen: pc ke tiep = pc + 2
    reg         idex_lui_r, idex_auipc_r, idex_jal_r, idex_jalr_r, idex_branch_r, idex_load_r, idex_store_r, idex_imm_op_r, idex_reg_op_r;
    reg         idex_rd_we_r;
    reg         idex_fa_mem, idex_fa_wb, idex_fb_mem, idex_fb_wb;   // forwarding: lay tu EX/MEM hoac MEM/WB
    reg         idex_illegal_r, idex_ecall_r, idex_ebreak_r, idex_mret_r, idex_csr_r, idex_mext_r, idex_wfi_r;
    reg         idex_fencei_r, idex_fence_r, idex_sret_r, idex_sfence_r;
    reg         idex_atom_r, idex_amo_r;                      // LR / SC / AMO (LR = load, SC = store, AMO riêng); A_EXT = 0 thi luon 0
    reg         idex_ipf_r, idex_iaf, idex_ipf2;                 // MMU: loi dich dia chi fetch (lenh la NOP)
    reg  [31:0] idex_ppa, idex_ppa2;                             // dia chi vat ly cua lenh (PMP)
    reg         idex_zb;                                      // lenh Zba/Zbb/Zbs/Zbc/Zicond (ket qua tu zb_out); khong can reset hay gate voi
    reg  [4:0]  idex_zop;                                     // idex_valid: bong bay khong ghi thanh ghi va ket qua cua no khong duoc dung
    // Cac co dieu khien chi co hieu luc khi idex_valid = 1. Nho vay lenh bi huy boi redirect chi can xoa idex_valid
    // (1 flip-flop) thay vi xoa ~20 co o day, giam so flip-flop ma redirect phai toi.
    wire idex_lui = idex_lui_r & idex_valid;
    wire idex_auipc = idex_auipc_r & idex_valid;
    wire idex_jal = idex_jal_r & idex_valid;
    wire idex_jalr = idex_jalr_r & idex_valid;
    wire idex_branch = idex_branch_r & idex_valid;
    wire idex_load = idex_load_r & idex_valid;
    wire idex_store = idex_store_r & idex_valid;
    wire idex_atom  = idex_atom_r  & idex_valid;
    wire idex_amo   = idex_amo_r   & idex_valid;
    wire idex_ldlike = idex_load | idex_amo | (idex_store & idex_atom);   // rd nhan ket qua o MEM: lenh dung ngay sau phai cho 1 chu ky
    wire idex_imm_op = idex_imm_op_r & idex_valid;
    wire idex_reg_op = idex_reg_op_r & idex_valid;
    wire idex_rd_we = idex_rd_we_r & idex_valid;
    wire idex_illegal = idex_illegal_r & idex_valid;
    wire idex_ecall = idex_ecall_r & idex_valid;
    wire idex_ebreak = idex_ebreak_r & idex_valid;
    wire idex_mret = idex_mret_r & idex_valid;
    wire idex_csr = idex_csr_r & idex_valid;
    wire idex_mext = idex_mext_r & idex_valid;
    wire idex_wfi = idex_wfi_r & idex_valid;
    wire idex_sret = idex_sret_r & idex_valid;
    wire idex_sfence = idex_sfence_r & idex_valid;
    wire idex_ipf = idex_ipf_r & idex_valid;

    // load-use
    assign stall = ifid_valid & idex_valid & idex_ldlike & (idex_rd != 5'd0) &
                   ((uses_rs1 & (idex_rd == rs1)) | (uses_rs2 & (idex_rd == rs2)));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idex_valid_r <= 1'b0;
            idex_lui_r    <= 1'b0; idex_auipc_r  <= 1'b0; idex_jal_r    <= 1'b0; idex_jalr_r   <= 1'b0;
            idex_branch_r <= 1'b0; idex_load_r   <= 1'b0; idex_store_r  <= 1'b0; idex_atom_r <= 1'b0; idex_amo_r <= 1'b0;
            idex_imm_op_r <= 1'b0; idex_reg_op_r <= 1'b0; idex_rd_we_r  <= 1'b0;
            idex_fa_mem <= 1'b0; idex_fa_wb  <= 1'b0; idex_fb_mem <= 1'b0; idex_fb_wb  <= 1'b0;
            idex_illegal_r <= 1'b0; idex_ecall_r <= 1'b0; idex_ebreak_r <= 1'b0;
            idex_mret_r   <= 1'b0; idex_csr_r    <= 1'b0; idex_mext_r   <= 1'b0; idex_wfi_r <= 1'b0; idex_fencei_r <= 1'b0; idex_fence_r <= 1'b0; idex_sret_r <= 1'b0; idex_sfence_r <= 1'b0; idex_ipf_r <= 1'b0;
            idex_pred_taken <= 1'b0; idex_jp_v <= 1'b0;
        end else if (ex_stall | frz) begin
            // lenh M dang chay, WFI dang cho o EX, hoac pipeline dong bang: giu nguyen ID/EX. Cho duyet bang trang:
            // toan hang da chot vao idex_rs*_val (nguon forward o MEM / WB se troi di) nen bo chon forward
            if (dwait && !frz) begin
                idex_fa_mem <= 1'b0; idex_fa_wb <= 1'b0; idex_fb_mem <= 1'b0; idex_fb_wb <= 1'b0;
            end
        end else begin
            // redirect_q chi dieu khien idex_valid_r; stall (tin hieu som) xoa cac co con lai
            idex_valid_r <= ifid_valid & ~redirect_q & ~stall;
            if (stall) begin
                idex_pred_taken <= 1'b0; idex_jp_v <= 1'b0;
                idex_lui_r    <= 1'b0; idex_auipc_r  <= 1'b0; idex_jal_r    <= 1'b0; idex_jalr_r   <= 1'b0;
                idex_branch_r <= 1'b0; idex_load_r   <= 1'b0; idex_store_r  <= 1'b0; idex_atom_r <= 1'b0; idex_amo_r <= 1'b0;
                idex_imm_op_r <= 1'b0; idex_reg_op_r <= 1'b0; idex_rd_we_r  <= 1'b0;
                idex_fa_mem <= 1'b0; idex_fa_wb  <= 1'b0; idex_fb_mem <= 1'b0; idex_fb_wb  <= 1'b0;
                idex_illegal_r <= 1'b0; idex_ecall_r <= 1'b0; idex_ebreak_r <= 1'b0;
                idex_mret_r   <= 1'b0; idex_csr_r    <= 1'b0; idex_mext_r   <= 1'b0; idex_wfi_r <= 1'b0; idex_fencei_r <= 1'b0; idex_fence_r <= 1'b0; idex_sret_r <= 1'b0; idex_sfence_r <= 1'b0; idex_ipf_r <= 1'b0;
            end else begin
                idex_pred_taken <= id_pred_taken;
                idex_jp_v       <= id_jp_v;
                idex_lui_r     <= is_lui & ifid_valid;
                idex_auipc_r   <= is_auipc & ifid_valid;
                idex_jal_r     <= is_jal & ifid_valid;
                idex_jalr_r    <= legal_jalr & ifid_valid;
                idex_branch_r  <= legal_branch & ifid_valid;
                idex_load_r    <= (legal_load | legal_lr) & ifid_valid;
                idex_store_r   <= (legal_store | legal_sc) & ifid_valid;
                idex_atom_r    <= legal_atomic & ifid_valid;
                idex_amo_r     <= legal_amo & ifid_valid;
                idex_imm_op_r  <= legal_imm & ifid_valid;
                idex_reg_op_r  <= legal_reg & ifid_valid;
                idex_rd_we_r   <= rd_we & ifid_valid;
                idex_fa_mem  <= id_fa_mem;
                idex_fa_wb   <= id_fa_wb;
                idex_fb_mem  <= id_fb_mem;
                idex_fb_wb   <= id_fb_wb;
                idex_illegal_r <= illegal & ifid_valid;
                idex_ecall_r   <= is_ecall & ifid_valid;
                idex_ebreak_r  <= is_ebreak & ifid_valid;
                idex_mret_r    <= is_mret & ifid_valid;
                idex_wfi_r     <= is_wfi & ifid_valid;
                idex_sret_r    <= is_sret & ifid_valid;
                idex_sfence_r  <= is_sfence & ifid_valid;
                idex_ipf_r     <= ifid_ipf & ifid_valid;
                idex_fencei_r  <= is_fencei & ifid_valid;
                idex_fence_r   <= legal_fence & ifid_valid;
                idex_csr_r     <= legal_csr & ifid_valid;
                idex_mext_r    <= (is_reg & f7_m) & ifid_valid;
            end
        end
    end

    // Truong du lieu cua ID/EX khong can xoa khi chen bong bay (co idex_valid va cac co dieu khien xoa roi),
    // nen khong de redirect/stall dieu khien enable cua chung: cat tai cao cua tin hieu redirect.
    always @(posedge clk) begin
        if (!(ex_stall | frz)) begin
            idex_pc      <= ifid_pc;
            idex_instr   <= ifid_raw;      // chi dung cho dia chi CSR (lenh 32 bit), mtval va vet
            idex_c       <= ifid_c;
            idex_jp_t    <= id_jp_t;
            idex_pidx    <= ifid_pidx;
            idex_tmeta   <= ifid_tmeta;
            idex_rs1_val <= rf_rs1;
            idex_rs2_val <= rf_rs2;
            idex_imm     <= imm;
            idex_rs1     <= rs1;
            idex_rs2     <= rs2;
            idex_rd      <= rd;
            idex_funct3  <= funct3;
            idex_f7_5    <= instr[30];
            idex_zop     <= zb_op;
            idex_zb      <= id_zb;
            idex_iaf     <= ifid_iaf;
            idex_ipf2    <= ifid_ipf2;
            idex_ppa     <= ifid_ppa;
            idex_ppa2    <= ifid_ppa2;
        end else if (dwait && !frz) begin    // cho duyet bang trang cho load / store: chot toan hang da forward
            idex_rs1_val <= op_a;
            idex_rs2_val <= op_b;
        end
    end

    // ============================================================
    // EX
    // ============================================================
    reg         exmem_valid, exmem_rd_we, exmem_load, exmem_store, exmem_fence, exmem_amo;
    reg  [31:0] exmem_pc, exmem_instr, exmem_result, exmem_store_val, exmem_tva;
    reg         exmem_tirq, exmem_trap, exmem_icnt;
    reg  [4:0]  exmem_rd;
    reg  [2:0]  exmem_funct3;

    // forwarding: tin hieu chon duoc tinh san o ID (khi lenh nay con o ID, lenh sinh ket qua dang o EX hoac MEM,
    // luc lenh nay toi EX thi chung da sang MEM hoac WB). Nho vay tang EX khong con phep so sanh so thanh ghi.
    assign id_fa_mem = idex_valid  & idex_rd_we  & (idex_rd  != 5'd0) & (idex_rd  == rs1);
    assign id_fa_wb  = exmem_valid & exmem_rd_we & (exmem_rd != 5'd0) & (exmem_rd == rs1);
    assign id_fb_mem = idex_valid  & idex_rd_we  & (idex_rd  != 5'd0) & (idex_rd  == rs2);
    assign id_fb_wb  = exmem_valid & exmem_rd_we & (exmem_rd != 5'd0) & (exmem_rd == rs2);

    wire [31:0] op_a = idex_fa_mem ? exmem_result : (idex_fa_wb ? memwb_val : idex_rs1_val);
    wire [31:0] op_b = idex_fb_mem ? exmem_result : (idex_fb_wb ? memwb_val : idex_rs2_val);

    wire [31:0] alu_b = (idex_reg_op | idex_branch) ? op_b : idex_imm;

    wire do_sub = idex_reg_op & idex_f7_5;
    wire do_sra = idex_f7_5;
    wire [4:0] shamt = alu_b[4:0];

    wire signed [31:0] op_a_s = op_a;
    wire [31:0] sra_out = op_a_s >>> shamt;
    wire [31:0] srl_out = op_a >> shamt;

    reg [31:0] alu_out;
    always @* begin
        case (idex_funct3)
            3'b000: alu_out = do_sub ? (op_a - alu_b) : (op_a + alu_b);
            3'b001: alu_out = op_a << shamt;
            3'b010: alu_out = ($signed(op_a) < $signed(alu_b)) ? 32'd1 : 32'd0;
            3'b011: alu_out = (op_a < alu_b) ? 32'd1 : 32'd0;
            3'b100: alu_out = op_a ^ alu_b;
            3'b101: alu_out = do_sra ? sra_out : srl_out;
            3'b110: alu_out = op_a | alu_b;
            3'b111: alu_out = op_a & alu_b;
        endcase
    end

    // ---- Zba / Zbb / Zbs / Zbc / Zicond o EX: moi lenh 1 chu ky, toan hang tu mux forwarding (op_a, alu_b) ----
    // Voi dang immediate (clz.. rori, bclri...) alu_b = idex_imm nen shamt = instr[24:20] giong dang thanh ghi.
    // Phan mo rong dang tat (tham so = 0) khong bao gio co idex_zb nhung cung duoc rut gon thanh hang so 0 de
    // cong cu tong hop khong giu logic thua.
    wire [31:0] zb_a = op_a;
    wire [31:0] zb_b = alu_b;
    wire [4:0]  zb_sh = zb_b[4:0];

    function [5:0] zb_clz32(input [31:0] x);       // so bit 0 dau; x = 0 -> 32
        integer i; reg done;
        begin
            zb_clz32 = 6'd32; done = 1'b0;
            for (i = 31; i >= 0; i = i - 1)
                if (!done && x[i]) begin zb_clz32 = 6'd31 - i[5:0]; done = 1'b1; end
        end
    endfunction
    function [31:0] zb_rev32(input [31:0] x);
        integer i;
        begin for (i = 0; i < 32; i = i + 1) zb_rev32[i] = x[31 - i]; end
    endfunction
    function [5:0] zb_pop32(input [31:0] x);
        integer i;
        begin zb_pop32 = 6'd0; for (i = 0; i < 32; i = i + 1) zb_pop32 = zb_pop32 + {5'd0, x[i]}; end
    endfunction
    function [63:0] zb_clmul64(input [31:0] x, input [31:0] y);   // nhan khong nho (carry-less), tich day du 64 bit
        integer i;
        begin
            zb_clmul64 = 64'd0;
            for (i = 0; i < 32; i = i + 1)
                if (y[i]) zb_clmul64 = zb_clmul64 ^ ({32'd0, x} << i);
        end
    endfunction

    wire [31:0] z_sh1   = {zb_a[30:0], 1'b0} + zb_b;
    wire [31:0] z_sh2   = {zb_a[29:0], 2'b0} + zb_b;
    wire [31:0] z_sh3   = {zb_a[28:0], 3'b0} + zb_b;
    wire        z_lt    = ($signed(zb_a) < $signed(zb_b));
    wire        z_ltu   = (zb_a < zb_b);
    wire        z_rol   = (idex_zop == Z_ROL);
    wire [4:0]  z_ramt  = z_rol ? (5'd0 - zb_sh) : zb_sh;                 // rol = quay phai (32 - sh): dung chung 1 bo quay
    wire [63:0] z_rot   = {zb_a, zb_a} >> z_ramt;
    wire [31:0] z_bit   = 32'd1 << zb_sh;
    wire [63:0] z_clm   = (ZBC != 0) ? zb_clmul64(zb_a, zb_b) : 64'd0;
    wire [5:0]  z_ctz_r = zb_clz32(zb_rev32(zb_a));
    reg  [31:0] zb_out;
    always @* begin
        case (idex_zop)
            Z_SH1ADD: zb_out = (ZBA != 0) ? z_sh1 : 32'd0;
            Z_SH2ADD: zb_out = (ZBA != 0) ? z_sh2 : 32'd0;
            Z_SH3ADD: zb_out = (ZBA != 0) ? z_sh3 : 32'd0;
            Z_ANDN:   zb_out = (ZBB != 0) ? (zb_a & ~zb_b) : 32'd0;
            Z_ORN:    zb_out = (ZBB != 0) ? (zb_a | ~zb_b) : 32'd0;
            Z_XNOR:   zb_out = (ZBB != 0) ? ~(zb_a ^ zb_b) : 32'd0;
            Z_CLZ:    zb_out = (ZBB != 0) ? {26'd0, zb_clz32(zb_a)} : 32'd0;
            Z_CTZ:    zb_out = (ZBB != 0) ? {26'd0, z_ctz_r} : 32'd0;
            Z_CPOP:   zb_out = (ZBB != 0) ? {26'd0, zb_pop32(zb_a)} : 32'd0;
            Z_SEXTB:  zb_out = (ZBB != 0) ? {{24{zb_a[7]}}, zb_a[7:0]} : 32'd0;
            Z_SEXTH:  zb_out = (ZBB != 0) ? {{16{zb_a[15]}}, zb_a[15:0]} : 32'd0;
            Z_ZEXTH:  zb_out = (ZBB != 0) ? {16'd0, zb_a[15:0]} : 32'd0;
            Z_MAX:    zb_out = (ZBB != 0) ? (z_lt  ? zb_b : zb_a) : 32'd0;
            Z_MAXU:   zb_out = (ZBB != 0) ? (z_ltu ? zb_b : zb_a) : 32'd0;
            Z_MIN:    zb_out = (ZBB != 0) ? (z_lt  ? zb_a : zb_b) : 32'd0;
            Z_MINU:   zb_out = (ZBB != 0) ? (z_ltu ? zb_a : zb_b) : 32'd0;
            Z_ROL, Z_ROR: zb_out = (ZBB != 0) ? z_rot[31:0] : 32'd0;
            Z_ORCB:   zb_out = (ZBB != 0) ? {{8{|zb_a[31:24]}}, {8{|zb_a[23:16]}}, {8{|zb_a[15:8]}}, {8{|zb_a[7:0]}}} : 32'd0;
            Z_REV8:   zb_out = (ZBB != 0) ? {zb_a[7:0], zb_a[15:8], zb_a[23:16], zb_a[31:24]} : 32'd0;
            Z_BCLR:   zb_out = (ZBS != 0) ? (zb_a & ~z_bit) : 32'd0;
            Z_BEXT:   zb_out = (ZBS != 0) ? {31'd0, zb_a[zb_sh]} : 32'd0;
            Z_BINV:   zb_out = (ZBS != 0) ? (zb_a ^ z_bit) : 32'd0;
            Z_BSET:   zb_out = (ZBS != 0) ? (zb_a | z_bit) : 32'd0;
            Z_CLMUL:  zb_out = z_clm[31:0];
            Z_CLMULR: zb_out = z_clm[62:31];
            Z_CLMULH: zb_out = z_clm[63:32];
            Z_CZEQZ:  zb_out = (ZICOND != 0) ? ((zb_b == 32'd0) ? 32'd0 : zb_a) : 32'd0;
            Z_CZNEZ:  zb_out = (ZICOND != 0) ? ((zb_b != 32'd0) ? 32'd0 : zb_a) : 32'd0;
            default:  zb_out = 32'd0;
        endcase
    end

    // nhan/chia
    wire        m_done;
    wire [31:0] m_result;
    rv32m #(.PREP(1), .STEPS(2), .MUL_LAT(MUL_LAT)) u_m (
        .clk(clk), .rst_n(rst_n),
        .req(idex_mext), .funct3(idex_funct3),
        .a(op_a), .b(op_b),
        .done(m_done), .result(m_result)
    );
    wire   wfi_wait;                                   // WFI o EX va chua co ngat nao dang cho (gan o phan ngat)
    wire   dwait;                                      // load / store cho duyet bang trang (MMU)
    assign ex_stall = (idex_mext & ~m_done) | wfi_wait | dwait;

    // nhanh
    wire eq  = (op_a == op_b);
    wire lt  = ($signed(op_a) < $signed(op_b));
    wire ltu = (op_a < op_b);
    reg take_branch;
    always @* begin
        case (idex_funct3)
            3'b000:  take_branch = eq;
            3'b001:  take_branch = ~eq;
            3'b100:  take_branch = lt;
            3'b101:  take_branch = ~lt;
            3'b110:  take_branch = ltu;
            3'b111:  take_branch = ~ltu;
            default: take_branch = 1'b0;
        endcase
    end

    wire [31:0] pc_imm      = idex_pc + idex_imm;                       // dich cua nhanh va JAL
    wire [31:0] pc_next     = idex_pc + (idex_c ? 32'd2 : 32'd4);       // lenh ke tiep tuan tu
    wire [31:0] jalr_target = (op_a + idex_imm) & 32'hFFFF_FFFE;

    // ---- CSR (doc/ghi o EX, dung thu tu chuong trinh) ----
    reg         mstatus_mie, mstatus_mpie;
    reg  [31:2] mtvec_r;
    reg         mtvec_vec;                             // mtvec.MODE = 1: ngat nhay toi BASE + 4 * ma nguyen nhan
    reg  [31:1] mepc_r;                                    // bit 1 chi co nghia khi ENABLE_C = 1
    wire [31:0] mepc_v = {mepc_r[31:2], mepc_r[1] & (ENABLE_C != 0), 1'b0};
    reg  [31:0] mscratch, mcause_r, mtval_r;
    reg         mie_mtie, mie_meie, mie_msie;
    reg         mip_mtip, mip_meip, mip_msip;              // chan ngat duoc dong bo qua 1 flip-flop
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin mip_mtip <= 1'b0; mip_meip <= 1'b0; mip_msip <= 1'b0; end
        else        begin mip_mtip <= irq_timer; mip_meip <= irq_ext; mip_msip <= irq_soft; end
    end

    // ---- che do Supervisor / User (SU = 1) ----
    // priv: 0 U, 1 S, 3 M. SU = 0: cac thanh ghi duoi day khong dung (rut gon thanh hang), lo chi co che do M.
    // Theo Spike khi khong co MMU (satp chi doc 0, SUM / MXR / TVM doc 0, medeleg khong co page fault): mstatus.FS ghi
    // duoc (SD = FS == 3), MPP sau reset va sau MRET la U, MPP = 2 ghi thanh U; WFI o U, hoac o S khi TW = 1, la lenh
    // bat hop le; SRET o U, hoac o S khi TSR = 1, bat hop le; doc cycle / instret / hpmcounter o S / U can
    // mcounteren (va scounteren o U). Ngat S (SSIP / STIP / SEIP) chi do phan mem ghi mip / sip.
    reg  [1:0]  priv_r;
    assign      priv = (SU != 0) ? priv_r : 2'd3;
    reg         st_sie, st_spie, st_spp, st_mprv, st_tw, st_tsr;
    reg         st_sum, st_mxr, st_tvm;                // chi co khi MMU = 1
    reg         satp_mode;                             // satp (MMU = 1): MODE (1 = Sv32), ASID 9 bit, PPN 22 bit
    reg  [8:0]  satp_asid;
    reg  [21:0] satp_ppn;
    wire [31:0] satp_v = {satp_mode, satp_asid, satp_ppn} & {32{(SU != 0) && (MMU != 0)}};
    wire        mmu_on = (SU != 0) & (MMU != 0);
    wire        sum_v = mmu_on & st_sum, mxr_v = mmu_on & st_mxr, tvm_v = mmu_on & st_tvm;
    reg  [1:0]  st_mpp, st_fs;
    reg  [31:2] stvec_r;
    reg         stvec_vec;
    reg  [31:1] sepc_r;
    wire [31:0] sepc_v = {sepc_r[31:2], sepc_r[1] & (ENABLE_C != 0), 1'b0};
    reg  [31:0] sscratch, scause_r, stval_r, mcounteren, scounteren;
    reg  [9:0]  medeleg_r;                                 // bit 0-9 cua medeleg (0 chi ghi duoc khi khong co C)
    reg         medeleg19;                                 // loi phan cung (Spike cho uy quyen khi co Zicntr)
    reg         mideleg_ssi, mideleg_sti, mideleg_sei;
    reg         mie_ssie, mie_stie, mie_seie;
    reg         mip_ssip, mip_stip, mip_seip;              // chi phan mem ghi
    wire        st_sd = (st_fs == 2'b11);
    wire [31:0] mstatus_v = (SU != 0) ?
        {st_sd, 8'b0, st_tsr, st_tw, tvm_v, mxr_v, sum_v, st_mprv, 2'b00, st_fs, st_mpp, 2'b00, st_spp, mstatus_mpie,
         1'b0, st_spie, 1'b0, mstatus_mie, 1'b0, st_sie, 1'b0} :
        {19'b0, 2'b11, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
    wire [31:0] sstatus_v = {st_sd, 11'b0, mxr_v, sum_v, 3'b0, st_fs, 4'b0, st_spp, 2'b0, st_spie, 3'b0, st_sie, 1'b0};
    wire [31:0] mie_v  = {20'b0, mie_meie, 1'b0, mie_seie & (SU != 0), 1'b0, mie_mtie, 1'b0, mie_stie & (SU != 0), 1'b0,
                          mie_msie, 1'b0, mie_ssie & (SU != 0), 1'b0};
    wire [31:0] mip_v  = {20'b0, mip_meip, 1'b0, mip_seip & (SU != 0), 1'b0, mip_mtip, 1'b0, mip_stip & (SU != 0), 1'b0,
                          mip_msip, 1'b0, mip_ssip & (SU != 0), 1'b0};
    wire [31:0] mideleg_v = {22'b0, mideleg_sei, 3'b0, mideleg_sti, 3'b0, mideleg_ssi, 1'b0} & {32{SU != 0}};
    reg  [2:0]  medeleg_pf;                                // bit 12, 13, 15 (loi trang, chi khi MMU = 1)
    wire [31:0] medeleg_v = {12'b0, medeleg19, 3'b0, medeleg_pf[2] & mmu_on, 1'b0, medeleg_pf[1:0] & {2{mmu_on}},
                             2'b0, medeleg_r} & {32{SU != 0}};

    wire [11:0] csr_addr = idex_instr[31:20];
    reg  [31:0] csr_rdata;
    always @* begin
        case (csr_addr)
            12'h300: csr_rdata = mstatus_v;
            12'h301: csr_rdata = 32'h4000_1100 | ((ENABLE_C != 0) ? 32'h4 : 32'h0) | ((A_EXT != 0) ? 32'h1 : 32'h0) |   // MXL = 32, I, M (va C khi ENABLE_C, A khi A_EXT)
                                 ((SU != 0) ? 32'h0014_0000 : 32'h0);                    // S, U
            12'h304: csr_rdata = mie_v;
            12'h305: csr_rdata = {mtvec_r, 1'b0, mtvec_vec};
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = mepc_v;
            12'h342: csr_rdata = mcause_r;
            12'h343: csr_rdata = mtval_r;
            12'h344: csr_rdata = mip_v;
            default: csr_rdata = cnt_rdata | pmp_rdata | su_rdata;   // bo dem / PMP / CSR S (0 neu khong phai);
        endcase                                                      // 0xF14 mhartid, satp = 0
    end
    // CSR cua che do S / U: SU = 0 thi bang 0 de tong hop bo luon cac thanh ghi (CSR nay khong ton tai, trap o ID)
    reg  [31:0] su_rdata;
    always @* begin
        case (csr_addr)
            12'h100: su_rdata = sstatus_v;
            12'h104: su_rdata = mie_v & mideleg_v;
            12'h105: su_rdata = {stvec_r, 1'b0, stvec_vec};
            12'h106: su_rdata = scounteren;
            12'h140: su_rdata = sscratch;
            12'h141: su_rdata = sepc_v;
            12'h142: su_rdata = scause_r;
            12'h143: su_rdata = stval_r;
            12'h144: su_rdata = mip_v & mideleg_v;
            12'h302: su_rdata = medeleg_v;
            12'h303: su_rdata = mideleg_v;
            12'h306: su_rdata = mcounteren;
            12'h180: su_rdata = satp_v;
            default: su_rdata = 32'd0;
        endcase
        if (SU == 0) su_rdata = 32'd0;
    end

    reg  [31:0] cnt_rdata;                                 // doc bo dem (Zicntr / Zihpm), xem cuoi module
    reg  [31:0] pmp_rdata;                                 // doc CSR PMP, xem cuoi module
    wire        pmp_ifault, pmp_lfault, pmp_sfault;        // vi pham PMP cua lenh o EX (fetch / load / store)
    wire [31:0] pmp_itval;                                 // mtval khi fetch bi PMP cam (pc hoac pc + 2)
    wire        cnt_icnt;
    wire        cnt_wr_ir;             // EX ghi minstret / minstreth (xem Zicntr)
    wire        csr_we_req = (idex_funct3[1:0] == 2'b01) | (idex_rs1 != 5'd0);
    wire [31:0] csr_src    = idex_funct3[2] ? {27'b0, idex_rs1} : op_a;
    reg  [31:0] csr_new;
    always @* begin
        case (idex_funct3[1:0])
            2'b01:   csr_new = csr_src;
            2'b10:   csr_new = csr_rdata | csr_src;
            default: csr_new = csr_rdata & ~csr_src;
        endcase
    end
    // quyen theo che do (chi khi SU = 1): CSR cap cao hon che do hien tai, bo dem bi mcounteren / scounteren chan,
    // MRET ngoai che do M, SRET o U (hoac S khi TSR), WFI o U (hoac S khi TW) -> lenh bat hop le
    wire        cnt_user  = (csr_addr[11:8] == 4'hC) & (csr_addr[6:5] == 2'b00);
    wire        cnt_en    = (priv == 2'd3) | (mcounteren[csr_addr[4:0]] & ((priv == 2'd1) | scounteren[csr_addr[4:0]]));
    wire        ex_priv_ill = (SU != 0) & (
                    (idex_csr & ((csr_addr[9:8] > priv) | (cnt_user & ~cnt_en) |
                                 ((csr_addr == 12'h180) & (priv == 2'd1) & tvm_v))) |
                    (idex_sfence & ((priv == 2'd0) | ((priv == 2'd1) & tvm_v))) |
                    (idex_mret & (priv != 2'd3)) |
                    (idex_sret & ((priv == 2'd0) | ((priv == 2'd1) & st_tsr))) |
                    (idex_wfi & ((priv == 2'd0) | ((priv != 2'd3) & st_tw))));
    wire        ex_illegal = idex_illegal | ex_priv_ill;
    // ---- ngat ----
    // Chi xet tren thanh ghi (mstatus, mie, mip, mideleg, priv) va idex_valid nen la tin hieu som. Lenh M dang chay
    // khong bi ngat; WFI cung khong bi ngat (no ket thuc khi co ngat dang cho, ngat roi vao lenh sau no).
    // Ngat ve M khi khong uy quyen va (priv < M hoac MIE); ve S khi uy quyen (mideleg) va (priv = U hoac S co SIE).
    // Uu tien: MEI, MSI, MTI, SEI, SSI, STI (ngat ve M truoc ngat ve S).
    wire pe_mei = mip_meip & mie_meie;
    wire pe_msi = mip_msip & mie_msie;
    wire pe_mti = mip_mtip & mie_mtie;
    wire pe_sei = (SU != 0) & mip_seip & mie_seie;
    wire pe_ssi = (SU != 0) & mip_ssip & mie_ssie;
    wire pe_sti = (SU != 0) & mip_stip & mie_stie;
    wire m_en   = (priv != 2'd3) | mstatus_mie;
    wire s_en   = (priv == 2'd0) | ((priv == 2'd1) & st_sie);
    wire cm_mei = pe_mei & m_en, cm_msi = pe_msi & m_en, cm_mti = pe_mti & m_en;
    wire cm_sei = pe_sei & ~mideleg_sei & m_en, cm_ssi = pe_ssi & ~mideleg_ssi & m_en, cm_sti = pe_sti & ~mideleg_sti & m_en;
    wire cs_sei = pe_sei & mideleg_sei & s_en, cs_ssi = pe_ssi & mideleg_ssi & s_en, cs_sti = pe_sti & mideleg_sti & s_en;
    wire irq_m     = cm_mei | cm_msi | cm_mti | cm_sei | cm_ssi | cm_sti;
    wire irq_s     = cs_sei | cs_ssi | cs_sti;
    wire [3:0] irq_code = irq_m ? (cm_mei ? 4'd11 : cm_msi ? 4'd3 : cm_mti ? 4'd7 : cm_sei ? 4'd9 : cm_ssi ? 4'd1 : 4'd5)
                                : (cs_sei ? 4'd9 : cs_ssi ? 4'd1 : 4'd5);
    wire irq_pend  = pe_mei | pe_msi | pe_mti | pe_sei | pe_ssi | pe_sti;
    wire irq_any   = irq_m | irq_s;
    wire irq_take  = irq_any & idex_valid & ~idex_mext_r & ~idex_wfi_r & ~frz & ~dwait;
    assign wfi_wait = idex_wfi & ~irq_pend & ~ex_priv_ill;
`ifdef RISCV_FORMAL
    assign fv_wfi_wait = wfi_wait;
`endif

    wire csr_write = idex_csr & csr_we_req & ~irq_take & ~frz & ~ex_priv_ill;   // idex_csr chi bat cho CSR hop le

    // ---- trap ----
    // dia chi nhay phai chia het cho 4 khi khong co lenh nen; voi C chi can chia het cho 2 (luon dung: imm chan,
    // JALR xoa bit 0) nen khong bao gio lech
    wire misaligned = (ENABLE_C == 0) & ((idex_jal & pc_imm[1]) | (idex_jalr & jalr_target[1]) |
                                         (idex_branch & take_branch & pc_imm[1]));
    wire [31:0] bad_target = idex_jal ? pc_imm : (idex_jalr ? jalr_target : pc_imm);

    // load/store lech dia chi: chi can 2 bit thap cua dia chi hieu dung (cong 2 bit, khong cho adder 32 bit)
    wire [1:0]  ea_lo = op_a[1:0] + idex_imm[1:0];
    wire [31:0] ea    = op_a + idex_imm;
    // MISALIGNED = 1: khong trap, tang MEM tu xu ly (xem phan MEM)
    wire ld_misal = (MISALIGNED == 0) & idex_load  &
                    (((idex_funct3[1:0] == 2'b01) & ea_lo[0]) | ((idex_funct3[1:0] == 2'b10) & (ea_lo != 2'b00)));
    wire st_misal = (MISALIGNED == 0) & idex_store &
                    (((idex_funct3[1:0] == 2'b01) & ea_lo[0]) | ((idex_funct3[1:0] == 2'b10) & (ea_lo != 2'b00)));
    // LR / SC / AMO lech dia chi luon trap (ke ca MISALIGNED = 1): LR cause 4, SC va AMO cause 6, mtval = dia chi
    wire at_misal = idex_atom & (ea_lo != 2'b00);
    wire ld_trap = ld_misal | (idex_load & at_misal);
    wire st_trap = st_misal | ((idex_store | idex_amo) & at_misal);

    // ---- MMU Sv32 (SU = 1, MMU = 1): dich dia chi load / store o EX, duyet bang trang, SFENCE.VMA ----
    // Che do hieu dung cua load / store la MPP khi MPRV = 1. TLB truot: EX dung (dwait), toan hang da forward duoc chot,
    // bo duyet dung cong bo nho du lieu khi tang MEM ranh; xong thi TLB trung (hoac co ket qua loi) va lenh chay tiep.
    // Quyen kiem moi lan dung: load can R (hoac X khi MXR), store can W; trang U: S can SUM, U bat buoc trang U;
    // A = 0, hoac store voi D = 0 -> loi trang (khong tu cap nhat A / D, giong Spike khong co Svadu).
    wire [1:0]  pd = ((SU != 0) & st_mprv) ? st_mpp : priv;
    assign      xi = mmu_on & satp_mode & (priv != 2'd3);
    wire        xd = mmu_on & satp_mode & (pd != 2'd3);
    wire        d_hit;
    wire [33:0] d_pa;
    wire [5:0]  d_fl;
    reg         dfr_v, dfr_af;                         // lan duyet cho load / store da loi
    reg  [31:0] dfr_va;
    wire        d_acc   = (idex_load | idex_store | idex_amo) & ~ld_trap & ~st_trap;
    wire        d_rec   = dfr_v & (dfr_va == ea);
    wire        d_wr    = idex_store | idex_amo;        // SC, AMO dich nhu store (AMO can ca R va W; W khong co R la ma hoa du tru)
    wire        d_bad   = (d_wr ? ~d_fl[1] : ~(d_fl[0] | (mxr_v & d_fl[2]))) |
                          ((pd == 2'd1) ? (d_fl[3] & ~sum_v) : ~d_fl[3]) | ~d_fl[4] | (d_wr & ~d_fl[5]);
    wire        d_pf    = xd & d_acc & ((d_hit & d_bad) | (d_rec & ~dfr_af));
    wire        d_af    = xd & d_acc & ((d_hit & ~d_bad & (d_pa[33:32] != 2'b00)) | (d_rec & dfr_af));
    assign      dwait   = xd & d_acc & ~d_hit & ~d_rec;
    wire [31:0] d_paddr = xd ? d_pa[31:0] : ea;
    // bo duyet dung chung: load / store uu tien hon fetch; ket qua loi duoc ghi lai theo dia chi ao
    reg         wk_busy, wk_d;
    reg  [31:0] wk_va;
    wire        wk_start = ~wk_busy & (dwait | i_need) & ~mmu_flush;
    wire        mmu_done, mmu_pf, mmu_af, mmu_mreq, mmu_pte_ok;
    wire [33:0] mmu_maddr;
    wire        mem_busy = exmem_valid & (exmem_load | exmem_store | exmem_amo | exmem_fence);
    generate if (SU != 0 && MMU != 0) begin : g_mmu
        rv32_mmu #(.TLB_N(TLB_N)) u_mmu (
            .clk(clk), .rst_n(rst_n), .asid(satp_asid), .root_ppn(satp_ppn), .flush(mmu_flush),
            .i_va(i_va), .i_hit(i_hit), .i_pa(i_pa), .i_fl(i_fl),
            .d_va(ea), .d_hit(d_hit), .d_pa(d_pa), .d_fl(d_fl),
            .req(wk_busy | wk_start), .req_va(dwait ? ea : i_va), .done(mmu_done), .pf(mmu_pf), .af(mmu_af),
            .m_req(mmu_mreq), .m_addr(mmu_maddr), .m_grant(~mem_busy), .m_ready(dmem_ready), .m_rdata(dmem_rdata),
            .pte_ok(mmu_pte_ok));
    end else begin : g_no_mmu
        assign i_hit = 1'b0; assign i_pa = 34'd0; assign i_fl = 6'd0;
        assign d_hit = 1'b0; assign d_pa = 34'd0; assign d_fl = 6'd0;
        assign mmu_done = 1'b0; assign mmu_pf = 1'b0; assign mmu_af = 1'b0; assign mmu_mreq = 1'b0;
        assign mmu_maddr = 34'd0;
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wk_busy <= 1'b0; wk_d <= 1'b0; ifr_v <= 1'b0; dfr_v <= 1'b0;
        end else begin
            if (mmu_flush)          wk_busy <= 1'b0;
            else if (wk_start)      begin wk_busy <= 1'b1; wk_d <= dwait; wk_va <= dwait ? ea : i_va; end
            else if (mmu_done)      wk_busy <= 1'b0;
            if (mmu_done && !mmu_flush && (mmu_pf || mmu_af) && !wk_d) begin
                ifr_v <= 1'b1; ifr_va <= wk_va; ifr_af <= mmu_af;
            end else if (redirect_q || mmu_flush) ifr_v <= 1'b0;
            if (mmu_done && !mmu_flush && (mmu_pf || mmu_af) && wk_d) begin
                dfr_v <= 1'b1; dfr_va <= wk_va; dfr_af <= mmu_af;
            end else if ((!ex_stall && !frz) || redirect_q) dfr_v <= 1'b0;  // lenh da roi EX
        end
    end

    wire trap_ex = irq_take | idex_ipf | pmp_ifault | ex_illegal | idex_ecall | idex_ebreak | misaligned | ld_trap |
                   st_trap | d_pf | d_af | pmp_lfault | pmp_sfault;
    wire mret_ex = idex_mret & ~irq_take & ~frz & ~ex_priv_ill;
    wire sret_ex = idex_sret & ~irq_take & ~frz & ~ex_priv_ill;
    wire sfence_ex = idex_sfence & ~irq_take & ~frz & ~ex_priv_ill;
    wire satp_wr   = csr_write & (csr_addr == 12'h180) & mmu_on;
    assign mmu_flush = sfence_ex | satp_wr;                 // xoa TLB; lenh sau duoc nap lai voi anh xa moi

    reg [31:0] trap_cause, trap_tval;
    always @* begin
        if (irq_take)           begin trap_cause = {1'b1, 27'd0, irq_code};             trap_tval = 32'd0; end
        else if (idex_ipf)      begin trap_cause = idex_iaf ? 32'd1 : 32'd12;            // loi dich dia chi fetch
                                      trap_tval = idex_ipf2 ? idex_pc + 32'd2 : idex_pc; end
        else if (pmp_ifault)    begin trap_cause = 32'd1;  trap_tval = pmp_itval;   end   // fetch bi PMP cam
        else if (ex_illegal)    begin trap_cause = 32'd2;  trap_tval = idex_instr; end
        else if (idex_ecall)    begin trap_cause = {28'd0, 2'b10, priv}; trap_tval = 32'd0; end   // 8 U, 9 S, 11 M
        else if (idex_ebreak)   begin trap_cause = 32'd3;  trap_tval = idex_pc;    end
        else if (ld_trap)       begin trap_cause = 32'd4;  trap_tval = ea;         end
        else if (st_trap)       begin trap_cause = 32'd6;  trap_tval = ea;         end
        else if (d_pf)          begin trap_cause = d_wr ? 32'd15 : 32'd13; trap_tval = ea; end   // loi trang
        else if (d_af)          begin trap_cause = d_wr ? 32'd7 : 32'd5;   trap_tval = ea; end   // loi truy cap
        else if (pmp_lfault)    begin trap_cause = 32'd5;  trap_tval = ea;         end   // load bi PMP cam
        else if (pmp_sfault)    begin trap_cause = 32'd7;  trap_tval = ea;         end   // store bi PMP cam
        else                    begin trap_cause = 32'd0;  trap_tval = bad_target; end
    end
    // trap ve S: ngat tu nhom S da uy quyen, hoac exception uy quyen qua medeleg khi dang o U / S
    wire exc_deleg = (priv != 2'd3) & medeleg_v[trap_cause[4:0]];
    wire trap_s    = (SU != 0) & (irq_take ? ~irq_m : exc_deleg);

    // doan sai: nhanh thuc te khac du doan. Dich khi doan sai: doan "nhay" -> chay tiep pc+4; doan "khong nhay" -> pc+imm.
    // JAL da nhay o ID nen khong con redirect o EX. redirect_pc khong phu thuoc ket qua so sanh nhanh.
    wire mispredict    = idex_branch & (take_branch ^ idex_pred_taken);
    // JALR: dich du doan (BTB o IF hoac RAS o ID) dung thi khong redirect
    wire jalr_ok       = idex_jp_v & (idex_jp_t == jalr_target);
    wire jalr_miss     = idex_jalr & ~jalr_ok;
    // FENCE.I: moi store cu hon da xong (store o MEM chua xong thi pipeline dang dong bang), nen xoa cache lenh ngay
    // va nap lai tu lenh ke tiep; cac lenh sau FENCE.I da nap vao IF/ID bi huy boi redirect
    wire fencei_ex     = idex_fencei_r & idex_valid & ~irq_take & ~frz;
    assign icache_flush = fencei_ex;
    // dong bang: lenh o EX se duoc xet lai khi pipeline chay tiep, nen chua redirect
    assign redirect    = (trap_ex | mret_ex | sret_ex | jalr_miss | mispredict | fencei_ex | sfence_ex | satp_wr) & ~frz;
    // xtvec vectored: chi ngat (exception van ve BASE); ma nguyen nhan cua ngat la 1 / 3 / 5 / 7 / 9 / 11
    wire [31:2] tvec_b     = trap_s ? stvec_r : mtvec_r;
    wire        tvec_v     = trap_s ? stvec_vec : mtvec_vec;
    wire [31:2] trap_base  = (irq_take & tvec_v) ? tvec_b + {26'd0, trap_cause[3:0]} : tvec_b;
    assign redirect_pc = trap_ex ? {trap_base, 2'b00} :
                         mret_ex ? mepc_v           :
                         sret_ex ? sepc_v           :
                         (fencei_ex | sfence_ex | satp_wr) ? pc_next :
                         idex_jalr ? jalr_target : (idex_pred_taken ? pc_next : pc_imm);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    redirect_q <= 1'b0;
        else if (!frz) redirect_q <= redirect;        // dong bang: giu redirect chua duoc IF dung toi
    end
    always @(posedge clk) if (!frz) redirect_pc_q <= redirect_pc;

    // Ghi CSR khi trap cung tre 1 chu ky: trap_ex phu thuoc ket qua so sanh nhanh (dich nhanh lech), nen khong de no
    // dieu khien enable cua ~100 flip-flop mepc/mcause/mtval cung chu ky. Lenh o EX chu ky sau da bi redirect_q vo hieu
    // va lenh dau tien cua trinh xu ly trap toi EX sau it nhat 3 chu ky, nen ghi tre khong doi hanh vi (ke ca priv).
    reg         trap_q;
    reg  [30:0] tepc_q;
    reg  [3:0]  tcause_q;
    reg         tint_q, ts_q;
    reg  [1:0]  tpriv_q;
    reg  [31:0] ttval_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) trap_q <= 1'b0;
        else        trap_q <= trap_ex & ~frz;
    end
    always @(posedge clk) begin
        tepc_q       <= idex_pc[31:1];
        tcause_q     <= trap_cause[3:0];
        tint_q       <= trap_cause[31];
        ttval_q      <= trap_tval;
        ts_q         <= trap_s;
        tpriv_q      <= priv;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mtvec_r      <= 30'd0;
            mtvec_vec    <= 1'b0;
            mepc_r       <= 31'd0;
            mscratch     <= 32'd0;
            mcause_r     <= 32'd0;
            mtval_r      <= 32'd0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
            mie_msie     <= 1'b0;
            priv_r       <= 2'd3;
            st_sie <= 1'b0; st_spie <= 1'b0; st_spp <= 1'b0; st_mprv <= 1'b0; st_tw <= 1'b0; st_tsr <= 1'b0;
            st_mpp <= 2'd0; st_fs <= 2'd0;
            stvec_r <= 30'd0; stvec_vec <= 1'b0; sepc_r <= 31'd0;
            sscratch <= 32'd0; scause_r <= 32'd0; stval_r <= 32'd0; mcounteren <= 32'd0; scounteren <= 32'd0;
            medeleg_r <= 10'd0; medeleg19 <= 1'b0; mideleg_ssi <= 1'b0; mideleg_sti <= 1'b0; mideleg_sei <= 1'b0;
            medeleg_pf <= 3'd0; st_sum <= 1'b0; st_mxr <= 1'b0; st_tvm <= 1'b0;
            satp_mode <= 1'b0; satp_asid <= 9'd0; satp_ppn <= 22'd0;
            mie_ssie <= 1'b0; mie_stie <= 1'b0; mie_seie <= 1'b0; mip_ssip <= 1'b0; mip_stip <= 1'b0; mip_seip <= 1'b0;
        end else if (trap_q) begin
            if (ts_q) begin                                 // trap ve S
                sepc_r       <= tepc_q;
                scause_r     <= {tint_q, 27'd0, tcause_q};
                stval_r      <= ttval_q;
                st_spp       <= tpriv_q[0];
                st_spie      <= st_sie;
                st_sie       <= 1'b0;
                priv_r       <= 2'd1;
            end else begin
                mepc_r       <= tepc_q;
                mcause_r     <= {tint_q, 27'd0, tcause_q};
                mtval_r      <= ttval_q;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
                st_mpp       <= tpriv_q;
                priv_r       <= 2'd3;
            end
        end else if (mret_ex) begin
            mstatus_mie  <= mstatus_mpie;
            mstatus_mpie <= 1'b1;
            priv_r       <= st_mpp;
            st_mpp       <= 2'd0;                           // MPP ve che do thap nhat (U)
            if (st_mpp != 2'd3) st_mprv <= 1'b0;
        end else if (sret_ex) begin
            st_sie       <= st_spie;
            st_spie      <= 1'b1;
            priv_r       <= {1'b0, st_spp};
            st_spp       <= 1'b0;
            st_mprv      <= 1'b0;
        end else if (csr_write) begin
            case (csr_addr)
                12'h300: begin
                    mstatus_mie <= csr_new[3]; mstatus_mpie <= csr_new[7];
                    st_sie <= csr_new[1]; st_spie <= csr_new[5]; st_spp <= csr_new[8]; st_fs <= csr_new[14:13];
                    st_mpp <= (csr_new[12:11] == 2'd2) ? 2'd0 : csr_new[12:11];        // H (2) khong co: ve U
                    st_mprv <= csr_new[17]; st_tw <= csr_new[21]; st_tsr <= csr_new[22];
                    st_sum <= csr_new[18]; st_mxr <= csr_new[19]; st_tvm <= csr_new[20];
                end
                12'h304: begin
                    mie_mtie <= csr_new[7]; mie_meie <= csr_new[11]; mie_msie <= csr_new[3];
                    mie_ssie <= csr_new[1]; mie_stie <= csr_new[5]; mie_seie <= csr_new[9];
                end
                12'h305: begin mtvec_r <= csr_new[31:2]; mtvec_vec <= csr_new[0]; end   // MODE >= 2 du phong: bit 1 doc 0
                12'h340: mscratch <= csr_new;
                12'h341: mepc_r   <= csr_new[31:1];
                12'h342: mcause_r <= csr_new;
                12'h343: mtval_r  <= csr_new;
                12'h344: begin mip_ssip <= csr_new[1]; mip_stip <= csr_new[5]; mip_seip <= csr_new[9]; end
                12'h100: begin st_sie <= csr_new[1]; st_spie <= csr_new[5]; st_spp <= csr_new[8]; st_fs <= csr_new[14:13];
                               st_sum <= csr_new[18]; st_mxr <= csr_new[19]; end
                12'h104: begin                              // sie: chi cac bit da uy quyen
                    if (mideleg_ssi) mie_ssie <= csr_new[1];
                    if (mideleg_sti) mie_stie <= csr_new[5];
                    if (mideleg_sei) mie_seie <= csr_new[9];
                end
                12'h105: begin stvec_r <= csr_new[31:2]; stvec_vec <= csr_new[0]; end
                12'h106: scounteren <= csr_new;
                12'h140: sscratch <= csr_new;
                12'h141: sepc_r   <= csr_new[31:1];
                12'h142: scause_r <= csr_new;
                12'h143: stval_r  <= csr_new;
                12'h144: if (mideleg_ssi) mip_ssip <= csr_new[1];      // sip: chi SSIP ghi duoc
                12'h302: begin medeleg_r <= {csr_new[9:1], csr_new[0] & (ENABLE_C == 0)}; medeleg19 <= csr_new[19];
                               medeleg_pf <= {csr_new[15], csr_new[13], csr_new[12]}; end
                12'h180: begin satp_mode <= csr_new[31]; satp_asid <= csr_new[30:22]; satp_ppn <= csr_new[21:0]; end
                12'h303: begin mideleg_ssi <= csr_new[1]; mideleg_sti <= csr_new[5]; mideleg_sei <= csr_new[9]; end
                12'h306: mcounteren <= csr_new;
                default: ;
            endcase
        end
    end

    // ket qua cua tang EX (voi load/store: dia chi)
    wire [31:0] ex_result = idex_lui              ? idex_imm        :
                            idex_auipc            ? pc_imm          :
                            (idex_jal | idex_jalr)? pc_next         :
                            idex_csr              ? csr_rdata       :
                            idex_mext             ? m_result        :
                            (idex_load | idex_store | idex_amo) ? d_paddr :
                            idex_zb               ? zb_out          :
                                                      alu_out;

    // cap nhat bo du doan tre 1 chu ky: EX ghi ket qua vao thanh ghi, chu ky sau moi sua bang (xem "Du doan nhanh")
    wire ex_upd   = idex_valid & ~frz & ~trap_ex;             // lenh thuc su chay xong o EX trong chu ky nay
    wire ex_lrd   = (idex_rd == 5'd1) | (idex_rd == 5'd5);
    wire ex_lrs1  = (idex_rs1 == 5'd1) | (idex_rs1 == 5'd5);
    wire ex_pop   = idex_jalr & ex_lrs1 & ~(ex_lrd & (idex_rd == idex_rs1));
    wire ex_push  = (idex_jal | idex_jalr) & ex_lrd;
    reg                 exmem_bupd, exmem_btaken;
    reg                 exmem_tupd;                         // TAGE: nhanh that su chay xong o EX (khong trap)
    reg  [TMW-1:0]      exmem_tmeta;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) exmem_tupd <= 1'b0;
        else begin
            exmem_tupd  <= ex_upd & idex_branch;
            exmem_tmeta <= idex_tmeta;
        end
    end
    generate if (TAGE != 0) begin : g_tage
        rv32_tage #(.NT(TAGE_NT), .IB(TAGE_IB), .TB(TAGE_TB), .BB(TAGE_BB), .PCB(PCB), .HL(TAGE_HL)) u_tage (
            .clk(clk), .rst_n(rst_n),
            .p_pc(pc), .p_taken(t_pred), .p_meta(if_tmeta),
            .u_valid(exmem_tupd), .u_taken(exmem_btaken), .u_meta(exmem_tmeta),
            .h_valid(ex_upd & idex_branch), .h_taken(take_branch));
    end else begin : g_notage
        assign t_pred   = 1'b0;
        assign if_tmeta = 1'b0;
    end endgenerate
    reg [BHT_BITS-1:0]  exmem_bidx;
    reg                 up_btb, up_inv, up_pop, up_push;
    // trang thai tiep theo cua RAS kien truc (cap nhat dang cho up_pop / up_push), dung chung khi chep sang ban suy doan
    reg  [RAS_B:0]      a_cnt_n;
    reg  [RAS_B-1:0]    a_top_n, a_widx;
    reg                 a_we;
    always @* begin
        a_cnt_n = a_cnt; a_top_n = a_top; a_we = 1'b0; a_widx = a_top;
        if (up_pop & up_push) begin
            a_we = 1'b1; if (a_cnt == 0) a_cnt_n = 1;
        end else if (up_push) begin
            a_we = 1'b1; a_widx = a_top + {{(RAS_B-1){1'b0}}, (a_cnt != 0)};
            a_top_n = a_widx; if (a_cnt != RAS_N) a_cnt_n = a_cnt + 1'b1;
        end else if (up_pop && a_cnt != 0) begin
            if (a_cnt != 1) a_top_n = a_top - 1'b1;
            a_cnt_n = a_cnt - 1'b1;
        end
    end
    reg [BTB_B-1:0]     up_bi, inv_bi;
    reg [TAGB-1:0]      up_bt;
    reg [31:1]          up_tgt, up_link;
    reg [1:0]           up_typ;
    integer bi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exmem_bupd <= 1'b0; exmem_btaken <= 1'b0; exmem_bidx <= {BHT_BITS{1'b0}};
            for (bi = 0; bi < (1<<BHT_BITS); bi = bi + 1) bht[bi] <= 2'b01;      // khoi dau: yeu, khong nhay
            for (bi = 0; bi < BTB_N; bi = bi + 1) btb_v[bi] <= 1'b0;
            ghr <= {GB{1'b0}};
            up_btb <= 1'b0; up_inv <= 1'b0; up_pop <= 1'b0; up_push <= 1'b0;
            a_cnt <= 0; a_top <= {RAS_B{1'b0}}; s_cnt <= 0; s_top <= {RAS_B{1'b0}};
        end else begin
            exmem_bupd   <= idex_valid & idex_branch & ~frz;      // dong bang: nhanh se duoc dem khi chay tiep
            exmem_btaken <= take_branch;
            exmem_bidx   <= idex_pidx;                             // chi so luc du doan (gshare can lich su luc do)
            if (exmem_bupd) begin
                if (exmem_btaken) begin if (bht[exmem_bidx] != 2'b11) bht[exmem_bidx] <= bht[exmem_bidx] + 2'd1; end
                else              begin if (bht[exmem_bidx] != 2'b00) bht[exmem_bidx] <= bht[exmem_bidx] - 2'd1; end
            end
            if (GHR_BITS > 0 && ex_upd && idex_branch) ghr <= {ghr, take_branch};
            // BTB: ghi khi nhanh nhay, JAL, JALR; xoa muc trung nham do ID bao (ghi cua EX thang neu cung muc)
            up_btb  <= ex_upd & ((idex_branch & take_branch) | idex_jal | idex_jalr);
            up_bi   <= idex_pc[PCB +: BTB_B];
            up_bt   <= idex_pc[PCB + BTB_B +: TAGB];
            up_tgt  <= idex_jalr ? jalr_target[31:1] : pc_imm[31:1];
            up_typ  <= idex_branch ? T_BR : idex_jal ? T_JAL : (ex_pop ? T_RET : T_JALR);
            up_inv  <= id_btb_inv & ~frz & ~ex_stall;
            inv_bi  <= ifid_pc[PCB +: BTB_B];
            if (BTB_N > 0) begin
                if (up_inv) btb_v[inv_bi] <= 1'b0;
                if (up_btb) begin
                    btb_v[up_bi] <= 1'b1; btb_tag[up_bi] <= up_bt; btb_tgt[up_bi] <= up_tgt; btb_typ[up_bi] <= up_typ;
                end
            end
            // RAS kien truc (theo lenh da chay xong o EX) va RAS suy doan (theo ID, chep lai tu kien truc khi EX redirect)
            up_pop  <= ex_upd & ex_pop;
            up_push <= ex_upd & ex_push;
            up_link <= pc_next[31:1];
            if (RAS_N > 0) begin
                a_cnt <= a_cnt_n; a_top <= a_top_n;
                if (a_we) a_ras[a_widx] <= up_link;
                if (redirect_q) begin
                    s_cnt <= a_cnt_n; s_top <= a_top_n;
                    for (bi = 0; bi < RN; bi = bi + 1) s_ras[bi] <= (a_we && a_widx == bi) ? up_link : a_ras[bi];
                end else begin
                    s_cnt <= s_cnt_n; s_top <= s_top_n;
                    if (s_we) s_ras[s_widx] <= id_seq[31:1];
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exmem_valid <= 1'b0;
            exmem_rd_we <= 1'b0;
            exmem_load  <= 1'b0;
            exmem_store <= 1'b0;
            exmem_fence <= 1'b0;
            exmem_amo   <= 1'b0;
            exmem_trap  <= 1'b0;
            exmem_icnt  <= 1'b0;
        end else if (!frz) begin
            exmem_valid     <= idex_valid & ~ex_stall;      // M chua xong: nhan bong bay
            exmem_rd_we     <= idex_rd_we & ~ex_stall & ~trap_ex;
            exmem_load      <= idex_load & ~ex_stall & ~trap_ex;
            exmem_store     <= idex_store & ~ex_stall & ~trap_ex;
            exmem_fence     <= idex_fence_r & idex_valid & ~ex_stall & ~trap_ex;
            exmem_amo       <= idex_amo & ~ex_stall & ~trap_ex;
            exmem_pc        <= idex_pc;
            exmem_instr     <= idex_instr;
            exmem_tirq      <= irq_take;                    // chi de testbench: lenh bi ngat chan lai (chay lai sau mret)
            exmem_trap      <= trap_ex;                     // lenh gay trap / bi ngat: khong tinh la hoan tat (minstret)
            exmem_icnt      <= cnt_icnt;                    // lenh nay co duoc dem vao minstret khi hoan tat khong
            exmem_rd        <= idex_rd;
            exmem_funct3    <= idex_funct3;
            exmem_result    <= ex_result;
            exmem_store_val <= op_b;
            exmem_tva       <= ea;                          // chi de testbench: dia chi ao cua load / store (vet)
        end
    end

    // ============================================================
    // MEM
    // ============================================================
    // Truy cap theo byte: du lieu dich trai byte_off byte tren 64 bit, wstrb 8 bit (4 bit thap: tu chua dia chi,
    // 4 bit cao: tu ke tiep). Truy cap can chinh hoac lech nhung nam gon trong 1 tu (vd. half o byte 1) chi dung 4 bit
    // thap: 1 lan truy cap nhu cu. Truy cap vat qua ranh gioi tu (word o byte 1..3, half o byte 3; chi khi
    // MISALIGNED = 1, neu khong da trap o EX) tach thanh 2 pha o MEM: pha 0 truy cap tu thap, pha 1 tu cao. Pipeline
    // dong bang (frz) tu pha 0 toi khi pha 1 xong; load giu 32 bit cua pha 0 trong ma_lo roi ghep voi tu cao.
    wire [1:0] byte_off = exmem_result[1:0];
    reg  [63:0] st_wide;
    reg  [7:0]  st_strb8;
    // Mo rong A (xem "Mo rong A: LR/SC va AMO"): AMO la doc-sua-ghi 2 pha o MEM (pha 0 doc tu, pha 1 ghi tu da tinh), SC chi
    // ghi khi con dat cho dung dia chi (neu khong, khong truy cap bo nho, rd = 1), LR doc nhu LW roi dat cho.
    wire        m_atom   = (A_EXT != 0) & (exmem_instr[6:0] == 7'b0101111);     // lenh 16 bit khong bao gio khop (bit 1:0 != 11)
    wire        m_is_sc  = m_atom & exmem_store;
    wire        m_is_lr  = m_atom & exmem_load;
    reg         res_v;                                      // dang dat cho
    reg  [31:2] res_a;                                      // tu duoc dat cho
    wire        sc_ok    = res_v & (res_a == exmem_result[31:2]);
    wire        sc_fail  = m_is_sc & ~sc_ok;
    reg         amo_phase;                                  // 1: pha ghi cua AMO
    reg  [31:0] amo_old;                                    // gia tri cu doc o pha 0 (cung la ket qua rd)
    wire [4:0]  amo_f5   = exmem_instr[31:27];
    wire        amo_lt   = $signed(amo_old) < $signed(exmem_store_val);
    wire        amo_ltu  = amo_old < exmem_store_val;
    reg  [31:0] amo_new;
    always @* begin
        case (amo_f5)
            5'b00001: amo_new = exmem_store_val;                                  // amoswap
            5'b00000: amo_new = amo_old + exmem_store_val;                        // amoadd
            5'b00100: amo_new = amo_old ^ exmem_store_val;                        // amoxor
            5'b01100: amo_new = amo_old & exmem_store_val;                        // amoand
            5'b01000: amo_new = amo_old | exmem_store_val;                        // amoor
            5'b10000: amo_new = amo_lt  ? amo_old : exmem_store_val;              // amomin
            5'b10100: amo_new = amo_lt  ? exmem_store_val : amo_old;              // amomax
            5'b11000: amo_new = amo_ltu ? amo_old : exmem_store_val;              // amominu
            default:  amo_new = amo_ltu ? exmem_store_val : amo_old;              // amomaxu
        endcase
    end
    wire [31:0] st_val = exmem_amo ? amo_new : exmem_store_val;
    always @* begin
        case (exmem_funct3[1:0])
            2'b00:   begin st_wide = {56'b0, st_val[7:0]};  st_strb8 = 8'b0000_0001; end
            2'b01:   begin st_wide = {48'b0, st_val[15:0]}; st_strb8 = 8'b0000_0011; end
            default: begin st_wide = {32'b0, st_val};       st_strb8 = 8'b0000_1111; end
        endcase
        st_wide  = st_wide << {byte_off, 3'b000};
        st_strb8 = st_strb8 << byte_off;
    end
    // so byte cua truy cap (load hoac store) vuot qua tu hien tai
    wire [7:0] acc_strb8 = (exmem_funct3[1:0] == 2'b00 ? 8'b0000_0001 :
                            exmem_funct3[1:0] == 2'b01 ? 8'b0000_0011 : 8'b0000_1111) << byte_off;
    wire       ma_cross  = (MISALIGNED != 0) & exmem_valid & (exmem_load | exmem_store) & (acc_strb8[7:4] != 4'b0000);
    reg        ma_phase;                                   // 1: dang o pha 1 (tu cao) cua truy cap vat qua tu
    reg [31:0] ma_lo;                                      // load: tu thap doc o pha 0

    wire [31:0] st_data = ma_phase ? st_wide[63:32] : st_wide[31:0];
    wire [3:0]  st_strb = ma_phase ? st_strb8[7:4]  : st_strb8[3:0];

    // pha 1: dia chi tu ke tiep (can chinh); pha 0 cua truy cap vat qua tu: dia chi tu thap can chinh
    assign dmem_addr = mmu_mreq ? mmu_maddr[31:0] :
                       ma_phase ? {exmem_result[31:2] + 30'd1, 2'b00} :
                       ma_cross ? {exmem_result[31:2], 2'b00} : exmem_result;

    assign dmem_we    = exmem_valid & ((exmem_store & ~sc_fail) | (exmem_amo & amo_phase));
    assign dmem_re    = (exmem_valid & (exmem_load | (exmem_amo & ~amo_phase))) | mmu_mreq;   // bo duyet bang trang doc PTE khi tang MEM ranh
    assign dmem_fence = exmem_valid & exmem_fence;
    // lenh o MEM xong khi bo nho san sang va (khong vat qua tu, hoac dang o pha cuoi)
    wire   mem_last   = (~ma_cross | ma_phase) & (~exmem_amo | amo_phase);
    assign frz        = (dmem_we | dmem_re | dmem_fence) & ~(dmem_ready & mem_last);
    assign dmem_wdata = st_data;
    assign dmem_wstrb = dmem_we ? st_strb : 4'b0000;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                             amo_phase <= 1'b0;
        else if (exmem_valid & exmem_amo & dmem_ready) amo_phase <= ~amo_phase;
    end
    always @(posedge clk) if (exmem_valid & exmem_amo & ~amo_phase & dmem_ready) amo_old <= dmem_rdata;

    // dat cho: LR dat, SC (thanh cong hay khong) xoa, trap / ngat xoa; A_ST_CLR = 1: store thuong va AMO cung xoa khi trung tu
    wire mem_done = exmem_valid & ~frz;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                              res_v <= 1'b0;
        else if (A_EXT != 0) begin
            if (trap_q)                                          res_v <= 1'b0;
            else if (mem_done & m_is_lr)                         begin res_v <= 1'b1; res_a <= exmem_result[31:2]; end
            else if (mem_done & m_is_sc)                         res_v <= 1'b0;
            else if (A_ST_CLR != 0 & mem_done & ((exmem_store & ~m_atom) | exmem_amo) & (res_a == exmem_result[31:2])) res_v <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                             ma_phase <= 1'b0;
        else if (ma_cross & dmem_ready) begin
            ma_phase <= ~ma_phase;                         // pha 0 xong -> pha 1; pha 1 xong -> ve 0 (lenh roi MEM)
            if (!ma_phase) ma_lo <= dmem_rdata;
        end
    end

    // load: ghep 2 tu (pha 1) hoac 1 tu, dich phai byte_off byte, roi mo rong dau / khong dau
    wire [63:0] ld_wide = ma_phase ? {dmem_rdata, ma_lo} : {32'b0, dmem_rdata};
    wire [31:0] ld_sh   = ld_wide >> {byte_off, 3'b000};
    reg  [31:0] ld_data;
    always @* begin
        case (exmem_funct3)
            3'b000:  ld_data = {{24{ld_sh[7]}},  ld_sh[7:0]};
            3'b001:  ld_data = {{16{ld_sh[15]}}, ld_sh[15:0]};
            3'b100:  ld_data = {24'b0, ld_sh[7:0]};
            3'b101:  ld_data = {16'b0, ld_sh[15:0]};
            default: ld_data = ld_sh;
        endcase
    end

    wire [31:0] mem_val = exmem_amo ? amo_old : m_is_sc ? {31'b0, sc_fail} : exmem_load ? ld_data : exmem_result;
`ifdef RISCV_FORMAL
    assign fv_m_valid = exmem_valid & (exmem_load | exmem_store);
    assign fv_m_store = exmem_store;
    assign fv_m_last  = mem_last;
    assign fv_m_addr  = exmem_result;
    assign fv_m_sval  = exmem_store_val;
    assign fv_m_ld    = ld_sh;
    assign fv_m_size  = exmem_funct3[1:0];
`endif

    // ============================================================
    // MEM/WB (cac truong memwb_t* chi de testbench in vet)
    // ============================================================
    reg  [31:0] memwb_pc, memwb_instr;
    reg         memwb_tst;
    reg  [31:0] memwb_taddr, memwb_tva;               // dia chi vat ly / dia chi ao (vet so voi Spike)
    reg  [63:0] memwb_tdata;                       // store vat qua tu: 64 bit va wstrb 8 bit (xem phan MEM)
    reg  [7:0]  memwb_tstrb;
    reg         memwb_new;                         // MEM/WB vua nhan lenh moi (khong phai chu ky dong bang)
    reg         memwb_tirq;                        // lenh bi ngat chan lai o EX: khong thuc thi, se chay lai sau mret
    reg         memwb_trap, memwb_icnt;
    reg         memwb_skip;                 // lenh nay da duoc tinh vao gia tri ghi minstret (xem Zicntr): khong tang them
    wire        wb_commit = memwb_valid & memwb_new;   // moi lenh hoan tat dung 1 chu ky (testbench in vet theo day)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memwb_valid <= 1'b0;
            memwb_rd_we <= 1'b0;
            memwb_tst   <= 1'b0;
            memwb_new   <= 1'b0;
            memwb_trap  <= 1'b0;
            memwb_icnt  <= 1'b0;
            memwb_skip  <= 1'b0;
        end else if (frz) begin
            memwb_new   <= 1'b0;                     // MEM/WB giu nguyen: lenh trong do da duoc tinh la hoan tat
        end else begin
            memwb_new   <= 1'b1;
            memwb_valid <= exmem_valid;
            memwb_rd_we <= exmem_rd_we;
            memwb_rd    <= exmem_rd;
            memwb_val   <= mem_val;
            memwb_pc    <= exmem_pc;
            memwb_instr <= exmem_instr;
            memwb_tirq  <= exmem_tirq;
            memwb_trap  <= exmem_trap;
            memwb_icnt  <= exmem_icnt;
            memwb_skip  <= cnt_wr_ir;                // cnt_wr_ir da gom ~frz: dung canh lenh nay roi MEM
            memwb_tst   <= dmem_we;
            memwb_taddr <= dmem_we ? exmem_result : 32'd0;
            memwb_tva   <= dmem_we ? exmem_tva : 32'd0;
            memwb_tdata <= dmem_we ? st_wide : 64'd0;      // st_wide chi co cac byte duoc ghi (con lai la 0)
            memwb_tstrb <= dmem_we ? st_strb8 : 8'd0;
        end
    end

`ifdef RISCV_FORMAL
    // ============================================================
    // RVFI (riscv-formal Verification Interface), mot lenh hoan tat moi chu ky o tang WB.
    // Toan bo khoi nay chi duoc bien dich khi co RISCV_FORMAL; no chi DOC cac tin hieu da co, khong dieu khien gi.
    //  - Lenh hoan tat khi memwb_valid & memwb_new (xem wb_commit). Lenh bi ngat o EX (irq_take) van di qua pipeline
    //    nhu lenh vo hieu nhung KHONG hoan tat (RVFI: ngat khong co lenh); lenh dau tien cua trinh xu ly ngat co intr = 1.
    //  - Toan hang nguon lay o EX sau forwarding. Lenh M dung o EX nhieu chu ky va forwarding doi trong luc do, nen
    //    toan hang cua chu ky dau (luc rv32m chep) duoc giu lai (rv_a_hold / rv_b_hold).
    //  - Bo nho: RVFI_ALIGNED_MEM, mem_addr chia het cho 4, rmask / wmask theo byte trong tu. Chi dung voi MISALIGNED = 0
    //    (truy cap lech tach 2 pha o MEM khong bieu dien duoc bang 1 kenh RVFI).
    // ============================================================
    localparam [31:0] RV_MISA = 32'h4000_1100 | ((ENABLE_C != 0) ? 32'h4 : 32'h0) | ((A_EXT != 0) ? 32'h1 : 32'h0);
    wire [31:0] csr_rdata_const_misa    = RV_MISA;
    wire [31:0] csr_rdata_const_mhartid = 32'd0;

    // lenh o ID dung rs1 / rs2 that su (CSR dang immediate khong dung rs1)
    reg rv_u1_q, rv_u2_q;
    always @(posedge clk) if (!(ex_stall | frz)) begin
        rv_u1_q <= legal_jalr | legal_branch | legal_load | legal_store | legal_imm | legal_reg | (legal_csr & ~funct3[2]);
        rv_u2_q <= legal_branch | legal_store | legal_reg;
    end

    // toan hang cua chu ky dau tien cua lenh o EX (lenh M o EX nhieu chu ky)
    reg         rv_mcont;
    reg  [31:0] rv_a_hold, rv_b_hold;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    rv_mcont <= 1'b0;
        else if (!frz) rv_mcont <= idex_mext & ~m_done;
    end
    always @(posedge clk) if (!rv_mcont) begin rv_a_hold <= op_a; rv_b_hold <= op_b; end
    wire [31:0] rv_a = rv_mcont ? rv_a_hold : op_a;
    wire [31:0] rv_b = rv_mcont ? rv_b_hold : op_b;

    // gia tri tai EX
    wire        rv_ex_irq  = irq_take;
    wire        rv_ex_trap = trap_ex & ~irq_take;
    wire [31:0] rv_ex_pcw  = trap_ex ? {mtvec_r, 2'b00} :
                             mret_ex ? mepc_v           :
                             idex_jalr ? jalr_target :
                             (idex_jal | (idex_branch & take_branch)) ? pc_imm : pc_next;

    reg  [4:0]  xm_rs1a, xm_rs2a;
    reg  [31:0] xm_rs1d, xm_rs2d, xm_pcw, xm_csr_rd, xm_csr_new;
    reg         xm_trap, xm_irq, xm_csr, xm_csr_w;
    always @(posedge clk) if (!frz) begin
        xm_rs1a    <= rv_u1_q ? idex_rs1 : 5'd0;
        xm_rs2a    <= rv_u2_q ? idex_rs2 : 5'd0;
        xm_rs1d    <= (rv_u1_q && idex_rs1 != 5'd0) ? rv_a : 32'd0;
        xm_rs2d    <= (rv_u2_q && idex_rs2 != 5'd0) ? rv_b : 32'd0;
        xm_pcw     <= rv_ex_pcw;
        xm_trap    <= rv_ex_trap;
        xm_irq     <= rv_ex_irq;
        xm_csr     <= idex_csr;
        xm_csr_w   <= idex_csr & csr_we_req;
        xm_csr_rd  <= csr_rdata;
        xm_csr_new <= csr_new;
    end

    // MEM -> MEM/WB: truy cap bo nho that su cua lenh vua xong o MEM (dmem_ready = 1 trong chu ky nay)
    wire [3:0] rv_ld_mask = ((exmem_funct3[1:0] == 2'b00) ? 4'b0001 :
                             (exmem_funct3[1:0] == 2'b01) ? 4'b0011 : 4'b1111) << byte_off;
    reg  [4:0]  memwb_rv_rs1a, memwb_rv_rs2a;
    reg  [31:0] memwb_rv_rs1d, memwb_rv_rs2d, memwb_rv_pcw, memwb_rv_csr_rd, memwb_rv_csr_new;
    reg         memwb_rv_trap, memwb_rv_irq, memwb_rv_csr, memwb_rv_csr_w;
    reg  [31:0] memwb_rv_maddr, memwb_rv_mrdata, memwb_rv_mwdata;
    reg  [3:0]  memwb_rv_mrmask, memwb_rv_mwmask;
    always @(posedge clk) if (!frz) begin
        memwb_rv_rs1a    <= xm_rs1a;   memwb_rv_rs2a   <= xm_rs2a;
        memwb_rv_rs1d    <= xm_rs1d;   memwb_rv_rs2d   <= xm_rs2d;
        memwb_rv_pcw     <= xm_pcw;
        memwb_rv_trap    <= xm_trap;   memwb_rv_irq    <= xm_irq;
        memwb_rv_csr     <= xm_csr;    memwb_rv_csr_w  <= xm_csr_w;
        memwb_rv_csr_rd  <= xm_csr_rd; memwb_rv_csr_new <= xm_csr_new;
`ifdef RISCV_FORMAL_ALIGNED_MEM
        memwb_rv_maddr   <= (dmem_re | dmem_we) ? {exmem_result[31:2], 2'b00} : 32'd0;
        memwb_rv_mrmask  <= dmem_re ? rv_ld_mask : 4'd0;
        memwb_rv_mwmask  <= dmem_we ? dmem_wstrb : 4'd0;
        memwb_rv_mrdata  <= dmem_re ? dmem_rdata : 32'd0;
        memwb_rv_mwdata  <= dmem_we ? dmem_wdata : 32'd0;
`else
        // Khong ALIGNED_MEM (dung cho MISALIGNED = 1): bao truy cap LOGIC cua lenh, mot ban ghi cho ca truy cap vat qua tu:
        // dia chi chinh xac, mat na theo kich thuoc (khong dich), du lieu da ghep 2 tu (load) / toan hang (store).
        memwb_rv_maddr   <= (dmem_re | dmem_we) ? exmem_result : 32'd0;
        memwb_rv_mrmask  <= dmem_re ? (exmem_funct3[1:0] == 2'b00 ? 4'b0001 : exmem_funct3[1:0] == 2'b01 ? 4'b0011 : 4'b1111) : 4'd0;
        memwb_rv_mwmask  <= dmem_we ? (exmem_funct3[1:0] == 2'b00 ? 4'b0001 : exmem_funct3[1:0] == 2'b01 ? 4'b0011 : 4'b1111) : 4'd0;
        memwb_rv_mrdata  <= dmem_re ? ld_sh : 32'd0;
        memwb_rv_mwdata  <= dmem_we ? exmem_store_val : 32'd0;
`endif
    end

    wire rv_ret = wb_commit & ~memwb_rv_irq;
    reg  [63:0] rv_order;
    reg         rv_intr_pend;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rv_order <= 64'd0; rv_intr_pend <= 1'b0; end
        else begin
            if (rv_ret) rv_order <= rv_order + 64'd1;
            if (rv_ret)                           rv_intr_pend <= 1'b0;
            else if (wb_commit & memwb_rv_irq)    rv_intr_pend <= 1'b1;   // lenh bi ngat: lenh hoan tat ke tiep vao trinh xu ly
        end
    end

    wire rv_rdw = memwb_rd_we & (memwb_rd != 5'd0);
    assign rvfi_valid     = rv_ret;
    assign rvfi_order     = rv_order;
    assign rvfi_insn      = memwb_instr;
    assign rvfi_trap      = memwb_rv_trap;
    assign rvfi_halt      = 1'b0;
    assign rvfi_intr      = rv_ret & rv_intr_pend;
    assign rvfi_mode      = 2'd3;
    assign rvfi_ixl       = 2'd1;
    assign rvfi_rs1_addr  = memwb_rv_rs1a;
    assign rvfi_rs2_addr  = memwb_rv_rs2a;
    assign rvfi_rs1_rdata = memwb_rv_rs1d;
    assign rvfi_rs2_rdata = memwb_rv_rs2d;
    assign rvfi_rd_addr   = rv_rdw ? memwb_rd  : 5'd0;
    assign rvfi_rd_wdata  = rv_rdw ? memwb_val : 32'd0;
    assign rvfi_pc_rdata  = memwb_pc;
    assign rvfi_pc_wdata  = memwb_rv_pcw;
    assign rvfi_mem_addr  = memwb_rv_maddr;
    assign rvfi_mem_rmask = memwb_rv_mrmask;
    assign rvfi_mem_wmask = memwb_rv_mwmask;
    assign rvfi_mem_rdata = memwb_rv_mrdata;
    assign rvfi_mem_wdata = memwb_rv_mwdata;

    wire        rv_csr_ret  = rv_ret & memwb_rv_csr & ~memwb_rv_trap;
    wire [11:0] rv_csr_addr = memwb_instr[31:20];
`ifdef RISCV_FORMAL_CSR_MISA
    wire rv_hit_misa = rv_csr_ret & (rv_csr_addr == 12'h301);
    assign rvfi_csr_misa_rmask = 32'hFFFF_FFFF;
    assign rvfi_csr_misa_rdata = rv_hit_misa ? memwb_rv_csr_rd : csr_rdata_const_misa;
    assign rvfi_csr_misa_wmask = (rv_hit_misa & memwb_rv_csr_w) ? 32'h0 : 32'h0;
    assign rvfi_csr_misa_wdata = (rv_hit_misa & memwb_rv_csr_w) ? (32'h0 & 32'h0) : 32'h0;
`endif
`ifdef RISCV_FORMAL_CSR_MHARTID
    wire rv_hit_mhartid = rv_csr_ret & (rv_csr_addr == 12'hF14);
    assign rvfi_csr_mhartid_rmask = 32'hFFFF_FFFF;
    assign rvfi_csr_mhartid_rdata = rv_hit_mhartid ? memwb_rv_csr_rd : csr_rdata_const_mhartid;
    assign rvfi_csr_mhartid_wmask = (rv_hit_mhartid & memwb_rv_csr_w) ? 32'h0 : 32'h0;
    assign rvfi_csr_mhartid_wdata = (rv_hit_mhartid & memwb_rv_csr_w) ? (32'h0 & 32'h0) : 32'h0;
`endif
`ifdef RISCV_FORMAL_CSR_MSTATUS
    wire rv_hit_mstatus = rv_csr_ret & (rv_csr_addr == 12'h300);
    assign rvfi_csr_mstatus_rmask = rv_hit_mstatus ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mstatus_rdata = rv_hit_mstatus ? memwb_rv_csr_rd : 32'h0;
    assign rvfi_csr_mstatus_wmask = (rv_hit_mstatus & memwb_rv_csr_w) ? 32'h0000_0088 : 32'h0;
    assign rvfi_csr_mstatus_wdata = (rv_hit_mstatus & memwb_rv_csr_w) ? ({19'b0, 2'b11, 3'b0, memwb_rv_csr_new[7], 3'b0, memwb_rv_csr_new[3], 3'b0} & 32'h0000_0088) : 32'h0;
`endif
`ifdef RISCV_FORMAL_CSR_MIE
    wire rv_hit_mie = rv_csr_ret & (rv_csr_addr == 12'h304);
    assign rvfi_csr_mie_rmask = rv_hit_mie ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mie_rdata = rv_hit_mie ? memwb_rv_csr_rd : 32'h0;
    assign rvfi_csr_mie_wmask = (rv_hit_mie & memwb_rv_csr_w) ? 32'h0000_0888 : 32'h0;
    assign rvfi_csr_mie_wdata = (rv_hit_mie & memwb_rv_csr_w) ? ({20'b0, memwb_rv_csr_new[11], 3'b0, memwb_rv_csr_new[7], 3'b0, memwb_rv_csr_new[3], 3'b0} & 32'h0000_0888) : 32'h0;
`endif
`ifdef RISCV_FORMAL_CSR_MTVEC
    wire rv_hit_mtvec = rv_csr_ret & (rv_csr_addr == 12'h305);
    assign rvfi_csr_mtvec_rmask = rv_hit_mtvec ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mtvec_rdata = rv_hit_mtvec ? memwb_rv_csr_rd : 32'h0;
    assign rvfi_csr_mtvec_wmask = (rv_hit_mtvec & memwb_rv_csr_w) ? 32'hFFFF_FFFD : 32'h0;     // bit 1 (MODE >= 2) doc 0
    assign rvfi_csr_mtvec_wdata = (rv_hit_mtvec & memwb_rv_csr_w) ? {memwb_rv_csr_new[31:2], 1'b0, memwb_rv_csr_new[0]} : 32'h0;
`endif
`ifdef RISCV_FORMAL_CSR_MSCRATCH
    wire rv_hit_mscratch = rv_csr_ret & (rv_csr_addr == 12'h340);
    assign rvfi_csr_mscratch_rmask = rv_hit_mscratch ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mscratch_rdata = rv_hit_mscratch ? memwb_rv_csr_rd : 32'h0;
    assign rvfi_csr_mscratch_wmask = (rv_hit_mscratch & memwb_rv_csr_w) ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mscratch_wdata = (rv_hit_mscratch & memwb_rv_csr_w) ? (memwb_rv_csr_new & 32'hFFFF_FFFF) : 32'h0;
`endif
`ifdef RISCV_FORMAL_CSR_MEPC
    wire rv_hit_mepc = rv_csr_ret & (rv_csr_addr == 12'h341);
    assign rvfi_csr_mepc_rmask = rv_hit_mepc ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mepc_rdata = rv_hit_mepc ? memwb_rv_csr_rd : 32'h0;
    assign rvfi_csr_mepc_wmask = (rv_hit_mepc & memwb_rv_csr_w) ? ((ENABLE_C != 0) ? 32'hFFFF_FFFE : 32'hFFFF_FFFC) : 32'h0;
    assign rvfi_csr_mepc_wdata = (rv_hit_mepc & memwb_rv_csr_w) ? ({memwb_rv_csr_new[31:2], memwb_rv_csr_new[1] & (ENABLE_C != 0), 1'b0}) : 32'h0;
`endif
`ifdef RISCV_FORMAL_CSR_MCAUSE
    wire rv_hit_mcause = rv_csr_ret & (rv_csr_addr == 12'h342);
    assign rvfi_csr_mcause_rmask = rv_hit_mcause ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mcause_rdata = rv_hit_mcause ? memwb_rv_csr_rd : 32'h0;
    assign rvfi_csr_mcause_wmask = (rv_hit_mcause & memwb_rv_csr_w) ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mcause_wdata = (rv_hit_mcause & memwb_rv_csr_w) ? (memwb_rv_csr_new & 32'hFFFF_FFFF) : 32'h0;
`endif
`ifdef RISCV_FORMAL_CSR_MTVAL
    wire rv_hit_mtval = rv_csr_ret & (rv_csr_addr == 12'h343);
    assign rvfi_csr_mtval_rmask = rv_hit_mtval ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mtval_rdata = rv_hit_mtval ? memwb_rv_csr_rd : 32'h0;
    assign rvfi_csr_mtval_wmask = (rv_hit_mtval & memwb_rv_csr_w) ? 32'hFFFF_FFFF : 32'h0;
    assign rvfi_csr_mtval_wdata = (rv_hit_mtval & memwb_rv_csr_w) ? (memwb_rv_csr_new & 32'hFFFF_FFFF) : 32'h0;
`endif
`endif
    // ---- Zicntr / Zihpm (ZICNTR = 1): mcycle, minstret, HPM_N bo dem su kien mhpmcounter3.. (64 bit) ----
    // minstret dem lenh hoan tat o WB (khong tinh lenh gay trap / bi ngat). CSR doc o EX: gia tri kien truc = minstret
    // cong cac lenh cu hon con o MEM / WB (chac chan hoan tat vi trap chi xay ra o EX). Ghi minstret o EX: tru lai so lenh
    // cu hon se con tang sau canh ghi, va lenh ghi khong tu tang (dac ta: "ghi thay cho tang").
    // Su kien (mhpmevent): 1 chu ky cho bo nho (frz), 2 lenh M chiem EX, 3 redirect o EX, 4 load-use, 5 ID nhay som,
    // 6 cho nap lenh, 7 nhanh, 8 nhanh doan sai, 9 JALR, 10 JALR doan sai, 11 ngat, 12 exception, 13 lenh hoan tat.
    // Cac loai chu ky 1-6 loai tru nhau theo thu tu uu tien nay (giong phan tich chu ky cua testbench).
    reg  [63:0] mcycle_r, minstret_r;
    reg  [2:0]  mcinh;                                     // mcountinhibit: bit 0 CY, bit 2 IR (bit 1 TM luon 0)
    reg  [63:0] hpm_cnt [0:29];
    reg  [3:0]  hpm_ev  [0:29];
    reg  [29:0] hpm_inh;
    wire        rt_inc    = wb_commit & ~memwb_trap;           // lenh hoan tat that su
    // moi lenh mang co icnt quyet dinh o EX: khong dem neu no ghi minstret (ghi thay cho tang) hoac mcountinhibit.IR
    // = 1 truoc lenh do. Cac lenh cu hon con trong pipeline van dem theo co cua chung.
    wire        ir_wb     = rt_inc & memwb_icnt & ~memwb_skip;   // lenh o WB lam minstret tang o canh nay
    wire [1:0]  ir_old    = {1'b0, exmem_valid & ~exmem_trap & exmem_icnt} + {1'b0, ir_wb};
    // chon san (carry-select): 3 bo cong chi phu thuoc minstret_r (som), ir_old den muon chi qua bo chon. Truoc day
    // minstret_r + ir_old roi tru lai khi ghi la 2 chuoi nho 64 bit noi tiep, la duong toi han cua ca loi (STA truoc P&R).
    wire [63:0] ir_p1     = minstret_r + 64'd1;
    wire [63:0] ir_p2     = minstret_r + 64'd2;
    wire [63:0] instret_v = ir_old[1] ? ir_p2 : (ir_old[0] ? ir_p1 : minstret_r);
    wire [13:1] hpm_evt;
    assign hpm_evt[1]  = frz;
    assign hpm_evt[2]  = ~frz & ex_stall;
    assign hpm_evt[3]  = ~frz & ~ex_stall & redirect_q;
    assign hpm_evt[4]  = ~frz & ~ex_stall & ~redirect_q & stall;
    assign hpm_evt[5]  = ~frz & ~ex_stall & ~redirect_q & ~stall & id_redirect;
    assign hpm_evt[6]  = ~frz & ~ex_stall & ~redirect_q & ~stall & ~id_redirect & ~imem_ready;
    assign hpm_evt[7]  = ex_upd & idex_branch;
    assign hpm_evt[8]  = ex_upd & idex_branch & mispredict;
    assign hpm_evt[9]  = ex_upd & idex_jalr;
    assign hpm_evt[10] = ex_upd & idex_jalr & jalr_miss;
    assign hpm_evt[11] = irq_take;
    assign hpm_evt[12] = trap_ex & ~irq_take & ~frz;
    assign hpm_evt[13] = rt_inc & memwb_icnt;
    // dia chi CSR cua bo dem: chi so 0 (cycle), 2 (instret), 3.. (hpm); h = nua cao
    wire        cnt_space = (csr_addr[11:8] == 4'hB || csr_addr[11:8] == 4'hC) && csr_addr[6:5] == 2'b00;
    wire [4:0]  cnt_idx   = csr_addr[4:0];
    wire        cnt_hi    = csr_addr[7];
    reg  [63:0] cnt_v;
    integer     hk;
    always @* begin
        cnt_v = 64'd0;
        if (cnt_idx == 5'd0) cnt_v = mcycle_r;
        else if (cnt_idx == 5'd2) cnt_v = instret_v;
        else if (cnt_idx >= 5'd3 && cnt_idx - 5'd3 < HPM_N) cnt_v = hpm_cnt[cnt_idx - 5'd3];
        cnt_rdata = 32'd0;
        if (ZICNTR != 0) begin
            if (cnt_space) cnt_rdata = cnt_hi ? cnt_v[63:32] : cnt_v[31:0];
            else if (csr_addr == 12'h320) begin
                cnt_rdata = {hpm_inh[28:0], mcinh};
                for (hk = HPM_N; hk < 29; hk = hk + 1) cnt_rdata[hk + 3] = 1'b0;
            end
            else if (csr_addr >= 12'h323 && csr_addr <= 12'h33F && csr_addr[4:0] - 5'd3 < HPM_N)
                cnt_rdata = {28'd0, hpm_ev[csr_addr[4:0] - 5'd3]};
        end
    end
    wire        cnt_wr    = csr_write & (ZICNTR != 0) & (csr_addr[11:8] == 4'hB) & (csr_addr[6:5] == 2'b00);
    assign      cnt_wr_ir = cnt_wr & (cnt_idx == 5'd2);
    assign      cnt_icnt  = ~cnt_wr_ir & ~mcinh[2];   // inhibit theo gia tri truoc lenh (lenh ghi mcountinhibit van duoc dem, giong Spike)
    // gia tri moi cua bo dem khi ghi nua thap / cao (tinh tren gia tri kien truc cnt_v)
    wire [63:0] cnt_new   = cnt_hi ? {csr_new, cnt_v[31:0]} : {cnt_v[63:32], csr_new};
    integer     hj;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mcycle_r   <= 64'd0;
            minstret_r <= 64'd0;
            mcinh      <= 3'd0;
            hpm_inh    <= 30'd0;
            for (hj = 0; hj < 30; hj = hj + 1) begin hpm_cnt[hj] <= 64'd0; hpm_ev[hj] <= 4'd0; end
        end else if (ZICNTR != 0) begin
            if (cnt_wr && cnt_idx == 5'd0)  mcycle_r <= cnt_new;
            else if (!mcinh[0])             mcycle_r <= mcycle_r + 64'd1;
            // ghi: gia tri moi da tinh ca lenh cu hon con o MEM (qua instret_v), nen lenh do duoc danh dau memwb_skip
            // va khong tang them khi hoan tat (truoc day: ghi cnt_new - 1 roi de no tang lai, can them 1 bo tru 64 bit).
            // Lenh o WB tang ngay o canh nay nen bi ghi de, gia tri cua no cung da nam trong instret_v.
            if (cnt_wr_ir)                  minstret_r <= cnt_new;
            else if (ir_wb)                 minstret_r <= ir_p1;
            for (hj = 0; hj < HPM_N; hj = hj + 1) begin
                if (cnt_wr && cnt_idx == hj + 3) hpm_cnt[hj] <= cnt_new;
                else if (!hpm_inh[hj] && hpm_ev[hj] != 4'd0 && hpm_ev[hj] <= 4'd13 && hpm_evt[hpm_ev[hj]])
                    hpm_cnt[hj] <= hpm_cnt[hj] + 64'd1;
                if (csr_write && csr_addr == 12'h323 + hj) hpm_ev[hj] <= csr_new[3:0];
            end
            if (csr_write && csr_addr == 12'h320) begin
                mcinh   <= {csr_new[2], 1'b0, csr_new[0]};
                hpm_inh <= csr_new[31:3] & ((30'd1 << HPM_N) - 30'd1);
            end
        end
    end


    // ---- PMP (bao ve bo nho vat ly), PMP_N muc, do mien 4 byte (G = 0) ----
    // Che do: 0 OFF, 1 TOR (pmpaddr[i-1] <= dia chi >> 2 < pmpaddr[i]), 2 NA4, 3 NAPOT. Muc so nho nhat khop duoc
    // dung; muc khong khoa (L = 0) khong rang buoc che do M (loi chi co che do M). Moi byte cua truy cap phai khop cung
    // mot muc, khop mot phan la loi. Kiem o EX: fetch (pc .. pc + do dai - 1), load / store (ea .. ea + kich thuoc - 1;
    // truy cap lech toi 2 tu 4 byte). Ghi CSR: muc khoa bo qua ghi; pmpaddr[i] cung bo qua khi muc i+1 la TOR va khoa;
    // R = 0 thi W bi xoa (to hop du phong), bit 5-6 doc 0 (giong Spike).
    localparam PN = (PMP_N > 0) ? PMP_N : 1;
    reg  [7:0]  pmp_cfg  [0:PN-1];
    reg  [31:0] pmp_addr [0:PN-1];
    // mat na cua tung muc, tinh mot lan dung chung cho 4 lan tra: NAPOT = cac bit 1 cuoi + bit 0 dau tien,
    // NA4 = 0, nen NA4 va NAPOT dung chung mot bo so sanh bang co mat na; pmp_am = pmpaddr | mat na
    wire [31:0] pmp_mk [0:PN-1];
    wire [31:0] pmp_am [0:PN-1];
    genvar gk;
    generate for (gk = 0; gk < PN; gk = gk + 1) begin : g_pmk
        assign pmp_mk[gk] = pmp_cfg[gk][3] ? pmp_addr[gk] ^ (pmp_addr[gk] + 32'd1) : 32'd0;
        assign pmp_am[gk] = pmp_addr[gk] | pmp_mk[gk];
    end endgenerate
    // 4 dia chi kiem: 0 = pc, 1 = pc + 2 (nua sau lenh 32 bit, kiem rieng nhu Spike: loi thi mtval = pc + 2),
    // 2 = tu dau, 3 = tu cuoi cua load / store (chi khac tu dau khi truy cap lech chay bang phan cung, MISALIGNED = 1;
    // khi MISALIGNED = 0 truy cap lech da trap o ld_misal / st_misal nen bo luon bo so sanh thu tu).
    // Moi (dia chi, muc) co mot bo so sanh nho hon (can tren TOR; can duoi TOR cua muc k la phu dinh so sanh can tren
    // cua muc k-1) va mot bo so sanh bang co mat na (NA4 / NAPOT). Viet bang mang bit (khong dung ham co vong lap) de
    // mo phong nhanh. Muc so nho nhat khop duoc dung: one-hot = m & -m.
    wire [31:0] if_p2  = idex_pc + 32'd2;
    wire [31:0] ls_end = (MISALIGNED == 0) ? d_paddr :
                         d_paddr + {30'd0, idex_funct3[1:0] == 2'b10 ? 2'd3 : (idex_funct3[1:0] == 2'b01 ? 2'd1 : 2'd0)};
    // dia chi vat ly: lenh (idex_ppa / idex_ppa2 = pc / pc + 2 khi khong dich), load / store (d_paddr), PTE (lan 4)
    wire [31:0] ppa2   = (MMU != 0) ? idex_ppa2 : if_p2;
    wire [29:0] pmp_w0 = ((MMU != 0) ? idex_ppa[31:2] : idex_pc[31:2]), pmp_w1 = ppa2[31:2], pmp_w2 = d_paddr[31:2];
    wire [29:0] pmp_w4 = mmu_maddr[31:2];
    wire [29:0] pmp_w3 = ls_end[31:2];
    localparam PA_N = (SU != 0 && MMU != 0) ? 5 : 4;      // lan 4: dia chi PTE cua bo duyet bang trang
    wire [5*PN-1:0] pmp_lt_f, pmp_m_f, pmp_oh_f;            // [a*PN + k]: dia chi a nho hon pmpaddr k / khop muc k
    wire [3*PN-1:0] pmp_ok3;                               // [3k +: 3] = {X, W, R} cho phep o che do M
    genvar ga;
    generate
        for (gk = 0; gk < PN; gk = gk + 1) begin : g_pok
            assign pmp_ok3[3 * gk +: 3] = ~{3{pmp_cfg[gk][7]}} | pmp_cfg[gk][2:0];     // khong khoa: khong rang buoc
        end
        for (ga = 0; ga < PA_N; ga = ga + 1) begin : g_pa
            wire [31:0] W = {2'b00, (ga == 0) ? pmp_w0 : (ga == 1) ? pmp_w1 : (ga == 2) ? pmp_w2 :
                                    (ga == 3) ? pmp_w3 : pmp_w4};
            wire [PN-1:0] mm = pmp_m_f[ga * PN +: PN];
            for (gk = 0; gk < PN; gk = gk + 1) begin : g_pe
                wire lo_ok = (gk == 0) ? 1'b1 : ~pmp_lt_f[ga * PN + ((gk == 0) ? 0 : gk - 1)];
                assign pmp_lt_f[ga * PN + gk] = W < pmp_addr[gk];
                assign pmp_m_f[ga * PN + gk]  = (gk < PMP_N) &
                    ((pmp_cfg[gk][4:3] == 2'd1) ? (lo_ok & pmp_lt_f[ga * PN + gk]) :
                     (pmp_cfg[gk][4] & ((W | pmp_mk[gk]) == pmp_am[gk])));
            end
            assign pmp_oh_f[ga * PN +: PN] = mm & (~mm + 1'b1);
        end
        if (PA_N == 4) begin : g_pa4
            assign pmp_lt_f[4 * PN +: PN] = {PN{1'b0}};
            assign pmp_m_f[4 * PN +: PN]  = {PN{1'b0}};
            assign pmp_oh_f[4 * PN +: PN] = {PN{1'b0}};
        end
    endgenerate
    wire [PN-1:0] pmp_okr, pmp_okw, pmp_okx;
    generate for (gk = 0; gk < PN; gk = gk + 1) begin : g_pv
        assign {pmp_okx[gk], pmp_okw[gk], pmp_okr[gk]} = pmp_ok3[3 * gk +: 3];
    end endgenerate
    wire [PN-1:0] pmp_m0 = pmp_m_f[0 +: PN], pmp_m1 = pmp_m_f[PN +: PN], pmp_m2 = pmp_m_f[2 * PN +: PN];
    wire [PN-1:0] pmp_m3 = pmp_m_f[3 * PN +: PN];
    wire [PN-1:0] pmp_oh0 = pmp_oh_f[0 +: PN], pmp_oh1 = pmp_oh_f[PN +: PN], pmp_oh2 = pmp_oh_f[2 * PN +: PN];
    wire [PN-1:0] pmp_oh3 = pmp_oh_f[3 * PN +: PN];
    // doc PTE: kiem nhu truy cap doc o che do S (moi muc rang buoc, khong khop la loi)
    wire [PN-1:0] pmp_m4 = pmp_m_f[4 * PN +: PN], pmp_oh4 = pmp_oh_f[4 * PN +: PN];
    assign mmu_pte_ok = (PMP_N == 0) | ((|pmp_m4) & |(pmp_oh4 & pmp_pr));
    // che do S / U (SU = 1): moi muc rang buoc (bo qua L), khong khop muc nao la loi. Load / store dung che do
    // hieu dung MPP khi mstatus.MPRV = 1; fetch dung che do hien tai.
    wire        pm_i    = (priv == 2'd3);
    wire        pm_d    = ((SU != 0) & st_mprv) ? (st_mpp == 2'd3) : pm_i;
    wire [PN-1:0] pmp_px, pmp_pw, pmp_pr;                  // quyen R / W / X thuan (che do S / U)
    generate for (gk = 0; gk < PN; gk = gk + 1) begin : g_pp
        assign {pmp_px[gk], pmp_pw[gk], pmp_pr[gk]} = pmp_cfg[gk][2:0];
    end endgenerate
    wire [PN-1:0] okx_i = pm_i ? pmp_okx : pmp_px;
    wire [PN-1:0] okr_d = pm_d ? pmp_okr : pmp_pr;
    wire [PN-1:0] okw_d = pm_d ? pmp_okw : pmp_pw;
    wire        if_f1   = (|pmp_m0) ? ~|(pmp_oh0 & okx_i) : ~pm_i;
    wire        if_f2   = (ENABLE_C != 0) & ~idex_c & idex_pc[1] & ((|pmp_m1) ? ~|(pmp_oh1 & okx_i) : ~pm_i);
    // load / store: khong muc nao khop ca hai tu thi duoc phep (chi che do M); khop thi ca hai tu phai khop cung muc
    wire        ls_hit  = (|pmp_m2) | (|pmp_m3);
    wire        ls_same = (|pmp_m2) & (|pmp_m3) & (pmp_oh2 == pmp_oh3);
    assign pmp_ifault = (PMP_N != 0) & idex_valid & ~irq_take & (if_f1 | if_f2);
    assign pmp_itval  = if_f1 ? idex_pc : if_p2;
    assign pmp_lfault = (PMP_N != 0) & idex_load  & ~ld_trap & (ls_hit ? ~(ls_same & |(pmp_oh2 & okr_d)) : ~pm_d);
    // AMO doc roi ghi: can ca quyen R va W cua muc khop (vi pham luon bao nhu store / AMO, cause 7); SC bi kiem nhu store ke ca khi se that bai
    assign pmp_sfault = (PMP_N != 0) & (idex_store | idex_amo) & ~st_trap &
                        (ls_hit ? ~(ls_same & |(pmp_oh2 & okw_d & (idex_amo ? okr_d : {PN{1'b1}}))) : ~pm_d);
    // doc CSR
    integer pk;
    always @* begin
        pmp_rdata = 32'd0;
        for (pk = 0; pk < PMP_N; pk = pk + 1) begin
            if (csr_addr == 12'h3A0 + pk / 4) pmp_rdata = pmp_rdata | ({24'd0, pmp_cfg[pk]} << (8 * (pk % 4)));
            if (csr_addr == 12'h3B0 + pk)     pmp_rdata = pmp_addr[pk];
        end
    end
    // ghi CSR
    reg [7:0] pmp_wcfg;
    integer   pw;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pw = 0; pw < PN; pw = pw + 1) begin pmp_cfg[pw] <= 8'd0; pmp_addr[pw] <= 32'd0; end
        end else if (csr_write) begin
            for (pw = 0; pw < PMP_N; pw = pw + 1) begin
                if (csr_addr == 12'h3A0 + pw / 4 && !pmp_cfg[pw][7]) begin
                    pmp_wcfg = csr_new[8 * (pw % 4) +: 8] & 8'h9F;
                    if (!pmp_wcfg[0]) pmp_wcfg[1] = 1'b0;                   // R = 0, W = 1: du phong -> xoa W
                    pmp_cfg[pw] <= pmp_wcfg;
                end
                if (csr_addr == 12'h3B0 + pw && !pmp_cfg[pw][7] &&
                    !(pw + 1 < PMP_N && pmp_cfg[(pw + 1 < PMP_N) ? pw + 1 : pw][7] &&
                      pmp_cfg[(pw + 1 < PMP_N) ? pw + 1 : pw][4:3] == 2'd1))
                    pmp_addr[pw] <= csr_new;
            end
        end
    end
endmodule
