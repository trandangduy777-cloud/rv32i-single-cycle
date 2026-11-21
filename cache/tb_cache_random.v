`timescale 1ns/1ps
// Kiem tra ngau nhien rv32_icache + rv32_dcache + rv32_bus_arbiter, doc lap voi loi CPU, tu viet.
// - Phia du lieu: chuoi load/store ngau nhien (byte/half/word, dia chi trong 1 KB cacheable va 64 B khong cacheable,
//   de co nhieu xung dot dong), moi lenh giu yeu cau cho toi khi ready, giong tang MEM cua pipeline.
//   Load so voi mo hinh tham chieu (mang refm[] cap nhat theo store).
// - Phia lenh: dia chi chia het cho 2 ngau nhien trong vung ma, doi dia chi bat ky luc nao (ke ca khi cache dang nap,
//   giong redirect), so 32 bit tra ve voi bo nho khi ready. Phia du lieu thinh thoang ghi vao vung ma (ma tu sua)
//   roi flush cache lenh (nhu FENCE.I); tu luc ghi toi luc flush, cache lenh duoc phep tra du lieu cu.
// - Vung thiet bi (DEV, 16 tu): bo nho tu tang gia tri moi chu ky; load vao day phai di qua bus va tra dung gia tri
//   bus doc ve trong chinh lan load do (khong duoc luu cache).
// - Bo nho chung tra loi sau 1..LAT chu ky ngau nhien; cache lenh va du lieu tranh nhau bus qua bo phan xu.
// - Bao loi va dung ngay o lan lech dau tien. Ket thuc: in so lan kiem tra, so lan truot, so lan dung bus.
// Tham so: +seed=<so> +n=<so thao tac du lieu> +lat=<do tre toi da>. Kich thuoc cache: -DL=<dong> -DW=<tu/dong>
module tb_cache_random;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

`ifndef L
`define L 4
`endif
`ifndef W
`define W 2
`endif

    localparam [31:0] DBASE = 32'h0000_1000;   // 1 KB cacheable: 0x1000-0x13FF
    localparam [31:0] UBASE = 32'h0001_0000;   // 64 B khong cacheable
    localparam [31:0] CODE  = 32'h0000_0000;   // vung ma: 0x0000-0x03FF
    localparam [31:0] DEV   = 32'h0001_8000;   // thiet bi: 16 tu, gia tri tu tang, khong cacheable

    // ---- bo nho chung + mo hinh tham chieu ----
    reg [31:0] mem [0:32767];      // 128 KB, chi so [16:2]
    reg [31:0] refm [0:32767];

    // ---- cache ----
    reg  [31:0] d_addr, d_wdata, i_addr;
    reg  [3:0]  d_wstrb;
    reg         d_re = 0, d_we = 0, i_flush = 0;
    wire [31:0] d_rdata, i_data;
    wire        d_ready, i_ready;
    wire        ic_req, ic_ack, dc_req, dc_we, dc_ack, m_req, m_we;
    wire [31:0] ic_addr, dc_addr, dc_wdata, m_addr, m_wdata, ic_miss, dc_miss;
    wire [3:0]  dc_wstrb, m_wstrb;
    reg         m_ack = 0;
    reg  [31:0] m_rdata;

    rv32_icache #(.LINES(`L), .WORDS(`W)) u_ic (
        .clk(clk), .rst_n(rst_n), .addr(i_addr), .data(i_data), .ready(i_ready), .flush(i_flush),
        .m_req(ic_req), .m_addr(ic_addr), .m_ack(ic_ack), .m_rdata(m_rdata), .n_miss(ic_miss));
    rv32_dcache #(.LINES(`L), .WORDS(`W), .CMASK(32'hFFFF_0000), .CBASE(32'h0000_0000)) u_dc (   // 0x0000-0xFFFF
        .clk(clk), .rst_n(rst_n), .addr(d_addr), .re(d_re), .we(d_we), .wstrb(d_wstrb), .wdata(d_wdata),
        .rdata(d_rdata), .ready(d_ready),
        .m_req(dc_req), .m_we(dc_we), .m_addr(dc_addr), .m_wdata(dc_wdata), .m_wstrb(dc_wstrb),
        .m_ack(dc_ack), .m_rdata(m_rdata), .n_miss(dc_miss));
    rv32_bus_arbiter u_arb (
        .clk(clk), .rst_n(rst_n),
        .i_req(ic_req), .i_addr(ic_addr), .i_ack(ic_ack),
        .d_req(dc_req), .d_we(dc_we), .d_addr(dc_addr), .d_wdata(dc_wdata), .d_wstrb(dc_wstrb), .d_ack(dc_ack),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_ack(m_ack));

    integer seed = 1, lat = 6, nops = 20000, wait_cnt = 0, n_bus = 0, di;
    reg [31:0] dev_last;           // gia tri bus doc ve lan cuoi tu vung thiet bi
    reg        dev_rd;             // co lan doc bus vao vung thiet bi (xoa khi bat dau moi load)
    always @(posedge clk) begin
        m_ack <= 1'b0;
        for (di = 0; di < 16; di = di + 1) mem[(DEV >> 2) + di] <= mem[(DEV >> 2) + di] + 1;   // thiet bi tu tang
        if (rst_n && m_req && !m_ack && wait_cnt <= 0 && !m_we && m_addr[31:6] == DEV[31:6]) begin
            dev_last <= mem[m_addr[16:2]];
            dev_rd   <= 1'b1;
        end
        if (rst_n && m_req && !m_ack) begin
            if (wait_cnt <= 0) begin
                m_ack   <= 1'b1;
                n_bus    = n_bus + 1;
                m_rdata <= mem[m_addr[16:2]];
                if (m_we) begin
                    if (m_wstrb[0]) mem[m_addr[16:2]][7:0]   <= m_wdata[7:0];
                    if (m_wstrb[1]) mem[m_addr[16:2]][15:8]  <= m_wdata[15:8];
                    if (m_wstrb[2]) mem[m_addr[16:2]][23:16] <= m_wdata[23:16];
                    if (m_wstrb[3]) mem[m_addr[16:2]][31:24] <= m_wdata[31:24];
                end
                wait_cnt = $urandom(seed) % lat;
                seed = seed + 1;
            end else
                wait_cnt = wait_cnt - 1;
        end
    end

    // ---- kiem tra phia lenh: moi chu ky ready, so voi bo nho ----
    integer n_ichk = 0, n_code_wr = 0;
    reg [31:0] iexp;
    reg        code_dirty = 0;     // da ghi vao vung ma, chua flush: cache lenh duoc phep cu
    always @(posedge clk) begin
        if (rst_n && i_ready && !code_dirty) begin
            iexp = i_addr[1] ? {mem[i_addr[16:2] + 1][15:0], mem[i_addr[16:2]][31:16]} : mem[i_addr[16:2]];
            if (i_data !== iexp) begin
                $display("[CACHE] FAIL: cache lenh addr=%08x tra %08x, dung la %08x", i_addr, i_data, iexp);
                $finish;
            end
            n_ichk = n_ichk + 1;
        end
    end
    // doi dia chi lenh ngau nhien (ke ca luc chua ready), thinh thoang flush
    always @(posedge clk) begin
        if (rst_n) begin
            if (i_ready || ($urandom(seed) % 8 == 0)) begin
                // thuong di tuan tu (+2 hoac +4), doi khi nhay
                if ($urandom(seed) % 6 == 0) i_addr <= CODE + (($urandom(seed) % 512) << 1);
                else i_addr <= CODE + ((i_addr + (($urandom(seed) % 2) ? 32'd2 : 32'd4)) & 32'h3FE);
            end
            i_flush <= ($urandom(seed) % 500 == 0) | flush_req;
        end
    end

    // ---- phia du lieu ----
    integer op, i, n_ld = 0, n_st = 0, n_dev = 0, sz, kind;
    reg flush_req = 0;
    reg [31:0] a, v, expv, mask;
    reg [3:0]  strb;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("n=%d", nops)) nops = 20000;
        if (!$value$plusargs("lat=%d", lat)) lat = 6;
        if (lat < 1) lat = 1;
        for (i = 0; i < 32768; i = i + 1) begin
            mem[i] = $urandom(seed); refm[i] = mem[i];
        end
        i_addr = CODE;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1;

        for (op = 0; op < nops; op = op + 1) begin
            // dia chi: 80 % cacheable (1 KB), 8 % khong cacheable (64 B), 6 % thiet bi (chi load), 6 % vung ma (chi store)
            kind = $urandom(seed) % 50;
            a  = kind < 4 ? UBASE + ($urandom(seed) % 64) : (kind < 7 ? DEV + ($urandom(seed) % 64) :
                 (kind < 10 ? CODE + (((i_addr & 32'h3F8) + ($urandom(seed) % 16)) & 32'h3FF) :   // gan lenh dang nap
                  DBASE + ($urandom(seed) % 1024)));
            sz = $urandom(seed) % 3;                         // 0 byte, 1 half, 2 word
            a  = sz == 2 ? {a[31:2], 2'b00} : (sz == 1 ? {a[31:1], 1'b0} : a);
            strb = sz == 2 ? 4'b1111 : (sz == 1 ? (a[1] ? 4'b1100 : 4'b0011) : (4'b0001 << a[1:0]));
            mask = {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}};
            @(negedge clk);
            d_addr = a; d_wstrb = strb;
            if (kind >= 7 && kind < 10 || (kind >= 10 && $urandom(seed) % 2)) begin   // store
                if (kind >= 7 && kind < 10) begin code_dirty = 1; n_code_wr = n_code_wr + 1; end
                v = $urandom(seed);
                d_wdata = v; d_we = 1; d_re = 0;
                #1;
                while (!d_ready) begin @(posedge clk); #1; end
                @(posedge clk);
                refm[a[16:2]] = (refm[a[16:2]] & ~mask) | (v & mask);
                n_st = n_st + 1;
                if (code_dirty) begin                        // store vao ma da toi bo nho: flush cache lenh
                    @(negedge clk) d_we = 0; flush_req = 1;
                    @(negedge clk) flush_req = 0;
                    @(negedge clk) code_dirty = 0;
                end
            end else begin                                   // load
                d_we = 0; d_re = 1; dev_rd = 0;
                #1;
                while (!d_ready) begin @(posedge clk); #1; end
                if (kind >= 4 && kind < 7) begin             // thiet bi: phai doc qua bus trong lan load nay
                    if (!dev_rd) begin
                        $display("[CACHE] FAIL: load thiet bi %08x khong di qua bus (thao tac %0d)", a, op);
                        $finish;
                    end
                    expv = dev_last; n_dev = n_dev + 1;
                end else
                    expv = refm[a[16:2]];
                if ((d_rdata & mask) !== (expv & mask)) begin
                    $display("[CACHE] FAIL: load %08x (strb %b) tra %08x, dung la %08x (thao tac %0d)",
                             a, strb, d_rdata & mask, expv & mask, op);
                    $finish;
                end
                @(posedge clk);
                n_ld = n_ld + 1;
            end
            d_we = 0; d_re = 0;
            // thinh thoang de trong vai chu ky
            if ($urandom(seed) % 4 == 0) repeat ($urandom(seed) % 3) @(posedge clk);
        end
        // bo nho phai khop mo hinh tham chieu (ghi xuyen: moi store da toi bo nho)
        for (i = 0; i < 32768; i = i + 1)
            if (mem[i] !== refm[i] && i[31:4] != DEV[31:6]) begin
                $display("[CACHE] FAIL: bo nho tai %08x = %08x, dung la %08x", i << 2, mem[i], refm[i]);
                $finish;
            end
        $display("[CACHE] PASS: %0d load (%0d thiet bi), %0d store (%0d vao vung ma), %0d lan kiem tra cache lenh; truot: lenh %0d, du lieu %0d; %0d lan dung bus",
                 n_ld, n_dev, n_st, n_code_wr, n_ichk, ic_miss, dc_miss, n_bus);
        $finish;
    end

    initial begin #200_000_000; $display("[CACHE] FAIL: het thoi gian"); $finish; end
endmodule
