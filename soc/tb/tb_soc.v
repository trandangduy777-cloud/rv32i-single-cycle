`timescale 1ns/1ps
// Testbench SoC: nap ROM tu hex (+rom=), giai ma UART TX o muc bit (kiem do dai tung bit dung bang chu ky quy dinh, bit start/stop, khong nhieu),
// so chuoi nhan duoc voi file mong doi (+exp=), kiem ma thoat (+code=, mac dinh 0) va thoi gian toi da (+max=, mac dinh 2.000.000 chu ky).
// +scn=N chon kich ban kich thich ben ngoai (theo dau nhac trong luong TX): 0 khong co, 1 UART RX, 2 GPIO, 3 UART RX + ngat, 4 ngat ngoai PLIC, 5 FreeRTOS (gui ky tu UART).
// Trong file +exp ky tu '#' khop mot day chu so thap phan bat ky (cho cac so do). +trap=<hex> +wake=<hex>: dia chi bo xu ly trap va ham mark_wake cua FreeRTOS, de do tre ngat.
// Chay: iverilog -g2012 -o x soc/tb/tb_soc.v soc/soc_*.v rv32im_pipeline.v rv32i_core.v rv32c_decompress.v rv32_mtimer.v && vvp x +rom=soc/sw/build/hello.hex +exp=soc/sw/hello.exp
module tb_soc;
    parameter DIV = 16;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         uart_rx = 1'b1;
    wire        uart_tx;
    reg  [15:0] ext_in = 16'd0;
    wire [15:0] gpio_out, gpio_oe;
    wire [15:0] pad = (gpio_oe & gpio_out) | (~gpio_oe & ext_in);
    wire        exit_valid;
    wire [31:0] exit_code;

    reg [3:0] ext_irq = 4'd0;
`ifdef SUCFG                    // cau hinh Linux-capable: S / U + MMU Sv32, CLINT bo cuc chuan, PLIC co context S (loi bien dich voi -DSEIP_PIN)
    localparam SUP = 1;
`else
    localparam SUP = 0;
`endif
`ifdef AXI
    soc_axi_top #(.UART_DIV(DIV), .MTIME_PRESC(1), .SU(SUP), .MMU(SUP), .CLINT_STD(SUP), .PLIC_S(SUP)) dut (
`else
    soc_top #(.UART_DIV(DIV), .MTIME_PRESC(1), .SU(SUP), .MMU(SUP), .CLINT_STD(SUP), .PLIC_S(SUP)) dut (
