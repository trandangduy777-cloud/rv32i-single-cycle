// Cache du lieu anh xa truc tiep, ghi xuyen (write-through), khong cap phat khi ghi (no-write-allocate), tu viet.
// - Phia loi (tang MEM cua pipeline): addr, re (load), we + wstrb + wdata (store). ready = 1 khi thao tac xong trong
//   chu ky nay; voi load, rdata hop le cung chu ky. Load trung cache: ready ngay (khong ton chu ky).
// - Load truot cache trong vung cacheable: nap ca dong (WORDS tu, tung tu qua bus) roi tra ket qua.
// - Load ngoai vung cacheable (thiet bi ngoai vi, TOHOST...): doc thang 1 tu qua bus, khong luu.
// - Store: luon ghi qua bus (1 tu, theo wstrb); neu dong dang co trong cache thi cap nhat cac byte tuong ung cung luc
//   bus xac nhan. Store khong nap dong moi.
// - Vung cacheable: (addr & CMASK) == CBASE.
// - Bus: 1 yeu cau moi lan, m_req giu cho toi khi m_ack (1 chu ky); m_rdata hop le khi m_ack voi lenh doc.
module rv32_dcache #(
    parameter        LINES = 16,
    parameter        WORDS = 4,
    parameter [31:0] CMASK = 32'h0000_0000,     // mac dinh: ca bo nho deu cacheable
    parameter [31:0] CBASE = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst_n,
    // phia loi
    input  wire [31:0] addr,
    input  wire        re,
    input  wire        we,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output wire        ready,
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

    reg [TB-1:0] tag_r [0:LINES-1];
    reg          val_r [0:LINES-1];
    reg [31:0]   mem_r [0:LINES*WORDS-1];

    wire [29:0]   w   = addr[31:2];
    wire [IB-1:0] idx = w[WB +: IB];
    wire [TB-1:0] tg  = w[29 -: TB];
    wire          cacheable = ((addr & CMASK) == CBASE);
    wire          hit = cacheable & val_r[idx] & (tag_r[idx] == tg);
    wire [31:0]   cdata = mem_r[w[IB+WB-1:0]];

    localparam IDLE = 2'd0, FILL = 2'd1, UNC = 2'd2, WR = 2'd3;
    reg [1:0]    state;
    reg [WB-1:0] fill_cnt;

    // ket qua: load trung cache (IDLE) hoac doc ngoai vung cacheable (UNC, luc m_ack); store xong luc m_ack (WR)
    assign ready = (state == IDLE & re & hit) | (state == UNC & m_ack) | (state == WR & m_ack);
    assign rdata = (state == UNC) ? m_rdata : cdata;

    assign m_req   = (state != IDLE);
    assign m_we    = (state == WR);
    assign m_addr  = (state == FILL) ? {w[29:WB], fill_cnt, 2'b00} : {w, 2'b00};
    assign m_wdata = wdata;
    assign m_wstrb = (state == WR) ? wstrb : 4'b1111;

    wire [31:0] wmask = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            fill_cnt <= {WB{1'b0}};
            n_miss   <= 32'd0;
            for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (we) state <= WR;
                    else if (re & ~hit) begin
                        if (cacheable) begin
                            state      <= FILL;
                            fill_cnt   <= {WB{1'b0}};
                            val_r[idx] <= 1'b0;                  // dong cu bi thay
                            n_miss     <= n_miss + 32'd1;
                        end else
                            state <= UNC;
                    end
                end
                FILL: if (m_ack) begin
                    mem_r[{idx, fill_cnt}] <= m_rdata;
                    fill_cnt <= fill_cnt + 1'b1;
                    if (fill_cnt == {WB{1'b1}}) begin
                        tag_r[idx] <= tg;
                        val_r[idx] <= 1'b1;
                        state <= IDLE;                           // chu ky sau trung cache -> ready
                    end
                end
                UNC: if (m_ack) state <= IDLE;
                WR: if (m_ack) begin
                    if (hit) mem_r[w[IB+WB-1:0]] <= (cdata & ~wmask) | (wdata & wmask);
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
