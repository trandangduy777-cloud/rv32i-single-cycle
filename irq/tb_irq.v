`timescale 1ns/1ps
// Testbench ngat va WFI cho rv32im_pipeline: loi + rv32_mtimer (0x0200_0000, co msip) + nguon ngat ngoai gia lap.
// Chay: iverilog -g2012 -o irq irq/tb_irq.v rv32im_pipeline.v rv32i_core.v rv32_mtimer.v && vvp irq +prog=irq/irq_test.hex
// irq_ext duoc bat o chu ky 400, 1500, 2600 (hoac khi chuong trinh ghi vao 0x0300_0004) va giu cho toi khi
// chuong trinh ghi vao 0x0300_0000.
// Ngoai ket qua tu kiem cua chuong trinh, testbench tu dem so lan loi nhan ngat (dut.irq_take) va so sanh voi so dem
// cua phan mem, dem so lan ghi vao vung 0x200-0x21F (vong lap chinh ghi dung NITER lan: lenh store bi ngat
// khong duoc ghi), va do do tre tu luc irq_ext bat toi luc loi nhan ngat.
module tb_irq;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    wire [31:0] imem_addr, dmem_addr, dmem_wdata, imem_data;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;
    wire [31:0] dmem_rdata;
    wire        irq_timer, irq_soft;
    reg         irq_ext = 1'b0;

    rv32im_pipeline dut (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_wstrb(dmem_wstrb), .dmem_we(dmem_we),
        .dmem_rdata(dmem_rdata),
        .irq_timer(irq_timer), .irq_soft(irq_soft), .irq_ext(irq_ext),
        .imem_ready(1'b1), .dmem_ready(1'b1), .dmem_re()
    );

    // ---- bo nho ----
    reg [31:0] imem [0:1023];
    reg [31:0] dmem [0:1023];
    assign imem_data = imem[imem_addr[11:2]];

    localparam TOHOST = 32'h0000_1000;
    wire sel_tmr = (dmem_addr[31:24] == 8'h02);
    wire sel_ack = (dmem_addr[31:24] == 8'h03);
    wire sel_mem = (dmem_addr[31:12] == 20'd0);

    wire [31:0] tmr_rdata;
    rv32_mtimer #(.PRESCALE(1)) u_tmr (
        .clk(clk), .rst_n(rst_n),
        .sel(sel_tmr), .addr(dmem_addr[4:2]), .we(dmem_we), .wstrb(dmem_wstrb), .wdata(dmem_wdata),
        .rdata(tmr_rdata), .irq(irq_timer), .msip(irq_soft)
    );
    assign dmem_rdata = sel_tmr ? tmr_rdata : dmem[dmem_addr[11:2]];

    always @(posedge clk) begin
        if (dmem_we && sel_mem) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[11:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[11:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[11:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[11:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    // ---- nguon ngat ngoai ----
    integer cycles = 0;
    always @(posedge clk) if (rst_n) cycles <= cycles + 1;

    integer ext_raised = 0, ext_start = 0, lat, lat_max = 0;
    reg     ext_sched = 1'b0;            // ngat ngoai dang cho do testbench phat theo lich (de do do tre)
    always @(posedge clk) begin
        if (rst_n && dmem_we && sel_ack && !dmem_addr[2]) irq_ext <= 1'b0;
        else if (rst_n && !irq_ext && ((dmem_we && sel_ack && dmem_addr[2]) ||
                                       cycles == 400 || cycles == 1500 || cycles == 2600)) begin
            irq_ext    <= 1'b1;
            ext_raised <= ext_raised + 1;
            ext_start  <= cycles;
            ext_sched  <= !(dmem_we && sel_ack);
        end
    end

    // ---- so lan ghi cua vong lap chinh ----
    localparam NITER = 300;
    integer loop_st = 0;
    always @(posedge clk) if (rst_n && dmem_we && dmem_addr[31:5] == (32'h200 >> 5)) loop_st = loop_st + 1;

    // ---- dem ngat loi da nhan ----
    integer hw_tmr = 0, hw_ext = 0, hw_soft = 0, n_pos = 0;
    reg     hit [0:1023];                    // lenh nao da tung bi ngat (o EX khi loi nhan ngat)
    always @(posedge clk) begin
        if (rst_n && dut.irq_take) begin
            if (!hit[dut.idex_pc[11:2]]) begin hit[dut.idex_pc[11:2]] = 1'b1; n_pos = n_pos + 1; end
            if (dut.trap_cause == 32'h8000_000B) begin
                hw_ext = hw_ext + 1;
                lat = cycles - ext_start;
                if (ext_sched && lat > lat_max) lat_max = lat;
            end else if (dut.trap_cause == 32'h8000_0007) hw_tmr = hw_tmr + 1;
            else if (dut.trap_cause == 32'h8000_0003) hw_soft = hw_soft + 1;
            else begin $display("[IRQ] FAIL: mcause la 0x%08x", dut.trap_cause); $finish; end
        end
    end

    // ---- so chu ky loi dung o WFI ----
    integer wfi_cyc = 0;
    always @(posedge clk) if (rst_n && dut.wfi_wait) wfi_cyc = wfi_cyc + 1;

    // ---- ket qua ----
    reg [8*256-1:0] progfile;
    integer i;
    always @(posedge clk) begin
        if (rst_n && dmem_we && dmem_addr == TOHOST) begin
            if (dmem_wdata != 32'd1)
                $display("[IRQ] FAIL: chuong trinh bao loi %0d (ngat timer %0d, ngoai %0d, phan mem %0d)",
                         dmem_wdata & 32'h3FF, dmem[32'h300 >> 2], dmem[32'h304 >> 2], dmem[32'h308 >> 2]);
            else if (hw_tmr != dmem[32'h300 >> 2] || hw_ext != dmem[32'h304 >> 2] || hw_soft != dmem[32'h308 >> 2] ||
                     hw_ext != ext_raised)
                $display("[IRQ] FAIL: loi nhan %0d timer / %0d ngoai / %0d phan mem, phan mem dem %0d / %0d / %0d, testbench phat %0d ngoai",
                         hw_tmr, hw_ext, hw_soft, dmem[32'h300 >> 2], dmem[32'h304 >> 2], dmem[32'h308 >> 2], ext_raised);
            else if (loop_st != NITER)
                $display("[IRQ] FAIL: vong lap chinh ghi bo nho %0d lan, dung ra %0d", loop_st, NITER);
            else if (wfi_cyc < 400)
                $display("[IRQ] FAIL: loi chi dung o WFI %0d chu ky (hai lenh WFI phai cho khoang 300 va 200 chu ky)", wfi_cyc);
            else
                $display("[IRQ] PASS sau %0d chu ky: %0d ngat timer, %0d ngat ngoai, %0d ngat phan mem, ngat roi vao %0d lenh khac nhau, tre ngat ngoai lon nhat %0d chu ky, dung o WFI %0d chu ky",
                         cycles, hw_tmr, hw_ext, hw_soft, n_pos, lat_max, wfi_cyc);
            $finish;
        end
    end

    initial begin
        if (!$value$plusargs("prog=%s", progfile)) progfile = "irq/irq_test.hex";
        for (i = 0; i < 1024; i = i + 1) begin imem[i] = 32'h0000_0013; dmem[i] = 32'd0; hit[i] = 1'b0; end
        $readmemh(progfile, imem);
        @(negedge clk); @(negedge clk);
        rst_n = 1;                              // nha reset o canh xuong
        #1000000;
        $display("[IRQ] FAIL: het thoi gian (%0d chu ky)", cycles);
        $finish;
    end
endmodule