`endif
        .clk(clk), .rst_n(rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx), .ext_irq(ext_irq),
        .gpio_in(pad), .gpio_out(gpio_out), .gpio_oe(gpio_oe), .exit_valid(exit_valid), .exit_code(exit_code)
    );

    // ---------- nap ROM, tham so dong lenh ----------
    reg [8*256-1:0] rom_file, exp_file;
    reg show = 1'b0, lat_on = 1'b0;
    integer scn, max_cyc, want_code, fd, ch, exp_n, i;
    reg [7:0] exp_buf [0:4095];
    reg [7:0] out_buf [0:4095];
    integer out_n = 0;
    integer cyc = 0;
    integer errors = 0;
    initial begin
        if (!$value$plusargs("rom=%s", rom_file)) begin $display("[SOC] FAIL thieu +rom="); $finish; end
        show = $test$plusargs("show");
        if (!$value$plusargs("scn=%d", scn)) scn = 0;
        if (!$value$plusargs("max=%d", max_cyc)) max_cyc = 2000000;
        if (!$value$plusargs("code=%d", want_code)) want_code = 0;
        exp_n = 0;
        if ($value$plusargs("exp=%s", exp_file)) begin
            fd = $fopen(exp_file, "r");
            if (fd == 0) begin $display("[SOC] FAIL khong mo duoc file mong doi"); $finish; end
            ch = $fgetc(fd);
            while (ch != -1) begin exp_buf[exp_n] = ch[7:0]; exp_n = exp_n + 1; ch = $fgetc(fd); end
            $fclose(fd);
        end
        #1 $readmemh(rom_file, dut.u_rom.mem);
        repeat (4) @(posedge clk);
        #1 rst_n = 1;
    end

    always @(posedge clk) if (rst_n) cyc <= cyc + 1;

    // ---------- giai ma UART TX o muc bit ----------
    integer mon_div = DIV;          // chu ky moi bit mong doi (kich ban co the doi theo dau nhac)
    integer fdiv, t0, rel, k;
    reg     tx_q = 1'b1, infr = 1'b0;
    reg [7:0] sh;
    integer frames = 0;
    always @(posedge clk) if (rst_n) begin
        tx_q <= uart_tx;
        rel = cyc - t0;
        if (infr && rel == 10 * fdiv) infr = 1'b0;                       // het bit stop
        if (!infr) begin
            if (tx_q && !uart_tx) begin infr = 1'b1; t0 = cyc; fdiv = mon_div; end
            else if (tx_q != uart_tx) begin errors = errors + 1; $display("[SOC] LOI UART: nhieu (len cao) ngoai khung, chu ky %0d", cyc); end
        end else begin
            if (uart_tx != tx_q && (rel % fdiv) != 0) begin
                errors = errors + 1; $display("[SOC] LOI UART: chuyen muc o chu ky %0d (rel %0d), khong nam o bien bit (DIV %0d)", cyc, rel, fdiv);
            end
            if ((rel % fdiv) == fdiv / 2) begin
                k = rel / fdiv;
                if (k == 0) begin
                    if (uart_tx !== 1'b0) begin errors = errors + 1; $display("[SOC] LOI UART: bit start != 0"); end
                end else if (k <= 8) sh[k-1] = uart_tx;
                else if (k == 9) begin
                    if (uart_tx !== 1'b1) begin errors = errors + 1; $display("[SOC] LOI UART: bit stop != 1"); end
                    if (out_n < 4096) out_buf[out_n] = sh;
                    if ($test$plusargs("stamp")) $display("[STAMP] %0d %c", cyc, (sh == 8'h0A) ? 8'h7E : sh);
                    out_n = out_n + 1; frames = frames + 1;
                end
            end
        end
    end

    // ---------- tien ich kich thich ----------
    task send_byte(input [7:0] d, input stop, input integer bitc);
        integer j;
        begin
            uart_rx = 1'b0; repeat (bitc) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin uart_rx = d[j]; repeat (bitc) @(posedge clk); end
            uart_rx = stop; repeat (bitc) @(posedge clk);
            uart_rx = 1'b1;
        end
    endtask

    // cho tin hieu TX ket thuc bang chuoi pat (n ky tu, ky tu dau o byte cao nhat)
    task wait_for(input [8*8-1:0] pat, input integer n);
        reg ok; integer j;
        begin
            ok = 1'b0;
            while (!ok) begin
                @(posedge clk);
                if (out_n >= n) begin
                    ok = 1'b1;
                    for (j = 0; j < n; j = j + 1) if (out_buf[out_n - n + j] !== pat[8*(n-1-j) +: 8]) ok = 1'b0;
                end
            end
            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        wait (rst_n);
        case (scn)
        1: begin
            wait_for("D24\n", 4); mon_div = 24;
            wait_for("D16\n", 4); mon_div = 16;
            wait_for("R1\n", 3);
            send_byte("a", 1'b1, 16); send_byte("b", 1'b1, 16); send_byte("c", 1'b1, 16); send_byte("d", 1'b1, 16); send_byte("e", 1'b1, 16);
            send_byte("f", 1'b1, 16); send_byte("g", 1'b1, 16); send_byte("h", 1'b1, 16); send_byte("i", 1'b1, 16); send_byte("j", 1'b1, 16);
            wait_for("R2\n", 3);
            send_byte("Q", 1'b0, 16);
            wait_for("R3\n", 3);
            send_byte("h", 1'b1, 16); repeat (50) @(posedge clk);
            send_byte("e", 1'b1, 16); send_byte("l", 1'b1, 16); send_byte("L", 1'b1, 16); repeat (200) @(posedge clk);
            send_byte("o", 1'b1, 16); send_byte(" ", 1'b1, 16); send_byte("1", 1'b1, 16); send_byte("\n", 1'b1, 16);
        end
        2: begin
            wait_for("G1\n", 3); ext_in[12] = 1'b1;
            wait_for("G2\n", 3);
            ext_in[13] = 1'b1; repeat (3) @(posedge clk);
            ext_in[12] = 1'b0; repeat (400) @(posedge clk);
            ext_in[12] = 1'b1; repeat (400) @(posedge clk);
            ext_in[13] = 1'b0;
            wait_for("G3\n", 3);
            ext_in[12] = 1'b0; repeat (20) @(posedge clk); ext_in[12] = 1'b1;
        end
        3: begin
            wait_for("RDY\n", 4);
            send_byte("p", 1'b1, 16); send_byte("i", 1'b1, 16); send_byte("n", 1'b1, 16); send_byte("g", 1'b1, 16); send_byte("\n", 1'b1, 16);
        end
        4: begin
            wait_for("P1\n", 3); ext_irq = 4'hF;
            wait_for("P2\n", 3); ext_irq = 4'h0;
        end
        5: begin
            wait_for("Q2\n", 3); send_byte("a", 1'b1, 16);
            wait_for("Q4\n", 3); send_byte("x", 1'b1, 16); send_byte("y", 1'b1, 16);
            // pha do tre: moi task ngu, chi Idle chay; 4 ky tu cach nhau 3333 chu ky (khong boi cua chu ky tick 2000), chi cac ngat nay duoc tinh vao thong ke
            wait_for("LAT\n", 4); lat_on = 1'b1;
            repeat (3333) @(posedge clk); send_byte("p", 1'b1, 16);
            repeat (3333) @(posedge clk); send_byte("q", 1'b1, 16);
            repeat (3333) @(posedge clk); send_byte("r", 1'b1, 16);
            repeat (3333) @(posedge clk); send_byte("s", 1'b1, 16);
        end
        default: ;
        endcase
    end

    // ---------- do tre ngat (FreeRTOS): tu luc EIP cua PLIC len cao den lan lay lenh dau tien tai bo xu ly trap / tai mark_wake ----------
    reg [31:0] trap_a, wake_a;
    reg        have_lat = 1'b0, irq_q = 1'b0, w_trap = 1'b0, w_wake = 1'b0;
    integer    irq_t, lat_n = 0, lt, lw, tr_min = 1 << 30, tr_max = 0, tr_sum = 0, wk_min = 1 << 30, wk_max = 0, wk_sum = 0, wk_n = 0;
    initial begin
        have_lat = $value$plusargs("trap=%h", trap_a) & $value$plusargs("wake=%h", wake_a);
    end
    always @(posedge clk) if (rst_n && have_lat) begin
        irq_q <= dut.irq_ext;
        if (dut.irq_ext && !irq_q && lat_on) begin irq_t = cyc; w_trap = 1'b1; w_wake = 1'b0; end
        if (w_trap && {dut.imem_addr[31:2], 2'b00} == trap_a) begin
            if ($test$plusargs("lat")) $display("[lat] trap at %0d (irq %0d)", cyc, irq_t);
            w_trap = 1'b0; w_wake = 1'b1; lt = cyc - irq_t; lat_n = lat_n + 1; tr_sum = tr_sum + lt;
            if (lt < tr_min) tr_min = lt; if (lt > tr_max) tr_max = lt;
        end
        if (w_wake && {dut.imem_addr[31:2], 2'b00} == {wake_a[31:2], 2'b00}) begin
            if ($test$plusargs("lat")) $display("[lat] wake at %0d (irq %0d)", cyc, irq_t);
            w_wake = 1'b0; lw = cyc - irq_t; wk_n = wk_n + 1; wk_sum = wk_sum + lw;
            if (lw < wk_min) wk_min = lw; if (lw > wk_max) wk_max = lw;
        end
    end

    // ---------- ket thuc ----------
    integer sticky_exit = 0;
    always @(posedge clk) begin
        if (rst_n && exit_valid && !sticky_exit) begin
            sticky_exit = 1;
            repeat (20 * DIV) @(posedge clk);                          // cho khung UART cuoi (neu con) ket thuc
            report;
        end
        if (rst_n && cyc >= max_cyc && !sticky_exit) begin
            sticky_exit = 1;
            $display("[SOC] FAIL het gio sau %0d chu ky (da nhan %0d ky tu)", cyc, out_n); show_out; $finish;
        end
    end


`ifdef AXI
    // Bo kiem giao thuc AXI4 (soc/axi/axi_checker.v) o 3 cong master va 3 cong slave cua interconnect; moi vi pham lam test that bai.
    genvar gi;
    generate
        for (gi = 0; gi < 3; gi = gi + 1) begin : axm
            axi_checker #(.NAME(gi == 0 ? "M0" : gi == 1 ? "M1" : "M2"), .IDW(4)) chk (.clk(clk), .rst_n(rst_n),
                .awid(dut.s_awid[gi*4 +: 4]), .awaddr(dut.s_awaddr[gi*32 +: 32]), .awlen(dut.s_awlen[gi*8 +: 8]), .awsize(dut.s_awsize[gi*3 +: 3]), .awburst(dut.s_awburst[gi*2 +: 2]), .awvalid(dut.s_awvalid[gi]), .awready(dut.s_awready[gi]),
                .wdata(dut.s_wdata[gi*32 +: 32]), .wstrb(dut.s_wstrb[gi*4 +: 4]), .wlast(dut.s_wlast[gi]), .wvalid(dut.s_wvalid[gi]), .wready(dut.s_wready[gi]),
                .bid(dut.s_bid[gi*4 +: 4]), .bresp(dut.s_bresp[gi*2 +: 2]), .bvalid(dut.s_bvalid[gi]), .bready(dut.s_bready[gi]),
                .arid(dut.s_arid[gi*4 +: 4]), .araddr(dut.s_araddr[gi*32 +: 32]), .arlen(dut.s_arlen[gi*8 +: 8]), .arsize(dut.s_arsize[gi*3 +: 3]), .arburst(dut.s_arburst[gi*2 +: 2]), .arvalid(dut.s_arvalid[gi]), .arready(dut.s_arready[gi]),
                .rid(dut.s_rid[gi*4 +: 4]), .rdata(dut.s_rdata[gi*32 +: 32]), .rresp(dut.s_rresp[gi*2 +: 2]), .rlast(dut.s_rlast[gi]), .rvalid(dut.s_rvalid[gi]), .rready(dut.s_rready[gi]));
            axi_checker #(.NAME(gi == 0 ? "S0" : gi == 1 ? "S1" : "S2"), .IDW(6)) chs (.clk(clk), .rst_n(rst_n),
                .awid(dut.m_awid[gi*6 +: 6]), .awaddr(dut.m_awaddr[gi*32 +: 32]), .awlen(dut.m_awlen[gi*8 +: 8]), .awsize(dut.m_awsize[gi*3 +: 3]), .awburst(dut.m_awburst[gi*2 +: 2]), .awvalid(dut.m_awvalid[gi]), .awready(dut.m_awready[gi]),
                .wdata(dut.m_wdata[gi*32 +: 32]), .wstrb(dut.m_wstrb[gi*4 +: 4]), .wlast(dut.m_wlast[gi]), .wvalid(dut.m_wvalid[gi]), .wready(dut.m_wready[gi]),
                .bid(dut.m_bid[gi*6 +: 6]), .bresp(dut.m_bresp[gi*2 +: 2]), .bvalid(dut.m_bvalid[gi]), .bready(dut.m_bready[gi]),
                .arid(dut.m_arid[gi*6 +: 6]), .araddr(dut.m_araddr[gi*32 +: 32]), .arlen(dut.m_arlen[gi*8 +: 8]), .arsize(dut.m_arsize[gi*3 +: 3]), .arburst(dut.m_arburst[gi*2 +: 2]), .arvalid(dut.m_arvalid[gi]), .arready(dut.m_arready[gi]),
                .rid(dut.m_rid[gi*6 +: 6]), .rdata(dut.m_rdata[gi*32 +: 32]), .rresp(dut.m_rresp[gi*2 +: 2]), .rlast(dut.m_rlast[gi]), .rvalid(dut.m_rvalid[gi]), .rready(dut.m_rready[gi]));
        end
    endgenerate
    // Kiem tra cap SoC (bo kiem giao thuc khong biet ma master "can" bao nhieu beat): burst nap dong cua cache dung bang so tu cua dong, cong lenh chi nap dong
    integer len_errs = 0;
    always @(posedge clk) if (rst_n) begin
        if (dut.s_arvalid[0] & dut.s_arready[0] & (dut.s_arlen[7:0] !== dut.IC_WORDS - 1)) begin len_errs = len_errs + 1; $display("[SOC] M0 AR: ARLEN %0d khac so tu cua dong - 1", dut.s_arlen[7:0]); end
        if (dut.s_arvalid[1] & dut.s_arready[1] & (dut.s_arlen[15:8] !== dut.DC_WORDS - 1) & (dut.s_arlen[15:8] !== 8'd0)) begin len_errs = len_errs + 1; $display("[SOC] M1 AR: ARLEN %0d khong phai nap dong hay 1 beat", dut.s_arlen[15:8]); end
    end
    wire [31:0] axi_errs = axm[0].chk.errors + axm[1].chk.errors + axm[2].chk.errors + axm[0].chs.errors + axm[1].chs.errors + axm[2].chs.errors + len_errs;
`endif

    task show_out; integer j; begin $write("[SOC] da nhan: \""); for (j = 0; j < out_n && j < 4096; j = j + 1) $write("%c", out_buf[j]); $display("\""); end endtask

    task report;
        integer j, bad, jj, kk;
        begin
            bad = 0;
            if (exp_n > 0 || out_n > 0) begin
                // so khop, '#' trong mong doi = mot day chu so thap phan (>= 1 chu so)
                jj = 0; kk = 0;
                while (jj < exp_n && kk < out_n) begin
                    if (exp_buf[jj] == "#") begin
                        if (out_buf[kk] < "0" || out_buf[kk] > "9") begin bad = bad + 1; jj = exp_n; end
                        else begin while (kk < out_n && out_buf[kk] >= "0" && out_buf[kk] <= "9") kk = kk + 1; jj = jj + 1; end
                    end else begin
                        if (out_buf[kk] !== exp_buf[jj]) bad = bad + 1;
                        jj = jj + 1; kk = kk + 1;
                    end
                end
                if (jj < exp_n || kk < out_n) bad = bad + 1;
            end
            if (exit_code !== want_code[31:0]) begin $display("[SOC] LOI ma thoat %08x, mong doi %08x (SCRATCH = mepc luc loi: %08x)", exit_code, want_code, dut.u_sys.scratch); bad = bad + 1; end
            if (errors != 0) bad = bad + 1;
`ifdef AXI
            if (axi_errs != 0) begin bad = bad + 1; $display("[SOC] LOI giao thuc AXI4: %0d vi pham (xem dong [AXI])", axi_errs); end
`endif
            if (have_lat && (lat_n < 2 || wk_n < 2)) begin bad = bad + 1; $display("[SOC] LOI do tre ngat: chi do duoc %0d lan toi trap, %0d lan toi mark_wake", lat_n, wk_n); end
            if (bad == 0) begin
                $display("[SOC] PASS %0d chu ky, %0d ky tu UART, ma thoat %0d", cyc, out_n, exit_code);
                if (have_lat) begin
                    $display("[SOC] RTOS do tre ngat (EIP len -> lay lenh dau o bo xu ly trap): n=%0d min=%0d trung binh=%0d max=%0d chu ky", lat_n, tr_min, tr_sum / lat_n, tr_max);
                    $display("[SOC] RTOS do tre ngat (EIP len -> lay lenh dau o mark_wake, task UART chay lai): n=%0d min=%0d trung binh=%0d max=%0d chu ky", wk_n, wk_min, wk_sum / wk_n, wk_max);
                end
                if (show) begin show_out; end
            end
            else begin $display("[SOC] FAIL (%0d loi, %0d loi UART)", bad, errors); show_out; end
            $finish;
        end
    endtask
endmodule
