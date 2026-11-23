`timescale 1ns/1ps
// Testbench in vet cho pipeline: moi lenh o tang WB in 1 dong cung dinh dang voi rv32i_iss.py
// Tham so dong lenh: +prog=<file hex lenh>  [+dmem=<file hex du lieu ban dau>]
// Ket thuc khi chuong trinh ghi vao dia chi tohost (0x1000)
// -DCACHE (voi PIPE_FULL): bo nho lenh qua rv32_icache, bo nho du lieu qua rv32_dcache (vung 0x000-0xFFF cacheable,
// TOHOST di thang), moi bo nho co bus rieng tra loi sau 1..(+lat) chu ky ngau nhien (+seed). Cache 2 dong x 2 tu de
// truot lien tuc: lenh CSR, trap, MRET... cua chuong trinh ngau nhien roi vao luc pipeline dang dong bang.
module tb_trace_pipe;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata, imem_data;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we, dmem_re, dmem_fence, imem_ready, dmem_ready;

`ifndef MULLAT
`define MULLAT 2   // bo nhan: 0 lap, 1 song song 1 chu ky, 2 song song 2 tang (--mul-lat)
`endif
`ifdef PIPE_FULL
`ifdef BPSTRESS   // bo du doan nho, tag 1 bit: BTB trung nham lien tuc, RAS tran, gshare 2 bit (kiem cac duong sua o ID/EX)
`ifdef MA
    rv32im_pipeline #(.MISALIGNED(1), .BTB_N(4), .BTB_TAG(1), .RAS_N(2), .GHR_BITS(2), .MUL_LAT(`MULLAT)) dut (
`else
    rv32im_pipeline #(.BTB_N(4), .BTB_TAG(1), .RAS_N(2), .GHR_BITS(2), .MUL_LAT(`MULLAT)) dut (
`endif
`else
`ifdef MA
    rv32im_pipeline #(.MISALIGNED(1), .MUL_LAT(`MULLAT)) dut (    // -DMA: load/store lech dia chi bang phan cung
`else
    rv32im_pipeline #(.MUL_LAT(`MULLAT)) dut (     // RV32IM + CSR + trap
`endif
`endif
`else
    rv32i_pipeline dut (             // RV32I thuan
`endif
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_rdata(dmem_rdata)
`ifdef PIPE_FULL
`ifndef NO_IRQ_PORTS
        , .irq_timer(1'b0), .irq_soft(1'b0), .irq_ext(1'b0)     // ngat duoc kiem tra rieng trong tb_irq.v
        , .imem_ready(imem_ready), .dmem_ready(dmem_ready), .dmem_re(dmem_re), .dmem_fence(dmem_fence)
`endif
`endif
    );

    reg [31:0] imem [0:1023];
    reg [31:0] dmem [0:1023];
    localparam TOHOST = 32'h0000_1000;

`ifdef CACHE
`ifndef CWY
`define CWY 1
`endif
    wire        ic_req, dc_req, dc_we;
    wire [31:0] ic_addr, dc_addr, dc_wdata, ic_miss, dc_miss;
    wire [3:0]  dc_wstrb;
    reg         ic_ack = 1'b0, dc_ack = 1'b0;
    reg  [31:0] ic_rdata, dc_rdata;
    rv32_icache #(.LINES(2), .WORDS(2), .WAYS(`CWY)) u_ic (
        .clk(clk), .rst_n(rst_n), .addr(imem_addr), .data(imem_data), .ready(imem_ready), .flush(1'b0),
        .m_req(ic_req), .m_addr(ic_addr), .m_ack(ic_ack), .m_rdata(ic_rdata), .n_miss(ic_miss));
    rv32_dcache #(.LINES(2), .WORDS(2), .WAYS(`CWY), .CMASK(32'hFFFF_F000), .CBASE(32'h0000_0000)) u_dc (
        .clk(clk), .rst_n(rst_n), .addr(dmem_addr), .re(dmem_re), .we(dmem_we), .fence(dmem_fence), .wstrb(dmem_wstrb),
        .wdata(dmem_wdata), .rdata(dmem_rdata), .ready(dmem_ready),
        .m_req(dc_req), .m_we(dc_we), .m_addr(dc_addr), .m_wdata(dc_wdata), .m_wstrb(dc_wstrb),
        .m_ack(dc_ack), .m_rdata(dc_rdata), .n_miss(dc_miss));

    integer lat = 4, seed = 1, iwait = 0, dwait = 0;
    always @(posedge clk) begin
        ic_ack <= 1'b0;
        dc_ack <= 1'b0;
        if (rst_n && ic_req && !ic_ack) begin
            if (iwait <= 0) begin
                ic_ack <= 1'b1; ic_rdata <= imem[ic_addr[11:2]];
                iwait = $urandom(seed) % lat; seed = seed + 1;
            end else iwait = iwait - 1;
        end
        if (rst_n && dc_req && !dc_ack) begin
            if (dwait <= 0) begin
                dc_ack <= 1'b1; dc_rdata <= dmem[dc_addr[11:2]];
                if (dc_we && dc_addr != TOHOST) begin
                    if (dc_wstrb[0]) dmem[dc_addr[11:2]][7:0]   <= dc_wdata[7:0];
                    if (dc_wstrb[1]) dmem[dc_addr[11:2]][15:8]  <= dc_wdata[15:8];
                    if (dc_wstrb[2]) dmem[dc_addr[11:2]][23:16] <= dc_wdata[23:16];
                    if (dc_wstrb[3]) dmem[dc_addr[11:2]][31:24] <= dc_wdata[31:24];
                end
                dwait = $urandom(seed) % lat; seed = seed + 1;
            end else dwait = dwait - 1;
        end
    end
