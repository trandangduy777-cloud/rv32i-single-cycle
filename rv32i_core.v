// RV32I single-cycle core (tu viet) + Zicsr co ban + trap (chi che do Machine)
// - Bo nho lenh/du lieu nam ngoai core (Harvard), doc lenh va doc du lieu la combinational
// - Ho tro: LUI AUIPC JAL JALR BEQ BNE BLT BGE BLTU BGEU
//           LB LH LW LBU LHU SB SH SW
//           ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI
//           ADD SUB SLL SLT SLTU XOR SRL SRA OR AND
//           FENCE / FENCE.I (coi nhu NOP), ECALL, EBREAK, MRET
//           CSRRW CSRRS CSRRC CSRRWI CSRRSI CSRRCI
//           Phan mo rong M: MUL MULH MULHSU MULHU DIV DIVU REM REMU (nhan/chia lap, nhieu chu ky, core dung pc cho den khi xong)
// - CSR: mstatus(MIE,MPIE; MPP co dinh 11) misa mtvec(che do truc tiep) mscratch mepc mcause mtval mhartid
// - Ngoai le (trap): lenh bat hop le (cause 2), EBREAK (3), ECALL tu M-mode (11),
//                    dia chi lenh nhay toi khong can chinh 4 byte (cause 0),
//                    load/store khong can chinh (cause 4 / 6, mtval = dia chi)
//   Khi trap: lenh gay trap khong ghi thanh ghi/bo nho; mepc=pc, mcause, mtval cap nhat,
//             MPIE<=MIE, MIE<=0, pc<=mtvec. MRET: pc<=mepc, MIE<=MPIE, MPIE<=1.
// - Chua co ngat (interrupt)
module rv32i_core #(
    parameter [31:0] RESET_PC = 32'h0000_0000   // dia chi lenh dau tien sau reset (phai chia het cho 4)
) (
    input  wire        clk,
    input  wire        rst_n,

    // bo nho lenh
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,

    // bo nho du lieu
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,   // byte enable khi ghi
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata
);

    // ------------------------------------------------------------
    // PC
    // ------------------------------------------------------------
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] pc_next;

    assign imem_addr = pc;
    wire [31:0] instr = imem_data;

    // ------------------------------------------------------------
    // Giai ma
    // ------------------------------------------------------------
    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd     = instr[11:7];
    wire [2:0] funct3 = instr[14:12];
    wire [4:0] rs1    = instr[19:15];
    wire [4:0] rs2    = instr[24:20];
    wire       funct7_5 = instr[30];

    localparam OP_LUI    = 7'b0110111;
    localparam OP_AUIPC  = 7'b0010111;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_IMM    = 7'b0010011;
    localparam OP_REG    = 7'b0110011;
    localparam OP_FENCE  = 7'b0001111;
    localparam OP_SYSTEM = 7'b1110011;

    wire is_lui    = (opcode == OP_LUI);
    wire is_auipc  = (opcode == OP_AUIPC);
    wire is_jal    = (opcode == OP_JAL);
    wire is_jalr   = (opcode == OP_JALR);
    wire is_branch = (opcode == OP_BRANCH);
    wire is_load   = (opcode == OP_LOAD);
    wire is_store  = (opcode == OP_STORE);
    wire is_imm    = (opcode == OP_IMM);
    wire is_reg    = (opcode == OP_REG);
    wire is_fence  = (opcode == OP_FENCE);
    wire is_system = (opcode == OP_SYSTEM);

    // Immediate
    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    // ------------------------------------------------------------
    // Register file: 32 x 32, x0 = 0
    // ------------------------------------------------------------
    reg  [31:0] regs [1:31];
    wire [31:0] rs1_val = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
    wire [31:0] rs2_val = (rs2 == 5'd0) ? 32'd0 : regs[rs2];

    // ------------------------------------------------------------
    // Kiem tra lenh hop le (giai ma chat: moi truong khong dung phai dung gia tri quy dinh)
    // ------------------------------------------------------------
    wire f7_zero = (instr[31:25] == 7'b0000000);
    wire f7_alt  = (instr[31:25] == 7'b0100000);
    wire f7_m    = (instr[31:25] == 7'b0000001);      // phan mo rong M

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

    // ------------------------------------------------------------
    // CSR
    // ------------------------------------------------------------
    reg         mstatus_mie, mstatus_mpie;
    reg  [31:2] mtvec_r, mepc_r;
    reg  [31:0] mscratch, mcause_r, mtval_r;

    wire [11:0] csr_addr = instr[31:20];
    reg  [31:0] csr_rdata;
    reg         csr_exists;
    always @* begin
        csr_exists = 1'b1;
        case (csr_addr)
            12'h300: csr_rdata = {19'b0, 2'b11, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
            12'h301: csr_rdata = 32'h4000_0100;           // misa: RV32, chu I
            12'h305: csr_rdata = {mtvec_r, 2'b00};
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = {mepc_r, 2'b00};
            12'h342: csr_rdata = mcause_r;
            12'h343: csr_rdata = mtval_r;
            12'hF14: csr_rdata = 32'd0;                   // mhartid (chi doc)
            default: begin csr_rdata = 32'd0; csr_exists = 1'b0; end
        endcase
    end

    wire        csr_we_req = (funct3[1:0] == 2'b01) | (rs1 != 5'd0);   // RS/RC voi rs1=x0 khong ghi
    wire        csr_ro     = (csr_addr[11:10] == 2'b11);
    wire        csr_ok     = csr_exists & ~(csr_we_req & csr_ro);
    wire        legal_csr  = is_csr & csr_ok;

    wire [31:0] csr_src = funct3[2] ? {27'b0, rs1} : rs1_val;
    reg  [31:0] csr_new;
    always @* begin
        case (funct3[1:0])
            2'b01:   csr_new = csr_src;
            2'b10:   csr_new = csr_rdata | csr_src;
            default: csr_new = csr_rdata & ~csr_src;
        endcase
    end

    // ------------------------------------------------------------
    // ALU
    // ------------------------------------------------------------
    wire [31:0] alu_a = rs1_val;
    wire [31:0] alu_b = (is_reg | is_branch) ? rs2_val : (is_store ? imm_s : imm_i);

    // SUB chi khi OP_REG va funct7[5]=1 voi funct3=000; SRA/SRAI khi funct7[5]=1
    wire do_sub = is_reg & funct7_5;
    wire do_sra = funct7_5;

    wire [4:0] shamt = alu_b[4:0];

    // Tach SRA ra wire signed rieng: neu tron signed/unsigned trong toan tu ?: thi ca bieu thuc thanh unsigned va >>> bi dich logic
    wire signed [31:0] alu_a_s = alu_a;
    wire [31:0] sra_out = alu_a_s >>> shamt;
    wire [31:0] srl_out = alu_a >> shamt;

    reg [31:0] alu_out;
    always @* begin
        case (funct3)
            3'b000: alu_out = do_sub ? (alu_a - alu_b) : (alu_a + alu_b);
            3'b001: alu_out = alu_a << shamt;
            3'b010: alu_out = ($signed(alu_a) < $signed(alu_b)) ? 32'd1 : 32'd0;
            3'b011: alu_out = (alu_a < alu_b) ? 32'd1 : 32'd0;
            3'b100: alu_out = alu_a ^ alu_b;
            3'b101: alu_out = do_sra ? sra_out : srl_out;
            3'b110: alu_out = alu_a | alu_b;
            3'b111: alu_out = alu_a & alu_b;
        endcase
    end

    // Dia chi load/store luon la rs1 + imm (khong qua alu_out de tranh nham funct3)
    wire [31:0] mem_addr = rs1_val + (is_store ? imm_s : imm_i);
    assign dmem_addr = mem_addr;

    // ------------------------------------------------------------
    // Nhanh
    // ------------------------------------------------------------
    wire eq  = (rs1_val == rs2_val);
    wire lt  = ($signed(rs1_val) < $signed(rs2_val));
    wire ltu = (rs1_val < rs2_val);

    reg take_branch;
    always @* begin
        case (funct3)
            3'b000:  take_branch = eq;
            3'b001:  take_branch = ~eq;
            3'b100:  take_branch = lt;
            3'b101:  take_branch = ~lt;
            3'b110:  take_branch = ltu;
            3'b111:  take_branch = ~ltu;
            default: take_branch = 1'b0;
        endcase
    end

    wire [31:0] branch_target = pc + imm_b;
    wire [31:0] jal_target    = pc + imm_j;
    wire [31:0] jalr_target   = (rs1_val + imm_i) & 32'hFFFF_FFFE;

    // ------------------------------------------------------------
    // Phan mo rong M: don vi nhan/chia lap. Lenh M giu pc (stall) cho den khi m_done.
    // retire = 1 o chu ky lenh hoan tat (testbench in vet khi retire = 1)
    // ------------------------------------------------------------
    wire        is_mext = is_reg & f7_m;
    wire        m_done;
    wire [31:0] m_result;
    rv32m u_m (
        .clk(clk), .rst_n(rst_n),
        .req(is_mext), .funct3(funct3),
        .a(rs1_val), .b(rs2_val),
        .done(m_done), .result(m_result)
    );
    wire stall  = is_mext & ~m_done;
    wire retire = ~stall;

    // ------------------------------------------------------------
    // Trap
    // ------------------------------------------------------------
    wire illegal = ~(is_lui | is_auipc | is_jal | legal_jalr | legal_branch | legal_load |
                     legal_store | legal_imm | legal_reg | legal_fence |
                     is_ecall | is_ebreak | is_mret | legal_csr);

    // dia chi nhay toi phai chia het cho 4 (khong co lenh nen C)
    wire misaligned = (is_jal & jal_target[1]) | (legal_jalr & jalr_target[1]) |
                      (legal_branch & take_branch & branch_target[1]);
    wire [31:0] bad_target = is_jal ? jal_target : (is_jalr ? jalr_target : branch_target);

    // load/store lech dia chi: nua tu (LH/LHU/SH) phai chan, tu (LW/SW) phai chia het cho 4
    wire ld_misal = legal_load  & (((funct3[1:0] == 2'b01) & mem_addr[0]) | ((funct3[1:0] == 2'b10) & (mem_addr[1:0] != 2'b00)));
    wire st_misal = legal_store & (((funct3[1:0] == 2'b01) & mem_addr[0]) | ((funct3[1:0] == 2'b10) & (mem_addr[1:0] != 2'b00)));

    wire trap = illegal | is_ecall | is_ebreak | misaligned | ld_misal | st_misal;

    reg [31:0] trap_cause, trap_tval;
    always @* begin
        if (illegal)       begin trap_cause = 32'd2;  trap_tval = instr;      end
        else if (is_ecall) begin trap_cause = 32'd11; trap_tval = 32'd0;      end
        else if (is_ebreak)begin trap_cause = 32'd3;  trap_tval = pc;         end
        else if (ld_misal) begin trap_cause = 32'd4;  trap_tval = mem_addr;   end
        else if (st_misal) begin trap_cause = 32'd6;  trap_tval = mem_addr;   end
        else               begin trap_cause = 32'd0;  trap_tval = bad_target; end
    end

    assign pc_next = stall                        ? pc               :
                     trap                         ? {mtvec_r, 2'b00} :
                     is_mret                      ? {mepc_r, 2'b00}  :
                     is_jal                       ? jal_target    :
                     is_jalr                      ? jalr_target   :
                     (is_branch & take_branch)    ? branch_target :
                                                    pc_plus4;

    // ------------------------------------------------------------
    // Store
    // ------------------------------------------------------------
    assign dmem_we = is_store & ~trap;
    wire [1:0] byte_off = mem_addr[1:0];

    reg [31:0] st_data;
    reg [3:0]  st_strb;
    always @* begin
        case (funct3[1:0])
            2'b00: begin // SB
                st_data = {4{rs2_val[7:0]}};
                st_strb = 4'b0001 << byte_off;
            end
            2'b01: begin // SH
                st_data = {2{rs2_val[15:0]}};
                st_strb = byte_off[1] ? 4'b1100 : 4'b0011;
            end
            default: begin // SW
                st_data = rs2_val;
                st_strb = 4'b1111;
            end
        endcase
    end
    assign dmem_wdata = st_data;
    assign dmem_wstrb = dmem_we ? st_strb : 4'b0000;

    // ------------------------------------------------------------
    // Load
    // ------------------------------------------------------------
    reg [31:0] ld_data;
    reg [7:0]  ld_byte;
    reg [15:0] ld_half;
    always @* begin
        ld_byte = dmem_rdata >> {byte_off, 3'b000};
        ld_half = byte_off[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];
        case (funct3)
            3'b000:  ld_data = {{24{ld_byte[7]}},  ld_byte};   // LB
            3'b001:  ld_data = {{16{ld_half[15]}}, ld_half};   // LH
            3'b100:  ld_data = {24'b0, ld_byte};               // LBU
            3'b101:  ld_data = {16'b0, ld_half};               // LHU
            default: ld_data = dmem_rdata;                     // LW
        endcase
    end

    // ------------------------------------------------------------
    // Ghi nguoc
    // ------------------------------------------------------------
    wire        rd_we = (is_lui | is_auipc | is_jal | is_jalr | is_load | is_imm | is_reg | is_csr) & ~trap & ~stall;
    reg  [31:0] rd_val;
    always @* begin
        if      (is_lui)           rd_val = imm_u;
        else if (is_auipc)         rd_val = pc + imm_u;
        else if (is_jal | is_jalr) rd_val = pc_plus4;
        else if (is_csr)           rd_val = csr_rdata;
        else if (is_mext)          rd_val = m_result;
        else if (is_load)          rd_val = ld_data;
        else                       rd_val = alu_out;
    end

    wire csr_write = is_csr & csr_ok & csr_we_req;   // csr_ok da loai truong hop trap

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc           <= RESET_PC;
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mtvec_r      <= 30'd0;
            mepc_r       <= 30'd0;
            mscratch     <= 32'd0;
            mcause_r     <= 32'd0;
            mtval_r      <= 32'd0;
        end else begin
            pc <= pc_next;
            if (rd_we && rd != 5'd0)
                regs[rd] <= rd_val;

            if (trap) begin
                mepc_r       <= pc[31:2];
                mcause_r     <= trap_cause;
                mtval_r      <= trap_tval;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (is_mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (csr_write) begin
                case (csr_addr)
                    12'h300: begin mstatus_mie <= csr_new[3]; mstatus_mpie <= csr_new[7]; end
                    12'h305: mtvec_r  <= csr_new[31:2];
                    12'h340: mscratch <= csr_new;
                    12'h341: mepc_r   <= csr_new[31:2];
                    12'h342: mcause_r <= csr_new;
                    12'h343: mtval_r  <= csr_new;
                    default: ;
                endcase
            end
        end
    end

endmodule


// ------------------------------------------------------------
// Don vi nhan/chia nguyen lap (32 chu ky lap, 1 bit moi chu ky)
//   funct3: 000 MUL, 001 MULH, 010 MULHSU, 011 MULHU, 100 DIV, 101 DIVU, 110 REM, 111 REMU
// Dung "do lon" (tri tuyet doi) roi sua dau o cuoi.
//   Chia cho 0: thuong = tat ca bit 1, du = so bi chia.  INT_MIN / -1: thuong = INT_MIN, du = 0.
// Giao thuc: req = 1 suot thoi gian lenh M dang cho. Don vi nhan toan hang o chu ky dau (IDLE -> RUN),
//   chay 32 chu ky, roi o trang thai FIN bao done = 1 trong 1 chu ky (core hoan tat lenh) va ve IDLE.
// ------------------------------------------------------------
// Tham so PREP: 0 = lay toan hang va dao dau trong cung 1 chu ky (bo don-cycle dung ban nay);
//               1 = chu ky dau chi chep toan hang tho vao thanh ghi, chu ky sau moi dao dau (them 1 chu ky cho moi lenh M).
//                   Pipeline dung PREP = 1: toan hang di qua mux forwarding nen khong duoc dat them bo cong dao dau phia sau.
// STEPS: so bit xu ly moi chu ky (1, 2 hoac 4). Bo nhan/chia lap lai buoc 1 bit STEPS lan trong mot chu ky,
// nen lenh M mat 32/STEPS chu ky lap thay vi 32; doi lai duong to hop dai gap STEPS lan.
module rv32m #(parameter PREP = 0, parameter STEPS = 1) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire [2:0]  funct3,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        done,
    output reg  [31:0] result
);
    localparam IDLE = 2'd0, RUN = 2'd1, FIN = 2'd2, PRE = 2'd3;

    reg [1:0]  state;
    reg [4:0]  cnt;
    reg [2:0]  op;
    reg [63:0] p;          // nhan: {tich cao, so nhan}; chia: {du, so bi chia/thuong}
    reg [31:0] m;          // nhan: so bi nhan; chia: so chia
    reg        neg_res;    // dao dau ket qua nhan (MULH*) hoac thuong
    reg        neg_rem;    // dao dau du
    reg        sa_r, sb_r; // dau toan hang, chot o chu ky dau (PREP = 1)

    // dau cua toan hang khi bat dau
    wire sa = (funct3 == 3'b001 | funct3 == 3'b010 | funct3 == 3'b100 | funct3 == 3'b110) & a[31];
    wire sb = (funct3 == 3'b001 | funct3 == 3'b100 | funct3 == 3'b110) & b[31];
    wire [31:0] ua = sa ? (~a + 32'd1) : a;
    wire [31:0] ub = sb ? (~b + 32'd1) : b;
    // PREP = 1: dao dau tu thanh ghi (p[31:0] giu a tho, m giu b tho)
    wire [31:0] ua_r = sa_r ? (~p[31:0] + 32'd1) : p[31:0];
    wire [31:0] ub_r = sb_r ? (~m + 32'd1) : m;

    localparam [4:0] LAST = 32 / STEPS - 1;   // chi so chu ky lap cuoi

    // buoc nhan 1 bit: cong don roi dich phai
    function [63:0] mul_step(input [63:0] pp, input [31:0] mm);
        reg [32:0] sum;
        begin
            sum      = {1'b0, pp[63:32]} + (pp[0] ? {1'b0, mm} : 33'd0);
            mul_step = {sum, pp[31:0]} >> 1;
        end
    endfunction

    // buoc chia khoi phuc 1 bit: dich trai {du, thuong} roi thu tru
    function [63:0] div_step(input [63:0] pp, input [31:0] mm);
        reg [32:0] rem, sub;
        reg        ge;
        begin
            rem = {pp[63:32], pp[31]};
            ge  = (rem >= {1'b0, mm});
            sub = rem - {1'b0, mm};
            div_step = ge ? {sub[31:0], pp[30:0], 1'b1} : {rem[31:0], pp[30:0], 1'b0};
        end
    endfunction

    // STEPS buoc noi tiep trong mot chu ky
    reg [63:0] p_next;
    integer k;
    always @* begin
        p_next = p;
        for (k = 0; k < STEPS; k = k + 1)
            p_next = op[2] ? div_step(p_next, m) : mul_step(p_next, m);
    end

    assign done = (state == FIN);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            cnt   <= 5'd0;
            op    <= 3'd0;
            p     <= 64'd0;
            m     <= 32'd0;
            neg_res <= 1'b0;
            neg_rem <= 1'b0;
            sa_r    <= 1'b0;
            sb_r    <= 1'b0;
        end else begin
            case (state)
                IDLE: if (req) begin
                    op  <= funct3;
                    cnt <= 5'd0;
                    state <= PREP ? PRE : RUN;
                    if (PREP) begin                      // chep toan hang tho, chua dao dau
                        p    <= {32'd0, a};
                        m    <= b;
                        sa_r <= sa;
                        sb_r <= sb;
                    end else if (funct3[2]) begin        // chia
                        p <= {32'd0, ua};
                        m <= ub;
                        neg_res <= (sa ^ sb) & (b != 32'd0);
                        neg_rem <= sa;
                    end else begin                       // nhan
                        p <= {32'd0, ub};
                        m <= ua;
                        neg_res <= sa ^ sb;
                        neg_rem <= 1'b0;
                    end
                end
                PRE: begin                               // chi duoc vao khi PREP = 1
                    if (op[2]) begin                     // chia
                        p <= {32'd0, ua_r};
                        m <= ub_r;
                        neg_res <= (sa_r ^ sb_r) & (m != 32'd0);
                        neg_rem <= sa_r;
                    end else begin                       // nhan
                        p <= {32'd0, ub_r};
                        m <= ua_r;
                        neg_res <= sa_r ^ sb_r;
                        neg_rem <= 1'b0;
                    end
                    state <= RUN;
                end
                RUN: begin
                    p <= p_next;
                    cnt <= cnt + 5'd1;
                    if (cnt == LAST) state <= FIN;
                end
                default: state <= IDLE;                  // FIN: lenh da hoan tat
            endcase
        end
    end

    wire [63:0] p_neg = ~p + 64'd1;
    always @* begin
        case (op)
            3'b000:  result = p[31:0];                                   // MUL
            3'b001,
            3'b010,
            3'b011:  result = neg_res ? p_neg[63:32] : p[63:32];         // MULH, MULHSU, MULHU
            3'b100:  result = neg_res ? (~p[31:0] + 32'd1) : p[31:0];    // DIV
            3'b101:  result = p[31:0];                                   // DIVU
            3'b110:  result = neg_rem ? (~p[63:32] + 32'd1) : p[63:32];  // REM
            default: result = p[63:32];                                  // REMU
        endcase
    end
endmodule
