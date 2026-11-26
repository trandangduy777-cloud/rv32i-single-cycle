// SVA cho rv32_dcache (bind, khong sua RTL). Mo hinh tham chieu nho nam trong checker: bo dem ghi bong (FIFO) va bo nho kien truc
// cua cac tu dang co trong cache (amem). Ten assertion bat dau bang DC_.
module sva_dcache #(parameter LINES = 16, WORDS = 4, WAYS = 1, WBUF = 4, QB = 2, parameter [31:0] CMASK = 0, CBASE = 0) (
    input logic clk, rst_n,
    input logic [31:0] addr, wdata, rdata, m_addr, m_wdata, m_rdata, fill_data,
    input logic re, we, fence, ready, wb_empty, m_req, m_we, m_ack, hit, free, push, pop, ld_hit, cacheable, fill_fwd,
    input logic [3:0] wstrb, m_wstrb,
    input logic [1:0] state,
    input logic [$clog2(WORDS)-1:0] fill_cnt,
    input logic [$clog2(WAYS > 1 ? WAYS : 2)-1:0] fill_way,
    input logic [QB:0] q_cnt,
    input logic q_full,
    input logic [29:0] fill_w,
    input logic [30 - $clog2(LINES / WAYS) - $clog2(WORDS) - 1:0] tag_r [0:LINES-1],
    input logic val_r [0:LINES-1]
);
    localparam IDLE = 2'd0, FILL = 2'd1, UNC = 2'd2, DRN = 2'd3;
    localparam SETS = LINES / WAYS;

    // ---- (1) valid / tag nhat quan: trong mot tap khong co 2 duong hop le cung tag ----
    genvar gs, ga, gb;
    generate
        for (gs = 0; gs < SETS; gs = gs + 1) begin : g_set
            for (ga = 0; ga < WAYS; ga = ga + 1) begin : g_a
                for (gb = ga + 1; gb < WAYS; gb = gb + 1) begin : g_b
                    DC_uniq_tag: assert property (@(posedge clk) disable iff (!rst_n)
                        !(val_r[gs * WAYS + ga] && val_r[gs * WAYS + gb] && tag_r[gs * WAYS + ga] == tag_r[gs * WAYS + gb]))
                        else $error("SVA DC_uniq_tag: tap %0d co 2 duong hop le cung tag", gs);
                end
            end
        end
    endgenerate

    // ---- (2) khong tra du lieu khi miss: load xong tu cache chi khi trung (IDLE / DRN) hoac doc ngoai vung o UNC voi ack ----
    DC_no_data_on_miss: assert property (@(posedge clk) disable iff (!rst_n)
        (re && !we && !fence && ready) |-> ((free && hit) || (state == UNC && m_ack)))
        else $error("SVA DC_no_data_on_miss: load bao ready khi khong trung cache va khong phai doc ngoai vung");
    DC_no_ready_in_fill: assert property (@(posedge clk) disable iff (!rst_n) (state == FILL) |-> !ready)
        else $error("SVA DC_no_ready_in_fill: ready trong luc dang nap dong");

    // ---- (3) bo dem ghi: FIFO bong ----
    logic [29:0] sq_a [0:WBUF-1];
    logic [31:0] sq_d [0:WBUF-1];
    logic [3:0]  sq_s [0:WBUF-1];
    int unsigned sq_n, sq_h, sq_t;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sq_n <= 0; sq_h <= 0; sq_t <= 0; end
        else begin
            if (push) begin sq_a[sq_t] <= addr[31:2]; sq_d[sq_t] <= wdata; sq_s[sq_t] <= wstrb; sq_t <= (sq_t + 1) % WBUF; end
            if (pop)  sq_h <= (sq_h + 1) % WBUF;
            sq_n <= sq_n + (push ? 1 : 0) - (pop ? 1 : 0);
        end
    end
    // thu tu ghi ra bus: dung muc dau cua FIFO (dia chi, du lieu, wstrb)
    DC_wb_order: assert property (@(posedge clk) disable iff (!rst_n)
        pop |-> (sq_n > 0 && m_addr[31:2] == sq_a[sq_h] && m_wdata == sq_d[sq_h] && m_wstrb == sq_s[sq_h]))
        else $error("SVA DC_wb_order: bo dem ghi khong ghi ra bus dung muc dau (sai thu tu / dia chi / du lieu / wstrb)");
    DC_wb_count: assert property (@(posedge clk) disable iff (!rst_n) (q_cnt == sq_n))
        else $error("SVA DC_wb_count: so muc bo dem ghi lech voi mo hinh (%0d vs %0d)", q_cnt, sq_n);
    DC_wb_nofull_push: assert property (@(posedge clk) disable iff (!rst_n) push |-> sq_n < WBUF)
        else $error("SVA DC_wb_nofull_push: nhan store khi bo dem day");
    // bat bien: con du lieu trong bo dem thi cache khong o IDLE (bo phan xu khong duoc cap bus cho cache lenh truoc khi ghi het)
    DC_wb_busy: assert property (@(posedge clk) disable iff (!rst_n) (sq_n > 0) |-> (state != IDLE))
        else $error("SVA DC_wb_busy: bo dem con du lieu nhung cache o IDLE");
    DC_fence_empty: assert property (@(posedge clk) disable iff (!rst_n) (fence && ready) |-> (sq_n == 0))
        else $error("SVA DC_fence_empty: FENCE xong khi bo dem ghi chua rong");

    // ---- (4) forward dung: du lieu nap = tu bo nho, tron lan luot cac store trong bo dem co cung dia chi (cu -> moi) ----
    logic [31:0] exp_fill;
    always @* begin
        exp_fill = m_rdata;
        for (int j = 0; j < WBUF; j++)
            if (j < sq_n && sq_a[(sq_h + j) % WBUF] == fill_w)
                exp_fill = (exp_fill & ~{{8{sq_s[(sq_h + j) % WBUF][3]}}, {8{sq_s[(sq_h + j) % WBUF][2]}}, {8{sq_s[(sq_h + j) % WBUF][1]}}, {8{sq_s[(sq_h + j) % WBUF][0]}}})
                         | (sq_d[(sq_h + j) % WBUF] & {{8{sq_s[(sq_h + j) % WBUF][3]}}, {8{sq_s[(sq_h + j) % WBUF][2]}}, {8{sq_s[(sq_h + j) % WBUF][1]}}, {8{sq_s[(sq_h + j) % WBUF][0]}}});
    end
    DC_fwd_data: assert property (@(posedge clk) disable iff (!rst_n) (state == FILL && m_ack) |-> (fill_data == exp_fill))
        else $error("SVA DC_fwd_data: du lieu nap dong khong khop (bo nho tron cac store cho trong bo dem): %08x vs %08x", fill_data, exp_fill);

    // ---- (5) load trung tra dung gia tri kien truc (amem: tu da nap + cac store trung) ----
    logic [31:0] amem [bit [29:0]];
    always @(posedge clk) begin
        if (rst_n) begin
            if (state == FILL && m_ack) amem[fill_w] = exp_fill;
            if (push && hit && amem.exists(addr[31:2])) begin
                amem[addr[31:2]] = (amem[addr[31:2]] & ~{{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}})
                                 | (wdata & {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}});
            end
        end
    end
    DC_load_data: assert property (@(posedge clk) disable iff (!rst_n)
        (ld_hit && ready && amem.exists(addr[31:2])) |-> (rdata == amem[addr[31:2]]))
        else $error("SVA DC_load_data: load trung tra sai gia tri: %08x vs %08x", rdata, amem[addr[31:2]]);

    // ---- (6) giao thuc bus: giu yeu cau va dia chi cho toi khi ack ----
    DC_bus_hold: assert property (@(posedge clk) disable iff (!rst_n) (m_req && !m_ack) |=> (m_req && $stable(m_addr) && $stable(m_we)))
        else $error("SVA DC_bus_hold: yeu cau bus thay doi truoc khi ack");
    DC_store_no_bus_read: assert property (@(posedge clk) disable iff (!rst_n) (m_req && m_we) |-> (state == DRN))
        else $error("SVA DC_store_no_bus_read: ghi bus ngoai trang thai DRN");

    // non-vacuous
    cover property (@(posedge clk) disable iff (!rst_n) ld_hit && ready);
    cover property (@(posedge clk) disable iff (!rst_n) state == FILL && m_ack && fill_fwd);
    cover property (@(posedge clk) disable iff (!rst_n) pop && sq_n > 1);
    cover property (@(posedge clk) disable iff (!rst_n) push && hit);
    cover property (@(posedge clk) disable iff (!rst_n) state == UNC && m_ack);
    cover property (@(posedge clk) disable iff (!rst_n) fence && ready);
    cover property (@(posedge clk) disable iff (!rst_n) we && q_full);
endmodule

bind rv32_dcache sva_dcache #(.LINES(LINES), .WORDS(WORDS), .WAYS(WAYS), .WBUF(WBUF), .QB(QB), .CMASK(CMASK), .CBASE(CBASE)) u_sva_dc (
    .clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata), .rdata(rdata), .m_addr(m_addr), .m_wdata(m_wdata), .m_rdata(m_rdata),
    .fill_data(fill_data), .re(re), .we(we), .fence(fence), .ready(ready), .wb_empty(wb_empty), .m_req(m_req), .m_we(m_we), .m_ack(m_ack),
    .hit(hit), .free(free), .push(push), .pop(pop), .ld_hit(ld_hit), .cacheable(cacheable), .fill_fwd(fill_fwd), .wstrb(wstrb), .m_wstrb(m_wstrb),
    .state(state), .fill_cnt(fill_cnt), .fill_way(fill_way), .q_cnt(q_cnt), .q_full(q_full), .fill_w(fill_w), .tag_r(tag_r), .val_r(val_r));
