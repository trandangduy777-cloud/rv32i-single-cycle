`timescale 1ns/1ps
// Testbench cho so vet voi Spike: chuong trinh dat o 0x8000_0000 (giong ban do bo nho mac dinh cua Spike),
// loi khoi dong o RESET_PC = 0x8000_0000, bo nho lenh va du lieu dung chung 256 KB (dia chi [17:2]).
// Moi lenh hoan tat in 1 dong:  pc=.. ins=.. rd=.. val=.. st=.. addr=.. data=.. strb=..
// Thanh ghi x1-x31 duoc dat 0 truoc khi chay nhu Spike. Ket thuc khi chuong trinh ghi vao TOHOST (0x8010_0000). Chon loi: -DSC (single-cycle), -DPIPE,
// -DPIPE_FULL, -DPIPE_FULL -DRVC (pipeline RV32IM co ENABLE_C = 1).
// Them -DCACHE (chi voi PIPE_FULL): loi noi qua rv32_icache + rv32_dcache + rv32_bus_arbiter toi bo nho chung co do tre
// ngau nhien 1..(+lat) chu ky moi tu (+seed). Vung cacheable 0x8000_0000-0x8003_FFFF; TOHOST di thang qua bus.
// Kich thuoc cache: -DICL/-DICW/-DDCL/-DDCW (so dong / so tu moi dong), mac dinh 16 x 4; bo dem ghi: -DDWB (mac dinh 4 muc);
// so duong cua ca 2 cache: -DCWY (mac dinh 1, anh xa truc tiep; tong so dong giu nguyen).
// Tham so: +prog=<file hex> [+lat=<do tre toi da>] [+seed=<so>]
module tb_cosim;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    localparam [31:0] BASE   = 32'h8000_0000;
    localparam [31:0] TOHOST = 32'h8010_0000;

    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata, imem_data;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we, dmem_re, dmem_fence, imem_ready, dmem_ready, icache_flush;

`ifdef PIPE_FULL
`ifdef RVC
    rv32im_pipeline #(.RESET_PC(BASE), .ENABLE_C(1)) dut (
`else
    rv32im_pipeline #(.RESET_PC(BASE)) dut (
`endif
`elsif PIPE
    rv32i_pipeline #(.RESET_PC(BASE)) dut (
`else
    rv32i_core #(.RESET_PC(BASE)) dut (
`endif
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_rdata(dmem_rdata)
`ifdef PIPE_FULL
        , .irq_timer(1'b0), .irq_soft(1'b0), .irq_ext(1'b0)
        , .imem_ready(imem_ready), .dmem_ready(dmem_ready), .dmem_re(dmem_re)
        , .icache_flush(icache_flush), .dmem_fence(dmem_fence)
`endif
    );

    reg [31:0] mem [0:65535];

