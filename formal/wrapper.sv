// Wrapper riscv-formal cho pipeline RV32IMC (rv32im_pipeline.v): noi bo nho lenh / du lieu "tu do" (moi chu ky nhan
// gia tri bat ky), ready tu do kem rang buoc cong bang, va cong RVFI cua loi ra ngoai.
// Mo phong bo nho bat ky: lenh, du lieu load va ready deu la dau vao tu do; kiem tra theo tung lenh hoan tat (RVFI)
// nen khong can mo hinh bo nho (riscv-formal dung chinh rvfi_mem_rdata de kiem load, va kiem rs/rd bang kiem tra reg).
module rvfi_wrapper (
	input         clock,
	input         reset,
	`RVFI_OUTPUTS
);
	(* keep *) wire [31:0] imem_addr;
	(* keep *) `rvformal_rand_reg [31:0] imem_data;
	(* keep *) `rvformal_rand_reg        imem_ready;

	(* keep *) wire [31:0] dmem_addr;
	(* keep *) wire [31:0] dmem_wdata;
	(* keep *) wire [3:0]  dmem_wstrb;
	(* keep *) wire        dmem_we, dmem_re, dmem_fence, icache_flush;
	(* keep *) `rvformal_rand_reg [31:0] dmem_rdata;
	(* keep *) `rvformal_rand_reg        dmem_ready;

	(* keep *) `rvformal_rand_reg irq_timer;
	(* keep *) `rvformal_rand_reg irq_soft;
	(* keep *) `rvformal_rand_reg irq_ext;

`ifdef RV_FORMAL_NOIRQ
	always @* assume (!irq_timer && !irq_soft && !irq_ext);
`endif

	rv32im_pipeline #(
		.ENABLE_C   (1),
		.MISALIGNED (0),
`ifdef RV_FORMAL_SIMPLE_BP
		.BTB_N(0), .RAS_N(0),
`endif
		.MUL_LAT    (`RV_FORMAL_MUL_LAT)
	) uut (
		.clk         (clock),
		.rst_n       (!reset),
		.imem_addr   (imem_addr),
		.imem_data   (imem_data),
		.imem_ready  (imem_ready),
		.dmem_addr   (dmem_addr),
		.dmem_wdata  (dmem_wdata),
		.dmem_wstrb  (dmem_wstrb),
		.dmem_we     (dmem_we),
		.dmem_re     (dmem_re),
		.dmem_fence  (dmem_fence),
		.icache_flush(icache_flush),
		.dmem_rdata  (dmem_rdata),
		.dmem_ready  (dmem_ready),
		.irq_timer   (irq_timer),
		.irq_soft    (irq_soft),
		.irq_ext     (irq_ext),
		`RVFI_CONN
	);

`ifdef RISCV_FORMAL_FAIRNESS
	// cong bang cho liveness: bo nho khong cho vo han (toi da 3 chu ky lien tiep chua san sang), khong ke WFI
	// (WFI cho ngat, ma ngat o day la dau vao tu do nen khong co gi bao dam no den)
	reg [1:0] iwait = 0, dwait = 0;
	always @(posedge clock) begin
		iwait <= imem_ready ? 2'd0 : iwait + 2'd1;
		dwait <= (dmem_ready | ~(dmem_we | dmem_re | dmem_fence)) ? 2'd0 : dwait + 2'd1;
		assume (iwait != 2'd3 || imem_ready);
		assume (dwait != 2'd3 || dmem_ready);
		assume (imem_data != 32'h1050_0073);
	end
`endif
endmodule
