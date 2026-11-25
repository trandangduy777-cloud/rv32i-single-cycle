// Check tu viet (khong co trong riscv-formal): trang thai THAT cua mepc / mcause / mtval / mstatus sau trap va MRET.
// csrw/csrc_any khong kiem duoc cac CSR nay vi phan cung tu ghi chung (trap, MRET); check nay doc lai chung bang CSR read
// ngay sau su kien va doi chieu voi dac ta RISC-V (M-mode):
//   TC_MEPC     lenh E (ECALL / EBREAK / C.EBREAK) tai pc co trap; lenh ke tiep doc mepc == pc & ~1
//   TC_MCAUSE   ... doc mcause == 11 (ECALL) hoac 3 (EBREAK, C.EBREAK)
//   TC_MTVAL    ... doc mtval == 0 (ECALL) hoac pc (EBREAK, C.EBREAK; RTL dat mtval = pc cho breakpoint)
//   TC_MSTATUS  A = doc mstatus, E = trap, R = doc mstatus: R.MIE = 0 va R.MPIE = A.MIE
//   TC_MRET     A = doc mstatus, M = MRET, R = doc mstatus: R.MIE = A.MPIE va R.MPIE = 1
// Cac lenh lien tiep theo thu tu retire (order, order + 1, order + 2); khong cho phep ngat xen vao (intr = 0).
module rvfi_trapcsr_check (
	input clock, reset, check,
	`RVFI_INPUTS
);
	`RVFI_CHANNEL(rvfi, `RISCV_FORMAL_CHANNEL_IDX)

	`rvformal_rand_const_reg [63:0] k;       // thu tu cua lenh dau tien trong chuoi

	// lenh dang xet dung la CSR read (csrrs rd, csr, x0) cua CSR cho truoc
	function csr_read(input [31:0] insn, input [11:0] addr);
		csr_read = insn[6:0] == 7'b1110011 && insn[14:12] == 3'b010 && insn[19:15] == 5'd0 && insn[11:7] != 5'd0 && insn[31:20] == addr;
	endfunction
	function is_ecall(input [31:0] insn);  is_ecall = insn == 32'h0000_0073; endfunction
	function is_brk(input [31:0] insn);    is_brk = insn == 32'h0010_0073 || insn == 32'h0000_9002; endfunction
	function is_mret(input [31:0] insn);   is_mret = insn == 32'h3020_0073; endfunction

	reg        s0_ok = 0, s1_ok = 0;
	reg [31:0] s0_rs1;
	reg [31:0] s0_insn, s0_pc, s0_rd, s1_insn, s1_pc, s1_rd;
	reg        s0_trap, s1_trap, s0_intr, s1_intr;

	always @(posedge clock) begin
		if (reset) begin s0_ok <= 0; s1_ok <= 0; end
		else if (!check && rvfi.valid) begin
			if (rvfi.order == k)     begin s0_ok <= 1; s0_insn <= rvfi.insn[31:0]; s0_rs1 <= rvfi.rs1_rdata; s0_pc <= rvfi.pc_rdata; s0_rd <= rvfi.rd_wdata; s0_trap <= rvfi.trap; s0_intr <= rvfi.intr; end
			if (rvfi.order == k + 1) begin s1_ok <= 1; s1_insn <= rvfi.insn[31:0]; s1_pc <= rvfi.pc_rdata; s1_rd <= rvfi.rd_wdata; s1_trap <= rvfi.trap; s1_intr <= rvfi.intr; end
		end
	end

`ifdef TC_MSTATUS
	`define TC_THREE
`endif
`ifdef TC_MRET
	`define TC_THREE
`endif

	// E: lenh gay trap; R: lenh doc CSR ngay sau do
// loai lenh gay trap: mac dinh ECALL / EBREAK / C.EBREAK; TC_ILL: lenh khong hop le; TC_LD / TC_ST: load / store lech dia chi
wire [31:0] ea_ld = s0_rs1 + {{20{s0_insn[31]}}, s0_insn[31:20]};
wire [31:0] ea_st = s0_rs1 + {{20{s0_insn[31]}}, s0_insn[31:25], s0_insn[11:7]};
`ifdef TC_ILL
`define TC_CLASS (s0_insn == 32'hFFFF_FFFF)
`define TC_CAUSE 32'd2
`define TC_TVAL  s0_insn
`elsif TC_LD
`define TC_CLASS (s0_insn[6:0] == 7'b0000011 && s0_insn[14:12] == 3'b010 && ea_ld[1:0] != 2'b00)
`define TC_CAUSE 32'd4
`define TC_TVAL  ea_ld
`elsif TC_ST
`define TC_CLASS (s0_insn[6:0] == 7'b0100011 && s0_insn[14:12] == 3'b010 && ea_st[1:0] != 2'b00)
`define TC_CAUSE 32'd6
`define TC_TVAL  ea_st
`else
`define TC_CLASS (is_ecall(s0_insn) || is_brk(s0_insn))
`define TC_CAUSE (is_ecall(s0_insn) ? 32'd11 : 32'd3)
`define TC_TVAL  (is_ecall(s0_insn) ? 32'd0 : s0_pc)
`endif

`ifdef TC_THREE
	wire [31:0] e_insn = s1_insn;  wire [31:0] e_pc = s1_pc;
`else
	wire [31:0] e_insn = s0_insn;  wire [31:0] e_pc = s0_pc;
`endif

	always @* begin
		if (!reset && check) begin
			assume (rvfi.valid && !rvfi.intr && !rvfi.trap);
`ifdef TC_THREE
			assume (rvfi.order == k + 2 && s0_ok && s1_ok && !s0_trap && !s0_intr && !s1_intr);
			assume (csr_read(s0_insn, 12'h300));
`else
			assume (rvfi.order == k + 1 && s0_ok && !s0_intr);
			assume (s0_trap && `TC_CLASS);
`endif
`ifdef TC_MEPC
			assume (csr_read(rvfi.insn[31:0], 12'h341));
			assert (rvfi.rd_wdata == {s0_pc[31:1], 1'b0});
`endif
`ifdef TC_MCAUSE
			assume (csr_read(rvfi.insn[31:0], 12'h342));
			assert (rvfi.rd_wdata == `TC_CAUSE);
`endif
`ifdef TC_MTVAL
			assume (csr_read(rvfi.insn[31:0], 12'h343));
			assert (rvfi.rd_wdata == `TC_TVAL);
`endif
`ifdef TC_MSTATUS
			assume (s1_trap && (is_ecall(s1_insn) || is_brk(s1_insn)));
			assume (csr_read(rvfi.insn[31:0], 12'h300));
			assert (rvfi.rd_wdata[3] == 1'b0);
			assert (rvfi.rd_wdata[7] == s0_rd[3]);
`endif
`ifdef TC_MRET
			assume (!s1_trap && is_mret(s1_insn));
			assume (csr_read(rvfi.insn[31:0], 12'h300));
			assert (rvfi.rd_wdata[3] == s0_rd[7]);
			assert (rvfi.rd_wdata[7] == 1'b1);
`endif
		end
	end
endmodule
