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
// - Ngat: irq_timer (MTIP) va irq_ext (MEIP), muc cao, giu cho toi khi phan mem xoa nguon ngat. Ngat duoc nhan o EX
//   khi mstatus.MIE = 1 va bit tuong ung trong mie bat: lenh dang o EX khong thuc thi, mepc = pc cua lenh do,
//   mcause = 0x8000000B (ngoai) hoac 0x80000007 (timer), nhay toi mtvec giong trap. Lenh M dang chay khong bi ngat
//   (ngat cho lenh ke tiep). mip (0x344) chi doc, phan anh truc tiep hai chan ngat.
// - Cac tin hieu memwb_* duoc testbench doc truc tiep (tang commit) de in vet
// Can bien dich cung rv32i_core.v (de lay module rv32m) hoac dua module rv32m vao cung file khi tong hop.
module rv32im_pipeline (
    input  wire        clk,
    input  wire        rst_n,

    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,

    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata,

    input  wire        irq_timer,      // MTIP, tu bo dem mtime/mtimecmp ben ngoai (rv32_mtimer.v)
    input  wire        irq_ext         // MEIP
);
    localparam NOP = 32'h0000_0013;

    // ============================================================
    // Khai bao truoc cac tin hieu dung cheo giua cac tang
    // ============================================================
    wire        id_fa_mem, id_fa_wb, id_fb_mem, id_fb_wb;   // chon forwarding, tinh san o ID
    wire        stall;                 // load-use: giu IF/ID va PC, chen bong bay vao EX
    wire        ex_stall;              // lenh M dang chay o EX: dong bang IF/ID/EX
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
    reg  [31:0] pc;
    reg         ifid_valid;
    reg  [31:0] ifid_pc, ifid_instr;

    assign imem_addr = pc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc         <= 32'd0;
            ifid_valid <= 1'b0;
        end else if (redirect_q) begin
            pc         <= redirect_pc_q;
            ifid_valid <= 1'b0;                // huy lenh vua doc nham duong
        end else if (id_redirect & ~ex_stall) begin   // nhay som o ID: huy lenh vua doc tuan tu o IF
            pc         <= id_target;
            ifid_valid <= 1'b0;
        end else if (!(stall | ex_stall)) begin
            pc         <= pc + 32'd4;
            ifid_valid <= 1'b1;
        end
    end

    // Truong du lieu cua IF/ID (pc, lenh) khong bi redirect dieu khien enable: lenh bi huy da duoc danh dau bang
    // ifid_valid = 0. Nho vay tin hieu redirect (ket qua so sanh nhanh o EX) khong phai toi hang chuc flip-flop nay.
    always @(posedge clk) begin
        if (!(stall | ex_stall)) begin
            ifid_pc    <= pc;
            ifid_instr <= imem_data;
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

    wire legal_reg    = is_reg & (f7_zero | f7_m | (f7_alt & (funct3 == 3'b000 | funct3 == 3'b101)));
    wire legal_imm    = is_imm & ((funct3 == 3'b001) ? f7_zero :
                                  (funct3 == 3'b101) ? (f7_zero | f7_alt) : 1'b1);
    wire legal_load   = is_load & (funct3 == 3'b000 | funct3 == 3'b001 | funct3 == 3'b010 |
                                   funct3 == 3'b100 | funct3 == 3'b101);
    wire legal_store  = is_store & (funct3 == 3'b000 | funct3 == 3'b001 | funct3 == 3'b010);
    wire legal_branch = is_branch & (funct3 != 3'b010 & funct3 != 3'b011);
    wire legal_jalr   = is_jalr & (funct3 == 3'b000);
    wire legal_fence  = is_fence & (funct3 == 3'b000 | funct3 == 3'b001);

    wire is_ecall  = (instr == 32'h0000_0073);
    wire is_ebreak = (instr == 32'h0010_0073);
    wire is_mret   = (instr == 32'h3020_0073);
    wire is_csr    = is_system & (funct3 != 3'b000) & (funct3 != 3'b100);

    // CSR co ton tai khong, co ghi duoc khong: chi phu thuoc cac bit cua lenh nen xet duoc ngay o ID
    wire [11:0] id_csr_addr = instr[31:20];
    reg         id_csr_exists;
    always @* begin
        case (id_csr_addr)
            12'h300, 12'h301, 12'h304, 12'h305, 12'h340, 12'h341, 12'h342, 12'h343, 12'h344, 12'hF14: id_csr_exists = 1'b1;
            default: id_csr_exists = 1'b0;
        endcase
    end
    wire id_csr_we_req = (funct3[1:0] == 2'b01) | (rs1 != 5'd0);
    wire id_csr_ro     = (id_csr_addr[11:10] == 2'b11);
    wire legal_csr     = is_csr & id_csr_exists & ~(id_csr_we_req & id_csr_ro);

    wire illegal = ~(is_lui | is_auipc | is_jal | legal_jalr | legal_branch | legal_load |
                     legal_store | legal_imm | legal_reg | legal_fence |
                     is_ecall | is_ebreak | is_mret | legal_csr);

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    wire [31:0] imm = is_store            ? imm_s :
                      is_branch           ? imm_b :
                      (is_lui | is_auipc) ? imm_u :
                      is_jal              ? imm_j : imm_i;

    wire rd_we = is_lui | is_auipc | is_jal | legal_jalr | legal_load | legal_imm | legal_reg | legal_csr;

    // toan hang nao that su duoc dung
    wire uses_rs1 = ~(is_lui | is_auipc | is_jal);
    wire uses_rs2 = is_reg | is_branch | is_store;

    // ---- Du doan nhanh o ID ----
    localparam BHT_BITS = 6;                                  // 64 muc x 2 bit
    reg  [1:0]  bht [0:(1<<BHT_BITS)-1];                      // 00/01: khong nhay, 10/11: nhay
    wire [BHT_BITS-1:0] bht_idx = ifid_pc[BHT_BITS+1:2];
    wire        id_pred_taken = legal_branch & bht[bht_idx][1];
    assign id_target   = ifid_pc + imm;                       // imm da chon imm_b / imm_j theo opcode
    // khi EX cung redirect thi redirect (EX) thang nho thu tu uu tien trong khoi IF, nen khong can dieu kien them o day
    assign id_redirect = ifid_valid & ~stall & (is_jal | id_pred_taken);

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
    reg  [31:0] idex_pc, idex_instr, idex_rs1_val, idex_rs2_val, idex_imm;
    reg  [4:0]  idex_rs1, idex_rs2, idex_rd;
    reg  [2:0]  idex_funct3;
    reg         idex_f7_5;
    reg         idex_lui_r, idex_auipc_r, idex_jal_r, idex_jalr_r, idex_branch_r, idex_load_r, idex_store_r, idex_imm_op_r, idex_reg_op_r;
    reg         idex_rd_we_r;
    reg         idex_fa_mem, idex_fa_wb, idex_fb_mem, idex_fb_wb;   // forwarding: lay tu EX/MEM hoac MEM/WB
    reg         idex_illegal_r, idex_ecall_r, idex_ebreak_r, idex_mret_r, idex_csr_r, idex_mext_r;
    // Cac co dieu khien chi co hieu luc khi idex_valid = 1. Nho vay lenh bi huy boi redirect chi can xoa idex_valid
    // (1 flip-flop) thay vi xoa ~20 co o day, giam so flip-flop ma redirect phai toi.
    wire idex_lui = idex_lui_r & idex_valid;
    wire idex_auipc = idex_auipc_r & idex_valid;
    wire idex_jal = idex_jal_r & idex_valid;
    wire idex_jalr = idex_jalr_r & idex_valid;
    wire idex_branch = idex_branch_r & idex_valid;
    wire idex_load = idex_load_r & idex_valid;
    wire idex_store = idex_store_r & idex_valid;
    wire idex_imm_op = idex_imm_op_r & idex_valid;
    wire idex_reg_op = idex_reg_op_r & idex_valid;
    wire idex_rd_we = idex_rd_we_r & idex_valid;
    wire idex_illegal = idex_illegal_r & idex_valid;
    wire idex_ecall = idex_ecall_r & idex_valid;
    wire idex_ebreak = idex_ebreak_r & idex_valid;
    wire idex_mret = idex_mret_r & idex_valid;
    wire idex_csr = idex_csr_r & idex_valid;
    wire idex_mext = idex_mext_r & idex_valid;

    // load-use
    assign stall = ifid_valid & idex_valid & idex_load & (idex_rd != 5'd0) &
                   ((uses_rs1 & (idex_rd == rs1)) | (uses_rs2 & (idex_rd == rs2)));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idex_valid_r <= 1'b0;
            idex_lui_r    <= 1'b0; idex_auipc_r  <= 1'b0; idex_jal_r    <= 1'b0; idex_jalr_r   <= 1'b0;
            idex_branch_r <= 1'b0; idex_load_r   <= 1'b0; idex_store_r  <= 1'b0;
            idex_imm_op_r <= 1'b0; idex_reg_op_r <= 1'b0; idex_rd_we_r  <= 1'b0;
            idex_fa_mem <= 1'b0; idex_fa_wb  <= 1'b0; idex_fb_mem <= 1'b0; idex_fb_wb  <= 1'b0;
            idex_illegal_r <= 1'b0; idex_ecall_r <= 1'b0; idex_ebreak_r <= 1'b0;
            idex_mret_r   <= 1'b0; idex_csr_r    <= 1'b0; idex_mext_r   <= 1'b0;
            idex_pred_taken <= 1'b0;
        end else if (ex_stall) begin
            // lenh M dang chay o EX: giu nguyen ID/EX
        end else begin
            // redirect_q chi dieu khien idex_valid_r; stall (tin hieu som) xoa cac co con lai
            idex_valid_r <= ifid_valid & ~redirect_q & ~stall;
            if (stall) begin
                idex_pred_taken <= 1'b0;
                idex_lui_r    <= 1'b0; idex_auipc_r  <= 1'b0; idex_jal_r    <= 1'b0; idex_jalr_r   <= 1'b0;
                idex_branch_r <= 1'b0; idex_load_r   <= 1'b0; idex_store_r  <= 1'b0;
                idex_imm_op_r <= 1'b0; idex_reg_op_r <= 1'b0; idex_rd_we_r  <= 1'b0;
                idex_fa_mem <= 1'b0; idex_fa_wb  <= 1'b0; idex_fb_mem <= 1'b0; idex_fb_wb  <= 1'b0;
                idex_illegal_r <= 1'b0; idex_ecall_r <= 1'b0; idex_ebreak_r <= 1'b0;
                idex_mret_r   <= 1'b0; idex_csr_r    <= 1'b0; idex_mext_r   <= 1'b0;
            end else begin
                idex_pred_taken <= id_pred_taken;
                idex_lui_r     <= is_lui & ifid_valid;
                idex_auipc_r   <= is_auipc & ifid_valid;
                idex_jal_r     <= is_jal & ifid_valid;
                idex_jalr_r    <= legal_jalr & ifid_valid;
                idex_branch_r  <= legal_branch & ifid_valid;
                idex_load_r    <= legal_load & ifid_valid;
                idex_store_r   <= legal_store & ifid_valid;
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
                idex_csr_r     <= legal_csr & ifid_valid;
                idex_mext_r    <= (is_reg & f7_m) & ifid_valid;
            end
        end
    end

    // Truong du lieu cua ID/EX khong can xoa khi chen bong bay (co idex_valid va cac co dieu khien xoa roi),
    // nen khong de redirect/stall dieu khien enable cua chung: cat tai cao cua tin hieu redirect.
    always @(posedge clk) begin
        if (!ex_stall) begin
            idex_pc      <= ifid_pc;
            idex_instr   <= ifid_instr;
            idex_rs1_val <= rf_rs1;
            idex_rs2_val <= rf_rs2;
            idex_imm     <= imm;
            idex_rs1     <= rs1;
            idex_rs2     <= rs2;
            idex_rd      <= rd;
            idex_funct3  <= funct3;
            idex_f7_5    <= instr[30];
        end
    end

    // ============================================================
    // EX
    // ============================================================
    reg         exmem_valid, exmem_rd_we, exmem_load, exmem_store;
    reg  [31:0] exmem_pc, exmem_instr, exmem_result, exmem_store_val;
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

    // nhan/chia
    wire        m_done;
    wire [31:0] m_result;
    rv32m #(.PREP(1), .STEPS(2)) u_m (
        .clk(clk), .rst_n(rst_n),
        .req(idex_mext), .funct3(idex_funct3),
        .a(op_a), .b(op_b),
        .done(m_done), .result(m_result)
    );
    assign ex_stall = idex_mext & ~m_done;

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
    wire [31:0] jalr_target = (op_a + idex_imm) & 32'hFFFF_FFFE;

    // ---- CSR (doc/ghi o EX, dung thu tu chuong trinh) ----
    reg         mstatus_mie, mstatus_mpie;
    reg  [31:2] mtvec_r, mepc_r;
    reg  [31:0] mscratch, mcause_r, mtval_r;
    reg         mie_mtie, mie_meie;
    reg         mip_mtip, mip_meip;                        // chan ngat duoc dong bo qua 1 flip-flop
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin mip_mtip <= 1'b0; mip_meip <= 1'b0; end
        else        begin mip_mtip <= irq_timer; mip_meip <= irq_ext; end
    end

    wire [11:0] csr_addr = idex_instr[31:20];
    reg  [31:0] csr_rdata;
    always @* begin
        case (csr_addr)
            12'h300: csr_rdata = {19'b0, 2'b11, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
            12'h301: csr_rdata = 32'h4000_0100;
            12'h304: csr_rdata = {20'b0, mie_meie, 3'b0, mie_mtie, 7'b0};
            12'h305: csr_rdata = {mtvec_r, 2'b00};
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = {mepc_r, 2'b00};
            12'h342: csr_rdata = mcause_r;
            12'h343: csr_rdata = mtval_r;
            12'h344: csr_rdata = {20'b0, mip_meip, 3'b0, mip_mtip, 7'b0};
            default: csr_rdata = 32'd0;                    // 0xF14 mhartid
        endcase
    end

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
    // ---- ngat ----
    // Chi xet tren thanh ghi (mstatus, mie, mip) va idex_valid nen la tin hieu som. Lenh M dang chay khong bi ngat.
    wire irq_meip  = mip_meip & mie_meie;
    wire irq_any   = mstatus_mie & (irq_meip | (mip_mtip & mie_mtie));
    wire irq_take  = irq_any & idex_valid & ~idex_mext_r;

    wire csr_write = idex_csr & csr_we_req & ~irq_take;     // idex_csr chi bat cho CSR hop le

    // ---- trap ----
    // dia chi nhay phai chia het cho 4 (khong co lenh nen C)
    wire misaligned = (idex_jal & pc_imm[1]) | (idex_jalr & jalr_target[1]) |
                      (idex_branch & take_branch & pc_imm[1]);
    wire [31:0] bad_target = idex_jal ? pc_imm : (idex_jalr ? jalr_target : pc_imm);

    // load/store lech dia chi: chi can 2 bit thap cua dia chi hieu dung (cong 2 bit, khong cho adder 32 bit)
    wire [1:0]  ea_lo = op_a[1:0] + idex_imm[1:0];
    wire [31:0] ea    = op_a + idex_imm;
    wire ld_misal = idex_load  & (((idex_funct3[1:0] == 2'b01) & ea_lo[0]) | ((idex_funct3[1:0] == 2'b10) & (ea_lo != 2'b00)));
    wire st_misal = idex_store & (((idex_funct3[1:0] == 2'b01) & ea_lo[0]) | ((idex_funct3[1:0] == 2'b10) & (ea_lo != 2'b00)));

    wire trap_ex = irq_take | idex_illegal | idex_ecall | idex_ebreak | misaligned | ld_misal | st_misal;
    wire mret_ex = idex_mret & ~irq_take;

    reg [31:0] trap_cause, trap_tval;
    always @* begin
        if (irq_take)           begin trap_cause = irq_meip ? 32'h8000_000B : 32'h8000_0007; trap_tval = 32'd0; end
        else if (idex_illegal)  begin trap_cause = 32'd2;  trap_tval = idex_instr; end
        else if (idex_ecall)    begin trap_cause = 32'd11; trap_tval = 32'd0;      end
        else if (idex_ebreak)   begin trap_cause = 32'd3;  trap_tval = idex_pc;    end
        else if (ld_misal)      begin trap_cause = 32'd4;  trap_tval = ea;         end
        else if (st_misal)      begin trap_cause = 32'd6;  trap_tval = ea;         end
        else                    begin trap_cause = 32'd0;  trap_tval = bad_target; end
    end

    // doan sai: nhanh thuc te khac du doan. Dich khi doan sai: doan "nhay" -> chay tiep pc+4; doan "khong nhay" -> pc+imm.
    // JAL da nhay o ID nen khong con redirect o EX. redirect_pc khong phu thuoc ket qua so sanh nhanh.
    wire mispredict    = idex_branch & (take_branch ^ idex_pred_taken);
    assign redirect    = trap_ex | mret_ex | idex_jalr | mispredict;
    assign redirect_pc = trap_ex ? {mtvec_r, 2'b00} :
                         mret_ex ? {mepc_r, 2'b00}  :
                         idex_jalr ? jalr_target : (idex_pred_taken ? idex_pc + 32'd4 : pc_imm);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) redirect_q <= 1'b0;
        else        redirect_q <= redirect;
    end
    always @(posedge clk) redirect_pc_q <= redirect_pc;

    // Ghi CSR khi trap cung tre 1 chu ky: trap_ex phu thuoc ket qua so sanh nhanh (dich nhanh lech), nen khong de no
    // dieu khien enable cua ~100 flip-flop mepc/mcause/mtval cung chu ky. Lenh o EX chu ky sau da bi redirect_q vo hieu
    // va lenh dau tien cua trinh xu ly trap toi EX sau it nhat 3 chu ky, nen ghi tre khong doi hanh vi.
    reg         trap_q;
    reg  [29:0] tepc_q;
    reg  [3:0]  tcause_q;
    reg         tint_q;
    reg  [31:0] ttval_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) trap_q <= 1'b0;
        else        trap_q <= trap_ex;
    end
    always @(posedge clk) begin
        tepc_q       <= idex_pc[31:2];
        tcause_q     <= trap_cause[3:0];
        tint_q       <= trap_cause[31];
        ttval_q      <= trap_tval;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mtvec_r      <= 30'd0;
            mepc_r       <= 30'd0;
            mscratch     <= 32'd0;
            mcause_r     <= 32'd0;
            mtval_r      <= 32'd0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
        end else if (trap_q) begin
            mepc_r       <= tepc_q;
            mcause_r     <= {tint_q, 27'd0, tcause_q};
            mtval_r      <= ttval_q;
            mstatus_mpie <= mstatus_mie;
            mstatus_mie  <= 1'b0;
        end else if (mret_ex) begin
            mstatus_mie  <= mstatus_mpie;
            mstatus_mpie <= 1'b1;
        end else if (csr_write) begin
            case (csr_addr)
                12'h300: begin mstatus_mie <= csr_new[3]; mstatus_mpie <= csr_new[7]; end
                12'h304: begin mie_mtie <= csr_new[7]; mie_meie <= csr_new[11]; end
                12'h305: mtvec_r  <= csr_new[31:2];
                12'h340: mscratch <= csr_new;
                12'h341: mepc_r   <= csr_new[31:2];
                12'h342: mcause_r <= csr_new;
                12'h343: mtval_r  <= csr_new;
                default: ;
            endcase
        end
    end

    // ket qua cua tang EX (voi load/store: dia chi)
    wire [31:0] ex_result = idex_lui              ? idex_imm        :
                            idex_auipc            ? pc_imm          :
                            (idex_jal | idex_jalr)? idex_pc + 32'd4 :
                            idex_csr              ? csr_rdata       :
                            idex_mext             ? m_result        :
                            (idex_load | idex_store) ? (op_a + idex_imm) :
                                                      alu_out;

    // cap nhat bang dem tre 1 chu ky: EX ghi ket qua nhanh vao thanh ghi, tang MEM moi sua bang
    reg                 exmem_bupd, exmem_btaken;
    reg [BHT_BITS-1:0]  exmem_bidx;
    integer bi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exmem_bupd <= 1'b0; exmem_btaken <= 1'b0; exmem_bidx <= {BHT_BITS{1'b0}};
            for (bi = 0; bi < (1<<BHT_BITS); bi = bi + 1) bht[bi] <= 2'b01;      // khoi dau: yeu, khong nhay
        end else begin
            exmem_bupd   <= idex_valid & idex_branch;
            exmem_btaken <= take_branch;
            exmem_bidx   <= idex_pc[BHT_BITS+1:2];
            if (exmem_bupd) begin
                if (exmem_btaken) begin if (bht[exmem_bidx] != 2'b11) bht[exmem_bidx] <= bht[exmem_bidx] + 2'd1; end
                else              begin if (bht[exmem_bidx] != 2'b00) bht[exmem_bidx] <= bht[exmem_bidx] - 2'd1; end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exmem_valid <= 1'b0;
            exmem_rd_we <= 1'b0;
            exmem_load  <= 1'b0;
            exmem_store <= 1'b0;
        end else begin
            exmem_valid     <= idex_valid & ~ex_stall;      // M chua xong: nhan bong bay
            exmem_rd_we     <= idex_rd_we & ~ex_stall & ~trap_ex;
            exmem_load      <= idex_load & ~ex_stall & ~trap_ex;
            exmem_store     <= idex_store & ~ex_stall & ~trap_ex;
            exmem_pc        <= idex_pc;
            exmem_instr     <= idex_instr;
            exmem_rd        <= idex_rd;
            exmem_funct3    <= idex_funct3;
            exmem_result    <= ex_result;
            exmem_store_val <= op_b;
        end
    end

    // ============================================================
    // MEM
    // ============================================================
    assign dmem_addr = exmem_result;
    wire [1:0] byte_off = exmem_result[1:0];

    reg [31:0] st_data;
    reg [3:0]  st_strb;
    always @* begin
        case (exmem_funct3[1:0])
            2'b00: begin
                st_data = {4{exmem_store_val[7:0]}};
                st_strb = 4'b0001 << byte_off;
            end
            2'b01: begin
                st_data = {2{exmem_store_val[15:0]}};
                st_strb = byte_off[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                st_data = exmem_store_val;
                st_strb = 4'b1111;
            end
        endcase
    end

    assign dmem_we    = exmem_valid & exmem_store;
    assign dmem_wdata = st_data;
    assign dmem_wstrb = dmem_we ? st_strb : 4'b0000;

    reg [31:0] ld_data;
    reg [7:0]  ld_byte;
    reg [15:0] ld_half;
    always @* begin
        ld_byte = dmem_rdata >> {byte_off, 3'b000};
        ld_half = byte_off[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];
        case (exmem_funct3)
            3'b000:  ld_data = {{24{ld_byte[7]}},  ld_byte};
            3'b001:  ld_data = {{16{ld_half[15]}}, ld_half};
            3'b100:  ld_data = {24'b0, ld_byte};
            3'b101:  ld_data = {16'b0, ld_half};
            default: ld_data = dmem_rdata;
        endcase
    end

    wire [31:0] mem_val = exmem_load ? ld_data : exmem_result;
    wire [31:0] st_mask = {{8{st_strb[3]}}, {8{st_strb[2]}}, {8{st_strb[1]}}, {8{st_strb[0]}}};

    // ============================================================
    // MEM/WB (cac truong memwb_t* chi de testbench in vet)
    // ============================================================
    reg  [31:0] memwb_pc, memwb_instr;
    reg         memwb_tst;
    reg  [31:0] memwb_taddr, memwb_tdata;
    reg  [3:0]  memwb_tstrb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memwb_valid <= 1'b0;
            memwb_rd_we <= 1'b0;
            memwb_tst   <= 1'b0;
        end else begin
            memwb_valid <= exmem_valid;
            memwb_rd_we <= exmem_rd_we;
            memwb_rd    <= exmem_rd;
            memwb_val   <= mem_val;
            memwb_pc    <= exmem_pc;
            memwb_instr <= exmem_instr;
            memwb_tst   <= dmem_we;
            memwb_taddr <= dmem_we ? dmem_addr : 32'd0;
            memwb_tdata <= dmem_we ? (st_data & st_mask) : 32'd0;
            memwb_tstrb <= dmem_we ? st_strb : 4'd0;
        end
    end
endmodule
