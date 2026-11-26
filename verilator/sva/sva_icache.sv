// SVA cho rv32_icache (bind, khong sua RTL). Ten assertion bat dau bang IC_.
module sva_icache #(parameter LINES = 16, WORDS = 4, WAYS = 1) (
    input logic clk, rst_n,
    input logic [31:0] addr, data, m_addr, m_rdata,
    input logic ready, flush, m_req, m_ack, state, fill_kill,
    input logic [29:0] w0, w1,
    input logic need1,
    input logic [$clog2(LINES / WAYS) > 0 ? $clog2(LINES / WAYS) - 1 : 0:0] fill_set,
    input logic [$clog2(WAYS > 1 ? WAYS : 2)-1:0] fill_way,
    input logic [$clog2(WORDS)-1:0] fill_cnt,
    input logic [30 - $clog2(LINES / WAYS) - $clog2(WORDS) - 1:0] tag_r [0:LINES-1],
    input logic val_r [0:LINES-1]
);
    localparam SETS = LINES / WAYS;
    genvar gs, ga, gb;
    generate
        for (gs = 0; gs < SETS; gs = gs + 1) begin : g_set
            for (ga = 0; ga < WAYS; ga = ga + 1) begin : g_a
                for (gb = ga + 1; gb < WAYS; gb = gb + 1) begin : g_b
                    IC_uniq_tag: assert property (@(posedge clk) disable iff (!rst_n)
                        !(val_r[gs * WAYS + ga] && val_r[gs * WAYS + gb] && tag_r[gs * WAYS + ga] == tag_r[gs * WAYS + gb]))
                        else $error("SVA IC_uniq_tag: tap %0d co 2 duong hop le cung tag", gs);
                end
            end
        end
    endgenerate
    // bo nho bong: moi tu nap qua bus duoc ghi nho; khi cache bao ready, lenh tra ve phai bang tu da nap (cat theo addr[1])
    logic [31:0] shadow [bit [29:0]];
    always @(posedge clk) if (rst_n && m_req && m_ack) shadow[m_addr[31:2]] = m_rdata;
    IC_data_correct: assert property (@(posedge clk) disable iff (!rst_n)
        (ready && shadow.exists(w0) && (!need1 || shadow.exists(w1)))
        |-> (data == (need1 ? {shadow[w1][15:0], shadow[w0][31:16]} : shadow[w0])))
        else $error("SVA IC_data_correct: lenh tra ve khac tu da nap: %08x", data);
    // flush: ngay chu ky sau khong con dong hop le nao (ke ca dong dang nap do co fill_kill)
    logic any_val;
    always @* begin any_val = 1'b0; for (int k = 0; k < LINES; k++) any_val |= val_r[k]; end
    IC_flush_inval: assert property (@(posedge clk) disable iff (!rst_n) flush |=> !any_val)
        else $error("SVA IC_flush_inval: flush xong van con dong hop le");
    // nap xong dong: dong hop le tru khi co flush trong luc nap
    IC_fill_valid: assert property (@(posedge clk) disable iff (!rst_n)
        (state && m_ack && fill_cnt == {$clog2(WORDS){1'b1}} && !fill_kill && !flush) |=> val_r[$past(fill_set) * WAYS + $past(fill_way)])
        else $error("SVA IC_fill_valid: nap xong dong nhung khong danh dau hop le");
    IC_fill_killed: assert property (@(posedge clk) disable iff (!rst_n)
        (state && m_ack && fill_cnt == {$clog2(WORDS){1'b1}} && (fill_kill || flush)) |=> !val_r[$past(fill_set) * WAYS + $past(fill_way)])
        else $error("SVA IC_fill_killed: dong nap trong luc flush van hop le (lenh cu co the xuat hien lai)");
    IC_bus_hold: assert property (@(posedge clk) disable iff (!rst_n) (m_req && !m_ack) |=> (m_req && $stable(m_addr)))
        else $error("SVA IC_bus_hold: yeu cau bus thay doi truoc khi ack");
    IC_no_ready_in_fill: assert property (@(posedge clk) disable iff (!rst_n) state |-> !ready)
        else $error("SVA IC_no_ready_in_fill: ready trong luc nap");
    cover property (@(posedge clk) disable iff (!rst_n) ready && need1);
    cover property (@(posedge clk) disable iff (!rst_n) flush && state);
    cover property (@(posedge clk) disable iff (!rst_n) flush);
    cover property (@(posedge clk) disable iff (!rst_n) state && m_ack && fill_cnt == {$clog2(WORDS){1'b1}});
endmodule

bind rv32_icache sva_icache #(.LINES(LINES), .WORDS(WORDS), .WAYS(WAYS)) u_sva_ic (
    .clk(clk), .rst_n(rst_n), .addr(addr), .data(data), .m_addr(m_addr), .m_rdata(m_rdata), .ready(ready), .flush(flush),
    .m_req(m_req), .m_ack(m_ack), .state(state), .fill_kill(fill_kill), .w0(w0), .w1(w1), .need1(need1), .fill_set(fill_set),
    .fill_way(fill_way), .fill_cnt(fill_cnt), .tag_r(tag_r), .val_r(val_r));
