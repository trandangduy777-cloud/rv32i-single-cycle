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
    // bo du doan nhanh: -DBTBN=<muc> -DRASN=<muc> -DGHRB=<bit> (mac dinh theo rv32im_pipeline.v; 0 0 0 = ban cu);
    // bo nhan: -DMULLAT=<0 lap | 1 song song 1 chu ky | 2 song song 2 tang>
`ifndef BTBN
`define BTBN 16
`endif
`ifndef RASN
`define RASN 4
`endif
`ifndef GHRB
`define GHRB 0
`endif
`ifndef BTAG
`define BTAG 10
`endif
`ifndef MULLAT
`define MULLAT 2
`endif
`ifdef MA
    localparam MA_HW = 1;              // -DMA: load/store lech dia chi bang phan cung (Spike chay voi --misaligned)
`else
    localparam MA_HW = 0;
`endif
`ifdef RVC
    rv32im_pipeline #(.RESET_PC(BASE), .ENABLE_C(1), .MISALIGNED(MA_HW), .BTB_N(`BTBN), .RAS_N(`RASN), .GHR_BITS(`GHRB), .BTB_TAG(`BTAG), .MUL_LAT(`MULLAT)) dut (
`else
    rv32im_pipeline #(.RESET_PC(BASE), .MISALIGNED(MA_HW), .BTB_N(`BTBN), .RAS_N(`RASN), .GHR_BITS(`GHRB), .BTB_TAG(`BTAG), .MUL_LAT(`MULLAT)) dut (
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
    reg [63:0] t_d;
    reg [7:0]  t_s;
    reg [31:0] mask;
    integer    n = 0;

    // ---- CoreMark (coremark/port/core_portme.c): o danh dau thoi gian va vung dem ee_printf trong RAM ----
    // Store 1 / 2 vao MARK hoan tat: ghi lai chu ky va so lenh (bat dau / ket thuc phan do). Store vao vung CON: gom
    // tung byte, in ra mot lan khi ket thuc (khong chen vao giua cac dong vet). +quiet: khong in vet tung lenh.
    localparam [31:0] MARK = 32'h8003_F800, CON = 32'h8003_8000;
    reg  [7:0] con_buf [0:16383];
    integer    con_n = 0, mk_c1 = -1, mk_c2 = -1, mk_n1 = 0, mk_n2 = 0, ck;
    reg        quiet = 0;
    task tb_store(input [31:0] a, input [7:0] st, input [63:0] d);
        begin
            if (a == MARK && st[3:0] == 4'b1111) begin
                if (d[31:0] == 32'd1) begin mk_c1 = cyc; mk_n1 = n; end
                if (d[31:0] == 32'd2) begin mk_c2 = cyc; mk_n2 = n; end
            end
            if (a >= CON && a < CON + 32'd16384)
                for (ck = 0; ck < 8; ck = ck + 1)
                    if (st[ck] && con_n < 16384) begin con_buf[con_n] = d[8 * ck +: 8]; con_n = con_n + 1; end
        end
    endtask
    // phan tich chu ky trong phan do (pipeline RV32IM): lenh M chiem EX, load-use, dong bang cho bo nho, redirect
    integer    st_m = 0, st_lu = 0, st_frz = 0, st_rq = 0, st_idr = 0, st_ifw = 0;
`ifdef PIPE_FULL
    always @(posedge clk) if (rst_n && mk_c1 >= 0 && mk_c2 < 0) begin
        if (dut.frz) st_frz = st_frz + 1;
        else if (dut.ex_stall) st_m = st_m + 1;
        else if (dut.redirect_q) st_rq = st_rq + 1;
        else if (dut.stall) st_lu = st_lu + 1;
        else if (dut.id_redirect) st_idr = st_idr + 1;
        else if (!dut.imem_ready) st_ifw = st_ifw + 1;
    end
`endif
    task tb_finish_report;
        begin
            if (mk_c1 >= 0 && mk_c2 >= 0)
                $display("CMARK cycles=%0d instr=%0d mstall=%0d frz=%0d redir=%0d loaduse=%0d idredir=%0d ifwait=%0d",
                         mk_c2 - mk_c1, mk_n2 - mk_n1, st_m, st_frz, st_rq, st_lu, st_idr, st_ifw);
            if (con_n > 0) begin
                $display("CONSOLE_BEGIN");
                for (ck = 0; ck < con_n; ck = ck + 1) $write("%c", con_buf[ck]);
                $display("CONSOLE_END");
            end
        end
    endtask
`ifdef SC
    // single-cycle: lay mau o canh len khi lenh hoan tat (lenh M mat nhieu chu ky)
    always @(posedge clk) begin
        if (rst_n && dut.retire) begin
            rd_w = dut.rd_we && (dut.rd != 5'd0);
            mask = {{8{dmem_wstrb[3]}}, {8{dmem_wstrb[2]}}, {8{dmem_wstrb[1]}}, {8{dmem_wstrb[0]}}};
            if (!quiet)
            $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%08x strb=%x",
                     imem_addr, imem_data, rd_w ? dut.rd : 5'd0, rd_w ? dut.rd_val : 32'd0,
                     dmem_we, dmem_we ? dmem_addr : 32'd0, dmem_we ? (dmem_wdata & mask) : 32'd0,
                     dmem_we ? dmem_wstrb : 4'd0);
            if (dmem_we) tb_store(dmem_addr, {4'b0, dmem_wstrb}, {32'b0, dmem_wdata & mask});
            n = n + 1;
            if (dmem_we && dmem_addr == TOHOST) begin
                tb_finish_report;
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
    integer    ai, ab, n_fchk = 0;
    always @(posedge clk) begin
        if (rst_n && commit) begin
            if (dut.memwb_tst && dut.memwb_taddr != TOHOST) begin
                // store co the vat qua 2 tu (MISALIGNED = 1): wstrb 8 bit, du lieu 64 bit tinh tu tu chua dia chi
                for (ab = 0; ab < 8; ab = ab + 1)
                    if ((dut.memwb_tstrb >> ab) & 1)
                        arch[dut.memwb_taddr[17:2] + ab / 4][8 * (ab % 4) +: 8] = dut.memwb_tdata >> (8 * ab);
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

`ifdef PIPE_FULL
    // thong ke du doan nhanh: lenh that su chay xong o EX (khong dong bang, khong trap); lan ID sua/nhay som duoc ap;
    // lan IF nhay theo BTB duoc ap
    integer n_br = 0, n_brmiss = 0, n_jr = 0, n_jrmiss = 0, n_idr = 0, n_btbt = 0;
    always @(posedge clk) if (rst_n) begin
        if (dut.ex_upd && dut.idex_branch) begin n_br = n_br + 1; if (dut.mispredict) n_brmiss = n_brmiss + 1; end
        if (dut.ex_upd && dut.idex_jalr)   begin n_jr = n_jr + 1; if (dut.jalr_miss)  n_jrmiss = n_jrmiss + 1; end
        if (!dut.frz && !dut.redirect_q && dut.id_redirect && !dut.ex_stall) n_idr = n_idr + 1;
        if (!dut.frz && !dut.redirect_q && !(dut.id_redirect && !dut.ex_stall) && !dut.stall && !dut.ex_stall &&
            dut.imem_ready && dut.if_pred) n_btbt = n_btbt + 1;
    end
`endif

    always @(posedge clk) begin
        if (rst_n && commit) begin
            rd_w = dut.memwb_rd_we && (dut.memwb_rd != 5'd0);
            t_d = dut.memwb_tdata; t_s = dut.memwb_tstrb;   // store vat qua tu (MISALIGNED = 1): 64 bit, wstrb 8 bit
            if (dut.memwb_tst) tb_store(dut.memwb_taddr, t_s, t_d);
            if (quiet) ;
            else if (t_s[7:4] != 4'b0000)
                $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%016x strb=%02x",
                         dut.memwb_pc, dut.memwb_instr, rd_w ? dut.memwb_rd : 5'd0, rd_w ? dut.memwb_val : 32'd0,
                         dut.memwb_tst, dut.memwb_taddr, t_d, t_s);
            else
                $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%08x strb=%x",
                         dut.memwb_pc, dut.memwb_instr, rd_w ? dut.memwb_rd : 5'd0, rd_w ? dut.memwb_val : 32'd0,
                         dut.memwb_tst, dut.memwb_taddr, t_d[31:0], t_s[3:0]);
            n = n + 1;
            if (dut.memwb_tst && dut.memwb_taddr == TOHOST) begin
                tb_finish_report;
`ifdef PIPE_FULL
                $display("BPRED br=%0d brmiss=%0d jalr=%0d jalrmiss=%0d idredir=%0d btbtaken=%0d",
                         n_br, n_brmiss, n_jr, n_jrmiss, n_idr, n_btbt);
`endif
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
    integer         tmax;
    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 32'd0;
        // thanh ghi khong co reset trong RTL; Spike bat dau voi 0, nen dat 0 de vet so sanh duoc
        // (vd. ham luu thanh ghi s0/s1 chua dung len stack)
        for (i = 1; i < 32; i = i + 1) dut.regs[i] = 32'd0;
        if (!$value$plusargs("prog=%s", progfile)) begin $display("ERROR: thieu +prog="); $finish; end
        if ($test$plusargs("quiet")) quiet = 1;
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
        if (!$value$plusargs("tmax=%d", tmax)) tmax = 5_000_000;      // so chu ky toi da (+tmax=)
        repeat (tmax) @(posedge clk);
        $display("TIMEOUT sau %0d lenh", n);
        $finish;
    end
endmodule
