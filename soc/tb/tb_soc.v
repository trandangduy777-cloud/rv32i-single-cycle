`timescale 1ns/1ps
// Testbench SoC: nap ROM tu hex (+rom=), giai ma UART TX o muc bit (kiem do dai tung bit dung bang chu ky quy dinh, bit start/stop, khong nhieu),
// so chuoi nhan duoc voi file mong doi (+exp=), kiem ma thoat (+code=, mac dinh 0) va thoi gian toi da (+max=, mac dinh 2.000.000 chu ky).
// +scn=N chon kich ban kich thich ben ngoai (theo dau nhac trong luong TX): 0 khong co, 1 UART RX, 2 GPIO, 3 UART RX + ngat.
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

    soc_top #(.UART_DIV(DIV), .MTIME_PRESC(1)) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in(pad), .gpio_out(gpio_out), .gpio_oe(gpio_oe), .exit_valid(exit_valid), .exit_code(exit_code)
    );

    // ---------- nap ROM, tham so dong lenh ----------
    reg [8*256-1:0] rom_file, exp_file;
    integer scn, max_cyc, want_code, fd, ch, exp_n, i;
    reg [7:0] exp_buf [0:4095];
    reg [7:0] out_buf [0:4095];
    integer out_n = 0;
    integer cyc = 0;
    integer errors = 0;
    initial begin
        if (!$value$plusargs("rom=%s", rom_file)) begin $display("[SOC] FAIL thieu +rom="); $finish; end
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
        default: ;
        endcase
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

    task show_out; integer j; begin $write("[SOC] da nhan: \""); for (j = 0; j < out_n && j < 4096; j = j + 1) $write("%c", out_buf[j]); $display("\""); end endtask

    task report;
        integer j, bad;
        begin
            bad = 0;
            if (exp_n > 0 || out_n > 0) begin
                if (out_n != exp_n) bad = bad + 1;
                for (j = 0; j < exp_n && j < out_n; j = j + 1) if (out_buf[j] !== exp_buf[j]) bad = bad + 1;
            end
            if (exit_code !== want_code[31:0]) begin $display("[SOC] LOI ma thoat %08x, mong doi %08x (SCRATCH = mepc luc loi: %08x)", exit_code, want_code, dut.u_sys.scratch); bad = bad + 1; end
            if (errors != 0) bad = bad + 1;
            if (bad == 0) $display("[SOC] PASS %0d chu ky, %0d ky tu UART, ma thoat %0d", cyc, out_n, exit_code);
            else begin $display("[SOC] FAIL (%0d loi, %0d loi UART)", bad, errors); show_out; end
            $finish;
        end
    endtask
endmodule