`ifdef CACHE
`ifndef ICL
`define ICL 16
`endif
`ifndef ICW
`define ICW 4
`endif
`ifndef DCL
`define DCL 16
`endif
`ifndef DCW
`define DCW 4
`endif
`ifndef DWB
`define DWB 4
`endif
`ifndef CWY
`define CWY 1
`endif
    wire        ic_req, ic_ack, dc_req, dc_we, dc_ack, m_req, m_we;
    wire [31:0] ic_addr, dc_addr, dc_wdata, m_addr, m_wdata, ic_miss, dc_miss;
    wire [3:0]  dc_wstrb, m_wstrb;
    reg         m_ack = 1'b0;
    reg  [31:0] m_rdata;

    rv32_icache #(.LINES(`ICL), .WORDS(`ICW), .WAYS(`CWY)) u_ic (
        .clk(clk), .rst_n(rst_n), .addr(imem_addr), .data(imem_data), .ready(imem_ready), .flush(icache_flush),
        .m_req(ic_req), .m_addr(ic_addr), .m_ack(ic_ack), .m_rdata(m_rdata), .n_miss(ic_miss));
    rv32_dcache #(.LINES(`DCL), .WORDS(`DCW), .WAYS(`CWY), .WBUF(`DWB), .CMASK(32'hFFFC_0000), .CBASE(BASE)) u_dc (
        .clk(clk), .rst_n(rst_n), .addr(dmem_addr), .re(dmem_re), .we(dmem_we), .fence(dmem_fence), .wstrb(dmem_wstrb),
        .wdata(dmem_wdata), .rdata(dmem_rdata), .ready(dmem_ready),
        .m_req(dc_req), .m_we(dc_we), .m_addr(dc_addr), .m_wdata(dc_wdata), .m_wstrb(dc_wstrb),
        .m_ack(dc_ack), .m_rdata(m_rdata), .n_miss(dc_miss));
    rv32_bus_arbiter u_arb (
        .clk(clk), .rst_n(rst_n),
        .i_req(ic_req), .i_addr(ic_addr), .i_ack(ic_ack),
        .d_req(dc_req), .d_we(dc_we), .d_addr(dc_addr), .d_wdata(dc_wdata), .d_wstrb(dc_wstrb), .d_ack(dc_ack),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_ack(m_ack));

    // bo nho chung: moi yeu cau duoc tra loi sau 1..LAT chu ky (ngau nhien), m_ack keo dai 1 chu ky
    integer lat = 4, seed = 1, wait_cnt = 0, n_bus = 0, n_bus_cyc = 0;
    always @(posedge clk) begin
        m_ack <= 1'b0;
        if (rst_n && m_req) n_bus_cyc = n_bus_cyc + 1;
        if (rst_n && m_req && !m_ack) begin
            if (wait_cnt <= 0) begin
                m_ack   <= 1'b1;
                n_bus    = n_bus + 1;
                m_rdata <= mem[m_addr[17:2]];
                if (m_we && m_addr != TOHOST) begin
                    if (m_addr[31:18] != BASE[31:18]) begin
                        $display("ERROR: ghi ngoai vung nho: addr=%08x", m_addr); $finish;
                    end
                    if (m_wstrb[0]) mem[m_addr[17:2]][7:0]   <= m_wdata[7:0];
                    if (m_wstrb[1]) mem[m_addr[17:2]][15:8]  <= m_wdata[15:8];
                    if (m_wstrb[2]) mem[m_addr[17:2]][23:16] <= m_wdata[23:16];
                    if (m_wstrb[3]) mem[m_addr[17:2]][31:24] <= m_wdata[31:24];
                end
                wait_cnt = $urandom(seed) % lat;     // yeu cau sau: cho 0..lat-1 chu ky truoc khi ack
                seed = seed + 1;
            end else
                wait_cnt = wait_cnt - 1;
        end
    end
`else
    // bo nho to hop: doc lenh tai dia chi chia het cho 2 (lenh 32 bit co the vat qua ranh gioi tu, mo rong C)
    wire [15:0] iw = imem_addr[17:2];
    assign imem_data  = imem_addr[1] ? {mem[iw + 16'd1][15:0], mem[iw][31:16]} : mem[iw];
    assign dmem_rdata = mem[dmem_addr[17:2]];
    assign imem_ready = 1'b1;
    assign dmem_ready = 1'b1;

    always @(posedge clk) begin
        if (dmem_we && dmem_addr != TOHOST) begin
            if (dmem_addr[31:18] != BASE[31:18]) begin
                $display("ERROR: ghi ngoai vung nho: addr=%08x", dmem_addr); $finish;
            end
            if (dmem_wstrb[0]) mem[dmem_addr[17:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) mem[dmem_addr[17:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) mem[dmem_addr[17:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mem[dmem_addr[17:2]][31:24] <= dmem_wdata[31:24];
        end
    end
`endif

    integer    cyc = 0;
    always @(posedge clk) if (rst_n) cyc <= cyc + 1;

    reg        rd_w;
    reg [31:0] mask;
    integer    n = 0;
`ifdef SC
    // single-cycle: lay mau o canh len khi lenh hoan tat (lenh M mat nhieu chu ky)
    always @(posedge clk) begin
        if (rst_n && dut.retire) begin
            rd_w = dut.rd_we && (dut.rd != 5'd0);
            mask = {{8{dmem_wstrb[3]}}, {8{dmem_wstrb[2]}}, {8{dmem_wstrb[1]}}, {8{dmem_wstrb[0]}}};
            $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%08x strb=%x",
                     imem_addr, imem_data, rd_w ? dut.rd : 5'd0, rd_w ? dut.rd_val : 32'd0,
                     dmem_we, dmem_we ? dmem_addr : 32'd0, dmem_we ? (dmem_wdata & mask) : 32'd0,
                     dmem_we ? dmem_wstrb : 4'd0);
            n = n + 1;
            if (dmem_we && dmem_addr == TOHOST) begin
                $display("DONE cycles=%0d instr=%0d", cyc, n);
                $finish;
            end
        end
    end
`else
    // pipeline: tang WB (pipeline RV32IM: wb_commit, moi lenh dung 1 lan ke ca khi pipeline dong bang)
