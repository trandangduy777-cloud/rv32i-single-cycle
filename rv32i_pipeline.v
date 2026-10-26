// RV32I pipeline 5 tang (IF / ID / EX / MEM / WB), tu viet
// - Cung cong voi rv32i_core: bo nho lenh va du lieu nam ngoai, doc combinational, ghi dong bo
// - Chi RV32I thuan (chua co CSR, trap, M). Lenh khong thuoc RV32I (FENCE, SYSTEM, ...) duoc coi la NOP.
// - Hazard du lieu:
//     + forwarding tu EX/MEM va MEM/WB vao tang EX (uu tien lenh moi hon)
//     + thanh ghi doc o ID duoc bypass tu WB (ghi va doc cung chu ky)
//     + load-use: dung 1 chu ky (giu PC va IF/ID, chen bong bay vao EX), sau do forward tu WB
// - Hazard dieu khien:
//     + JAL nhay ngay o ID (huy 1 lenh o IF, mat 1 chu ky)
//     + nhanh co dieu kien duoc DOAN o ID bang bang dem 2 bit (BHT_N muc, chi so = pc[BHT_BITS+1:2]);
//       doan "nhay" thi nhay ngay o ID (mat 1 chu ky), doan "khong nhay" thi chay tiep (khong mat)
//     + doan sai duoc phat hien o EX (so sanh ket qua nhanh voi du doan), huy 2 lenh, mat 2 chu ky
//     + JALR van quyet dinh o EX (mat 2 chu ky)
//     + dich nhay duoc tinh dung o ID (pc + imm), nen doan sai chi gay cham, khong bao gio sai ket qua
//     + bang dem duoc cap nhat tre 1 chu ky (qua thanh ghi o tang MEM) de ket qua so sanh nhanh khong
//       phai dieu khien enable cua cac flop bang dem
// - Cac tin hieu memwb_* duoc testbench doc truc tiep (tang commit) de in vet; khong noi ra cong
module rv32i_pipeline (
    input  wire        clk,
    input  wire        rst_n,

    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,

    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata
);
    localparam NOP = 32'h0000_0013;

    // ============================================================
    // Khai bao truoc cac tin hieu dung cheo giua cac tang
    // ============================================================
    wire        id_fa_mem, id_fa_wb, id_fb_mem, id_fb_wb;   // chon forwarding, tinh san o ID
    wire        stall;                 // load-use: giu IF/ID va PC
    wire        redirect;              // EX quyet dinh nhay (doan sai nhanh, hoac JALR)
    wire [31:0] redirect_pc;
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
            ifid_pc    <= 32'd0;
            ifid_instr <= NOP;
        end else if (redirect) begin
            pc         <= redirect_pc;
            ifid_valid <= 1'b0;                // huy lenh vua doc nham duong
            ifid_instr <= NOP;
        end else if (id_redirect) begin        // nhay som o ID: huy lenh vua doc tuan tu o IF
            pc         <= id_target;
            ifid_valid <= 1'b0;
            ifid_instr <= NOP;
        end else if (!stall) begin
            pc         <= pc + 32'd4;
            ifid_valid <= 1'b1;
            ifid_pc    <= pc;
            ifid_instr <= imem_data;
        end
    end

    // ============================================================
    // ID
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

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    wire [31:0] imm = is_store            ? imm_s :
                      is_branch           ? imm_b :
                      (is_lui | is_auipc) ? imm_u :
                      is_jal              ? imm_j : imm_i;

    wire rd_we = is_lui | is_auipc | is_jal | is_jalr | is_load | is_imm | is_reg;

    // toan hang nao that su duoc dung (de khong dung thua khi truong rs1/rs2 thuc ra la immediate)
    wire uses_rs1 = ~(is_lui | is_auipc | is_jal);
    wire uses_rs2 = is_reg | is_branch | is_store;

    // ---- Du doan nhanh o ID ----
    localparam BHT_BITS = 6;                                  // 64 muc x 2 bit
    reg  [1:0]  bht [0:(1<<BHT_BITS)-1];                      // 00/01: khong nhay, 10/11: nhay
    wire [BHT_BITS-1:0] bht_idx = ifid_pc[BHT_BITS+1:2];
    wire        id_pred_taken = is_branch & bht[bht_idx][1];
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
    reg         idex_valid;
    reg         idex_pred_taken;                              // du doan cua nhanh dang o EX
    reg  [31:0] idex_pc, idex_instr, idex_rs1_val, idex_rs2_val, idex_imm;
    reg  [4:0]  idex_rs1, idex_rs2, idex_rd;
    reg  [2:0]  idex_funct3;
    reg         idex_f7_5;
    reg         idex_lui, idex_auipc, idex_jal, idex_jalr, idex_branch, idex_load, idex_store, idex_imm_op, idex_reg_op;
    reg         idex_rd_we;
    reg         idex_fa_mem, idex_fa_wb, idex_fb_mem, idex_fb_wb;   // forwarding: lay tu EX/MEM hoac MEM/WB

    // load-use: lenh o EX la load ghi vao thanh ghi ma lenh o ID can
    assign stall = ifid_valid & idex_valid & idex_load & (idex_rd != 5'd0) &
                   ((uses_rs1 & (idex_rd == rs1)) | (uses_rs2 & (idex_rd == rs2)));

    wire id_bubble = redirect | stall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idex_valid  <= 1'b0;
            idex_lui    <= 1'b0; idex_auipc  <= 1'b0; idex_jal    <= 1'b0; idex_jalr   <= 1'b0;
            idex_branch <= 1'b0; idex_load   <= 1'b0; idex_store  <= 1'b0;
            idex_imm_op <= 1'b0; idex_reg_op <= 1'b0; idex_rd_we  <= 1'b0;
            idex_fa_mem <= 1'b0; idex_fa_wb  <= 1'b0; idex_fb_mem <= 1'b0; idex_fb_wb  <= 1'b0;
            idex_pred_taken <= 1'b0;
        end else if (id_bubble) begin                    // chen bong bay (stall hoac huy sau khi nhay)
            idex_valid  <= 1'b0;
            idex_lui    <= 1'b0; idex_auipc  <= 1'b0; idex_jal    <= 1'b0; idex_jalr   <= 1'b0;
            idex_branch <= 1'b0; idex_load   <= 1'b0; idex_store  <= 1'b0;
            idex_imm_op <= 1'b0; idex_reg_op <= 1'b0; idex_rd_we  <= 1'b0;
            idex_fa_mem <= 1'b0; idex_fa_wb  <= 1'b0; idex_fb_mem <= 1'b0; idex_fb_wb  <= 1'b0;
            idex_pred_taken <= 1'b0;
        end else begin
            idex_valid   <= ifid_valid;
            idex_pred_taken <= id_pred_taken;
            idex_lui     <= is_lui & ifid_valid;
            idex_auipc   <= is_auipc & ifid_valid;
            idex_jal     <= is_jal & ifid_valid;
            idex_jalr    <= is_jalr & ifid_valid;
            idex_branch  <= is_branch & ifid_valid;
            idex_load    <= is_load & ifid_valid;
            idex_store   <= is_store & ifid_valid;
            idex_imm_op  <= is_imm & ifid_valid;
            idex_reg_op  <= is_reg & ifid_valid;
            idex_rd_we   <= rd_we & ifid_valid;
            idex_fa_mem  <= id_fa_mem;
            idex_fa_wb   <= id_fa_wb;
            idex_fb_mem  <= id_fb_mem;
            idex_fb_wb   <= id_fb_wb;
        end
    end

    // Truong du lieu cua ID/EX khong can xoa khi chen bong bay (co idex_valid va cac co dieu khien xoa roi),
    // nen khong de redirect/stall dieu khien enable cua chung: cat tai cao cua tin hieu redirect.
    always @(posedge clk) begin
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

    // doan sai: nhanh thuc te khac du doan. Dich khi doan sai: doan "nhay" -> chay tiep pc+4; doan "khong nhay" -> pc+imm.
    // JAL da nhay o ID nen khong con redirect o EX. redirect_pc khong phu thuoc ket qua so sanh nhanh.
    wire mispredict    = idex_branch & (take_branch ^ idex_pred_taken);
    assign redirect    = idex_valid & (idex_jalr | mispredict);
    assign redirect_pc = idex_jalr ? jalr_target : (idex_pred_taken ? idex_pc + 32'd4 : pc_imm);

    // ket qua cua tang EX (voi load/store: dia chi)
    wire [31:0] ex_result = idex_lui              ? idex_imm        :
                            idex_auipc            ? pc_imm          :
                            (idex_jal | idex_jalr)? idex_pc + 32'd4 :
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
            exmem_valid     <= idex_valid;
            exmem_rd_we     <= idex_rd_we;
            exmem_load      <= idex_load;
            exmem_store     <= idex_store;
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
    // MEM/WB (cac truong memwb_t* chi de testbench in vet, tool tong hop se bo)
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