`else
    assign imem_data  = imem[imem_addr[11:2]];
    assign dmem_rdata = dmem[dmem_addr[11:2]];
    assign imem_ready = 1'b1;
    assign dmem_ready = 1'b1;

    always @(posedge clk) begin
        if (dmem_we && dmem_addr != TOHOST) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[11:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[11:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[11:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[11:2]][31:24] <= dmem_wdata[31:24];
        end
    end
`endif


`ifdef CACHE
    // Bo dem ghi: store xong o MEM truoc khi toi bo nho. Mo hinh kien truc arch[] cap nhat khi store hoan tat (WB);
    // khi FENCE / FENCE.I hoan tat, moi store truoc no phai da toi bo nho (dmem[] khop arch[] o moi dia chi).
    reg [31:0] arch [0:1023];
    integer    ai, ab, n_fchk = 0;
    always @(posedge clk) begin
        if (rst_n && dut.wb_commit) begin
            if (dut.memwb_tst && dut.memwb_taddr != TOHOST) begin
                // store co the vat qua 2 tu (MISALIGNED = 1): wstrb 8 bit, du lieu 64 bit tinh tu tu chua dia chi
                for (ab = 0; ab < 8; ab = ab + 1)
                    if ((dut.memwb_tstrb >> ab) & 1)
                        arch[dut.memwb_taddr[11:2] + ab / 4][8 * (ab % 4) +: 8] = dut.memwb_tdata >> (8 * ab);
            end
            if (dut.memwb_instr[6:0] == 7'b0001111 && dut.memwb_instr[14:13] == 2'b00) begin   // FENCE, FENCE.I
                for (ai = 0; ai < 1024; ai = ai + 1)
                    if (dmem[ai] !== arch[ai]) begin
                        $display("ERROR: FENCE tai pc=%08x hoan tat nhung bo nho tai tu %0d = %08x, dung la %08x",
                                 dut.memwb_pc, ai, dmem[ai], arch[ai]);
                        $finish;
                    end
                n_fchk = n_fchk + 1;
            end
        end
    end
`endif

    reg rd_w;
    reg [63:0] t_d;
    reg [7:0]  t_s;
    // Tang commit (WB): in 1 dong cho moi lenh hoan tat, cung dinh dang voi ISS.
    // Lay mau o canh len: luc nay cac thanh ghi pipeline chua cap nhat (NBA), nen doc dung lenh dang o WB.
    always @(posedge clk) begin
`ifdef PIPE_FULL
`ifndef NO_IRQ_PORTS
        if (rst_n && dut.wb_commit) begin
`else
        if (rst_n && dut.memwb_valid) begin
`endif
`else
        if (rst_n && dut.memwb_valid) begin
`endif
            rd_w = dut.memwb_rd_we && (dut.memwb_rd != 5'd0);
            t_d = dut.memwb_tdata; t_s = dut.memwb_tstrb;   // store vat qua tu: in 64 bit / wstrb 8 bit
            if (t_s[7:4] != 4'b0000)
                $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%016x strb=%02x",
                     dut.memwb_pc, dut.memwb_instr,
                     rd_w ? dut.memwb_rd : 5'd0, rd_w ? dut.memwb_val : 32'd0,
                     dut.memwb_tst, dut.memwb_taddr, t_d, t_s);
            else
                $display("pc=%08x ins=%08x rd=%0d val=%08x st=%0d addr=%08x data=%08x strb=%x",
                     dut.memwb_pc, dut.memwb_instr,
                     rd_w ? dut.memwb_rd : 5'd0, rd_w ? dut.memwb_val : 32'd0,
                     dut.memwb_tst, dut.memwb_taddr, t_d[31:0], t_s[3:0]);
            if (dut.memwb_tst && dut.memwb_taddr == TOHOST) $finish;
        end
    end

    reg [8*256-1:0] progfile, dmemfile;
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) begin imem[i] = 32'h00000013; dmem[i] = 32'd0; end
        if (!$value$plusargs("prog=%s", progfile)) progfile = "prog.hex";
        $readmemh(progfile, imem);
        if ($value$plusargs("dmem=%s", dmemfile)) $readmemh(dmemfile, dmem);
`ifdef CACHE
        for (i = 0; i < 1024; i = i + 1) arch[i] = dmem[i];
`endif
`ifdef CACHE
        if (!$value$plusargs("lat=%d", lat)) lat = 4;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
`endif
        repeat (3) @(posedge clk);
        @(negedge clk);          // nha reset o canh xuong de khong dua voi canh len
        rst_n = 1;
        #2000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
