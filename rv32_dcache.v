// Cache du lieu anh xa truc tiep, ghi xuyen (write-through) qua bo dem ghi (write buffer), khong cap phat khi ghi
// (no-write-allocate), tu viet.
// - Phia loi (tang MEM cua pipeline): addr, re (load), we + wstrb + wdata (store), fence (FENCE / FENCE.I).
//   ready = 1 khi thao tac xong trong chu ky nay; voi load, rdata hop le cung chu ky.
// - Store: dua vao bo dem ghi WBUF muc (FIFO) va xong ngay trong chu ky do (ready = 1) neu bo dem con cho; dong dang
//   co trong cache duoc cap nhat cac byte theo wstrb cung luc. Bo dem day: store cho toi khi co cho.
//   Bo dem tu ghi ra bus theo dung thu tu FIFO moi khi bus cua cache ranh (trang thai DRN).
// - Load trung cache: ready ngay (khong ton chu ky), ke ca khi bo dem dang ghi ra bus.
// - Load truot cache trong vung cacheable: nap ca dong (WORDS tu) ma KHONG cho bo dem ghi het: moi tu doc ve duoc tron
//   (forward) voi moi store con trong bo dem trung dia chi tu do, theo thu tu tu cu toi moi, nen dong nap vao luon
//   mang gia tri moi nhat du bo nho chua nhan cac store do. Trong luc nap, bus dung cho nap nen bo dem dung yen.
// - Load ngoai vung cacheable (thiet bi ngoai vi, TOHOST...): ghi het bo dem truoc (giu thu tu voi thiet bi), roi doc
//   thang 1 tu qua bus, khong luu.
// - fence: cho toi khi bo dem rong (moi store truoc do da toi bo nho) roi ready.
// - Thu tu voi cache lenh (FENCE.I): bo phan xu bus uu tien phia du lieu va bo dem giu m_req lien tuc khi con du lieu,
//   nen moi store vao bo dem truoc mot lan nap cua cache lenh deu toi bo nho truoc lan nap do.
// - Vung cacheable: (addr & CMASK) == CBASE.
// - Bus: 1 yeu cau moi lan, m_req giu cho toi khi m_ack (1 chu ky); m_rdata hop le khi m_ack voi lenh doc.
module rv32_dcache #(
    parameter        LINES = 16,
    parameter        WORDS = 4,
    parameter        WBUF  = 4,                 // so muc bo dem ghi (>= 1)
    parameter [31:0] CMASK = 32'h0000_0000,     // mac dinh: ca bo nho deu cacheable
    parameter [31:0] CBASE = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst_n,
    // phia loi
    input  wire [31:0] addr,
    input  wire        re,
    input  wire        we,
    input  wire        fence,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output wire        ready,
    output wire        wb_empty,               // bo dem ghi rong
    // phia bus
    output wire        m_req,
    output wire        m_we,
    output wire [31:0] m_addr,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    input  wire        m_ack,
    input  wire [31:0] m_rdata,
    // thong ke
    output reg  [31:0] n_miss
);
    localparam IB = $clog2(LINES);
    localparam WB = $clog2(WORDS);
    localparam TB = 30 - IB - WB;
    localparam QB = (WBUF > 1) ? $clog2(WBUF) : 1;

    reg [TB-1:0] tag_r [0:LINES-1];
    reg          val_r [0:LINES-1];
    reg [31:0]   mem_r [0:LINES*WORDS-1];

    wire [29:0]   w   = addr[31:2];
    wire [IB-1:0] idx = w[WB +: IB];
    wire [TB-1:0] tg  = w[29 -: TB];
    wire          cacheable = ((addr & CMASK) == CBASE);
    wire          hit = cacheable & val_r[idx] & (tag_r[idx] == tg);
    wire [31:0]   cdata = mem_r[w[IB+WB-1:0]];

    localparam IDLE = 2'd0, FILL = 2'd1, UNC = 2'd2, DRN = 2'd3;
    reg [1:0]    state;
    reg [WB-1:0] fill_cnt;

    // ---- bo dem ghi: FIFO WBUF muc {dia chi tu, du lieu, wstrb} ----
    reg [29:0]   q_addr [0:WBUF-1];
    reg [31:0]   q_data [0:WBUF-1];
    reg [3:0]    q_strb [0:WBUF-1];
    reg [QB-1:0] q_head, q_tail;
    reg [QB:0]   q_cnt;
    wire         q_full = (q_cnt == WBUF);
    assign wb_empty = (q_cnt == 0);

    function [QB-1:0] q_inc(input [QB-1:0] p);
        q_inc = (p == WBUF - 1) ? {QB{1'b0}} : p + 1'b1;
    endfunction

    // trang thai cho phep phuc vu loi ngay: khong dang nap dong / doc ngoai vung (DRN chi chiem bus de ghi)
    wire free   = (state == IDLE) | (state == DRN);
    wire push   = free & we & ~q_full;                    // store vao bo dem trong chu ky nay
    wire pop    = (state == DRN) & m_ack;                 // muc dau bo dem da toi bo nho
    wire ld_hit = free & re & hit;

    assign ready = push | ld_hit | (state == UNC & m_ack) | (free & fence & wb_empty);
    assign rdata = (state == UNC) ? m_rdata : cdata;

    // ---- forward khi nap dong: tron tu doc ve voi moi store trong bo dem cung dia chi, tu cu toi moi ----
    wire [29:0] fill_w = {w[29:WB], fill_cnt};
    reg  [31:0] fill_data, fmask;
    reg         fill_fwd;
    reg  [QB:0] fs;
    integer     j;
    always @* begin
        fill_data = m_rdata;
        fill_fwd  = 1'b0;
        for (j = 0; j < WBUF; j = j + 1) begin
            fs = q_head + j;
            if (fs >= WBUF) fs = fs - WBUF;
            fmask = {{8{q_strb[fs][3]}}, {8{q_strb[fs][2]}}, {8{q_strb[fs][1]}}, {8{q_strb[fs][0]}}};
            if (j < q_cnt && q_addr[fs] == fill_w) begin
                fill_data = (fill_data & ~fmask) | (q_data[fs] & fmask);
                fill_fwd  = 1'b1;
            end
        end
    end

    assign m_req   = (state != IDLE);
    assign m_we    = (state == DRN);
    assign m_addr  = (state == FILL) ? {w[29:WB], fill_cnt, 2'b00} :
                     (state == DRN)  ? {q_addr[q_head], 2'b00} : {w, 2'b00};
    assign m_wdata = q_data[q_head];
    assign m_wstrb = (state == DRN) ? q_strb[q_head] : 4'b1111;

    wire [31:0] wmask = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};

    // so muc con lai sau chu ky nay (de quyet dinh co ghi tiep khong)
    wire [QB:0] q_next = q_cnt + push - pop;
    wire        rd_miss = re & ~hit;                      // load can dung bus (nap dong hoac doc ngoai vung)

    // thong ke (doc qua phan cap tu testbench)
    reg [31:0] n_wbfull, n_fwd, n_drain;

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            fill_cnt <= {WB{1'b0}};
            n_miss   <= 32'd0;
            n_wbfull <= 32'd0;
            n_fwd    <= 32'd0;
            n_drain  <= 32'd0;
            q_head   <= {QB{1'b0}};
            q_tail   <= {QB{1'b0}};
            q_cnt    <= {(QB+1){1'b0}};
            for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;
        end else begin
            q_cnt <= q_next;
            if (push) begin
                q_addr[q_tail] <= w;
                q_data[q_tail] <= wdata;
                q_strb[q_tail] <= wstrb;
                q_tail <= q_inc(q_tail);
                if (hit) mem_r[w[IB+WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);
            end
            if (pop) begin
                q_head  <= q_inc(q_head);
                n_drain <= n_drain + 32'd1;
            end
            if (free & we & q_full) n_wbfull <= n_wbfull + 32'd1;

            case (state)
                // Bat bien: bo dem con du lieu thi state != IDLE (tru chinh chu ky store vao bo dem trong IDLE), de
                // m_req khong ha giua cac lan dung bus va bo phan xu khong cap bus cho cache lenh truoc khi ghi het.
                IDLE: begin
                    if (rd_miss & cacheable) begin               // nap dong ngay, khong cho bo dem
                        state      <= FILL;
                        fill_cnt   <= {WB{1'b0}};
                        val_r[idx] <= 1'b0;                      // dong cu bi thay
                        n_miss     <= n_miss + 32'd1;
                    end else if (rd_miss & wb_empty)             // ngoai vung cacheable, bo dem da rong
                        state <= UNC;
                    else if (~wb_empty | push)                   // con store (hoac vua nhan): ghi ra bus
                        state <= DRN;
                end
                DRN: if (m_ack) begin
                    if (rd_miss & cacheable) begin               // load truot dang cho: nap dong ngay sau lan ghi nay
                        state      <= FILL;
                        fill_cnt   <= {WB{1'b0}};
                        val_r[idx] <= 1'b0;
                        n_miss     <= n_miss + 32'd1;
                    end else if (q_next == 0)                    // ghi het: doc ngoai vung (neu dang cho) hoac nghi
                        state <= rd_miss ? UNC : IDLE;
                end
                FILL: if (m_ack) begin
                    mem_r[{idx, fill_cnt}] <= fill_data;
                    if (fill_fwd) n_fwd <= n_fwd + 32'd1;
                    fill_cnt <= fill_cnt + 1'b1;
                    if (fill_cnt == {WB{1'b1}}) begin
                        tag_r[idx] <= tg;
                        val_r[idx] <= 1'b1;
                        state <= wb_empty ? IDLE : DRN;          // chu ky sau trung cache -> ready (IDLE va DRN deu phuc vu)
                    end
                end
                UNC: if (m_ack) state <= IDLE;                   // bo dem rong suot UNC (khong nhan store)
            endcase
        end
    end
endmodule