`ifdef PIPE_FULL
    wire commit = dut.wb_commit;
`else
    wire commit = dut.memwb_valid;
`endif

`ifdef CACHE
    // Bo dem ghi: store xong o MEM truoc khi toi bo nho. Mo hinh kien truc arch[] cap nhat khi store hoan tat (WB);
    // khi FENCE / FENCE.I hoan tat, moi store truoc no phai da toi bo nho (mem[] khop arch[] o moi dia chi).
    reg [31:0] arch [0:65535];
    integer    ai, n_fchk = 0;
    always @(posedge clk) begin
        if (rst_n && commit) begin
            if (dut.memwb_tst && dut.memwb_taddr != TOHOST) begin
                if (dut.memwb_tstrb[0]) arch[dut.memwb_taddr[17:2]][7:0]   = dut.memwb_tdata[7:0];
                if (dut.memwb_tstrb[1]) arch[dut.memwb_taddr[17:2]][15:8]  = dut.memwb_tdata[15:8];
                if (dut.memwb_tstrb[2]) arch[dut.memwb_taddr[17:2]][23:16] = dut.memwb_tdata[23:16];
                if (dut.memwb_tstrb[3]) arch[dut.memwb_taddr[17:2]][31:24] = dut.memwb_tdata[31:24];
            end
            if (dut.memwb_instr[6:0] == 7'b0001111 && dut.memwb_instr[14:13] == 2'b00) begin   // FENCE, FENCE.I
                for (ai = 0; ai < 65536; ai = ai + 1)
                    if (mem[ai] !== arch[ai]) begin
                        $display("ERROR: FENCE tai pc=%08x hoan tat nhung bo nho tai tu %0d = %08x, dung la %08x",
                                 dut.memwb_pc, ai, mem[ai], arch[ai]);
                        $finish;
                    end
                n_fchk = n_fchk + 1;
            end
        end
    end
`endif

    always @(posedge clk) begin
        if (rst_n && commit) begin
            rd_w = dut.memwb_rd_we && (dut.memwb_rd != 5'd0);
            $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%08x strb=%x",
                     dut.memwb_pc, dut.memwb_instr, rd_w ? dut.memwb_rd : 5'd0, rd_w ? dut.memwb_val : 32'd0,
                     dut.memwb_tst, dut.memwb_taddr, dut.memwb_tdata, dut.memwb_tstrb);
            n = n + 1;
            if (dut.memwb_tst && dut.memwb_taddr == TOHOST) begin
`ifdef CACHE
                $display("DONE cycles=%0d instr=%0d imiss=%0d dmiss=%0d bus=%0d buscyc=%0d wbfull=%0d fwd=%0d",
                         cyc, n, ic_miss, dc_miss, n_bus, n_bus_cyc, u_dc.n_wbfull, u_dc.n_fwd);
`else
                $display("DONE cycles=%0d instr=%0d", cyc, n);
`endif
                $finish;
            end
        end
    end
`endif

    reg [8*256-1:0] progfile;
    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 32'd0;
        // thanh ghi khong co reset trong RTL; Spike bat dau voi 0, nen dat 0 de vet so sanh duoc
        // (vd. ham luu thanh ghi s0/s1 chua dung len stack)
        for (i = 1; i < 32; i = i + 1) dut.regs[i] = 32'd0;
        if (!$value$plusargs("prog=%s", progfile)) begin $display("ERROR: thieu +prog="); $finish; end
`ifdef CACHE
        if (!$value$plusargs("lat=%d", lat)) lat = 4;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (lat < 1) lat = 1;
`endif
        $readmemh(progfile, mem);
`ifdef CACHE
        for (i = 0; i < 65536; i = i + 1) arch[i] = mem[i];
`endif
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        #50_000_000;
        $display("TIMEOUT sau %0d lenh", n);
        $finish;
    end
endmodule
