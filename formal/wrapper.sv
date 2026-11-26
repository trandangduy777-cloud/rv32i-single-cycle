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

	(* keep *) wire fv_wfi_wait;
	(* keep *) wire fv_m_valid, fv_m_store, fv_m_last;
	(* keep *) wire [31:0] fv_m_addr, fv_m_sval, fv_m_ld;
	(* keep *) wire [1:0] fv_m_size;
	(* keep *) `rvformal_rand_reg irq_timer;
	(* keep *) `rvformal_rand_reg irq_soft;
	(* keep *) `rvformal_rand_reg irq_ext;

`ifdef RV_FORMAL_NOIRQ
	always @* assume (!irq_timer && !irq_soft && !irq_ext);
`endif

	rv32im_pipeline #(
		.ENABLE_C   (1),
`ifdef RV_FORMAL_MISALIGNED
		.MISALIGNED (1),
`else
		.MISALIGNED (0),
`endif
		.PMP_N      (0),          // riscv-formal khong mo hinh PMP: muc khoa gay trap ma spec khong biet (PMP so vet voi Spike)
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
		.fv_wfi_wait (fv_wfi_wait),
		.fv_m_valid(fv_m_valid), .fv_m_store(fv_m_store), .fv_m_last(fv_m_last),
		.fv_m_addr(fv_m_addr), .fv_m_sval(fv_m_sval), .fv_m_ld(fv_m_ld), .fv_m_size(fv_m_size),
		`RVFI_CONN
	);


`ifdef RV_FORMAL_MISALIGNED
	// Monitor muc bus cho MISALIGNED = 1 (RVFI bao truy cap LOGIC nen khong thay duong du lieu bus): chon 1 byte B tuy y;
	// moi lan bus xong mot nhat (dmem_ready) cho lenh o MEM, doi chieu voi truy cap logic:
	//  - store: dmem_wstrb[B] != 0 dung khi B nam trong [addr, addr + kich thuoc) cua lenh, va byte B tren bus = byte tuong ung cua toan hang;
	//  - load : khi lan cuoi, byte tuong ung cua gia tri lenh nhan ve (ld_sh, da ghep 2 tu) = byte B ma bus da tra ve (lan nay hoac lan truoc).
	`rvformal_rand_const_reg [31:0] mon_b;
	reg [7:0] mon_cap = 8'd0;
	wire [31:0] mon_d  = mon_b - fv_m_addr;
	wire [31:0] mon_sz = 32'd1 << fv_m_size;
	wire        mon_cov = mon_d < mon_sz;
	wire        mon_beat = fv_m_valid & dmem_ready & ~reset;
	wire        mon_word = dmem_addr[31:2] == mon_b[31:2];
	wire [7:0]  mon_bus_rd = dmem_rdata >> {mon_b[1:0], 3'b000};
	always @(posedge clock) if (mon_beat && !fv_m_store && mon_word) mon_cap <= mon_bus_rd;
	always @* if (!reset) cover (mon_beat && !fv_m_store && fv_m_last && mon_cov && mon_word && fv_m_addr[1:0] == 2'b01 && fv_m_size == 2'b10);
	always @* begin
		if (mon_beat && fv_m_store && mon_word) begin
			assert (dmem_wstrb[mon_b[1:0]] == mon_cov);
			if (mon_cov) assert (((dmem_wdata >> {mon_b[1:0], 3'b000}) & 32'hFF) == ((fv_m_sval >> {mon_d[1:0], 3'b000}) & 32'hFF));
		end
		if (mon_beat && !fv_m_store && fv_m_last && mon_cov)
			assert (((fv_m_ld >> {mon_d[1:0], 3'b000}) & 32'hFF) == {24'd0, (mon_word ? mon_bus_rd : mon_cap)});
	end
`endif
`ifdef RISCV_FORMAL_FAIRNESS
	// cong bang cho liveness: bo nho khong cho vo han (toi da 3 chu ky lien tiep chua san sang), khong ke WFI
	// (WFI cho ngat, ma ngat o day la dau vao tu do nen khong co gi bao dam no den)
	reg [1:0] iwait = 0, dwait = 0;
	always @(posedge clock) begin
		iwait <= imem_ready ? 2'd0 : iwait + 2'd1;
		dwait <= (dmem_ready | ~(dmem_we | dmem_re | dmem_fence)) ? 2'd0 : dwait + 2'd1;
		assume (iwait != 2'd3 || imem_ready);
		assume (dwait != 2'd3 || dmem_ready);
`ifndef RV_FORMAL_WFI_FAIR
		assume (imem_data != 32'h1050_0073);
`endif
	end
`ifdef RV_FORMAL_WFI_FAIR
	// Mo hinh ngat cong bang cho WFI: ngat DA BAT (mie & mip) den trong 3 chu ky ke tu khi WFI bat dau cho. Neu mie = 0
	// thi khong co ngat nao co the lam WFI het cho (dung dac ta: WFI duoc phep cho vo han), nen cac vet do bi loai: day la
	// chung minh CO DIEU KIEN ("neu co ngat bat thi WFI hoan tat"), khong phai "WFI luon hoan tat".
	reg [1:0] wwait = 0;
	always @(posedge clock) begin
		wwait <= fv_wfi_wait ? wwait + 2'd1 : 2'd0;
		assume (wwait != 2'd3 || !fv_wfi_wait);
	end
`endif
`endif
endmodule
