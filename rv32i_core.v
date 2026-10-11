// RV32I single-cycle core (tu viet)
// - Bo nho lenh/du lieu nam ngoai core (Harvard), doc lenh va doc du lieu la combinational
// - Ho tro: LUI AUIPC JAL JALR BEQ BNE BLT BGE BLTU BGEU
//           LB LH LW LBU LHU SB SH SW
//           ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI
//           ADD SUB SLL SLT SLTU XOR SRL SRA OR AND
// - FENCE/ECALL/EBREAK/CSR: coi nhu NOP (khong co trap)
module rv32i_core (
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

    wire is_lui    = (opcode == OP_LUI);
    wire is_auipc  = (opcode == OP_AUIPC);
    wire is_jal    = (opcode == OP_JAL);
    wire is_jalr   = (opcode == OP_JALR);
    wire is_branch = (opcode == OP_BRANCH);
    wire is_load   = (opcode == OP_LOAD);
    wire is_store  = (opcode == OP_STORE);
    wire is_imm    = (opcode == OP_IMM);
    wire is_reg    = (opcode == OP_REG);

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

    assign pc_next = is_jal                       ? jal_target    :
                     is_jalr                      ? jalr_target   :
                     (is_branch & take_branch)    ? branch_target :
                                                    pc_plus4;

    // ------------------------------------------------------------
    // Store
    // ------------------------------------------------------------
    assign dmem_we = is_store;
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
    assign dmem_wstrb = is_store ? st_strb : 4'b0000;

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
    wire        rd_we = is_lui | is_auipc | is_jal | is_jalr | is_load | is_imm | is_reg;
    reg  [31:0] rd_val;
    always @* begin
        if      (is_lui)           rd_val = imm_u;
        else if (is_auipc)         rd_val = pc + imm_u;
        else if (is_jal | is_jalr) rd_val = pc_plus4;
        else if (is_load)          rd_val = ld_data;
        else                       rd_val = alu_out;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 32'd0;
        end else begin
            pc <= pc_next;
            if (rd_we && rd != 5'd0)
                regs[rd] <= rd_val;
        end
    end

endmodule
