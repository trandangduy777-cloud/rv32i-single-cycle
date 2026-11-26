// SVA cho rv32_bus_arbiter (bind, khong sua RTL). Ten moi assertion bat dau bang ARB_ de mutate_sva.py biet nhom nao bat duoc.
module sva_arbiter #(parameter MAX_BYPASS = 32, MAX_WAIT = 1024) (
    input logic clk, rst_n,
    input logic i_req, i_ack, d_req, d_we, d_ack, m_req, m_we, m_ack,
    input logic [31:0] i_addr, d_addr, m_addr, d_wdata, m_wdata,
    input logic [3:0]  d_wstrb, m_wstrb,
    input logic [1:0]  own,
    input logic sel_i, sel_d
);
    // khong cap bus cho hai ben cung luc
    ARB_one_ack:    assert property (@(posedge clk) disable iff (!rst_n) !(i_ack && d_ack)) else $error("SVA ARB_one_ack: i_ack va d_ack cung luc");
    ARB_ack_req_i:  assert property (@(posedge clk) disable iff (!rst_n) i_ack |-> i_req) else $error("SVA ARB_ack_req_i: i_ack khi khong co i_req");
    ARB_ack_req_d:  assert property (@(posedge clk) disable iff (!rst_n) d_ack |-> d_req) else $error("SVA ARB_ack_req_d: d_ack khi khong co d_req");
    ARB_ack_needs_mack: assert property (@(posedge clk) disable iff (!rst_n) (i_ack || d_ack) |-> m_ack) else $error("SVA ARB_ack_needs_mack");
    // dia chi / du lieu toi bo nho la cua ben duoc cap
    ARB_addr_i:  assert property (@(posedge clk) disable iff (!rst_n) i_ack |-> (m_addr == i_addr && !m_we && m_wstrb == 4'b1111)) else $error("SVA ARB_addr_i: sai dia chi / we / wstrb khi cap cho cache lenh");
    ARB_addr_d:  assert property (@(posedge clk) disable iff (!rst_n) d_ack |-> (m_addr == d_addr && m_we == d_we && m_wdata == d_wdata && (!d_we || m_wstrb == d_wstrb))) else $error("SVA ARB_addr_d: sai dia chi / du lieu khi cap cho cache du lieu");
    ARB_req_has_src: assert property (@(posedge clk) disable iff (!rst_n) m_req |-> (i_req || d_req)) else $error("SVA ARB_req_has_src: m_req khi khong ben nao yeu cau");
    // giao thuc: da cap thi giu cho toi khi bo nho ack; khong doi chu giua chung
    ARB_hold_own: assert property (@(posedge clk) disable iff (!rst_n) (own != 2'd0 && !m_ack) |=> (own == $past(own))) else $error("SVA ARB_hold_own: doi chu bus khi giao dich chua xong");
    ARB_hold_req: assert property (@(posedge clk) disable iff (!rst_n) (m_req && !m_ack) |=> (m_req && $stable(m_addr) && $stable(m_we))) else $error("SVA ARB_hold_req: m_req/dia chi/we thay doi truoc khi ack");
    // uu tien: khi bus ranh va ca hai cung yeu cau, cache du lieu duoc truoc
    ARB_prio_d: assert property (@(posedge clk) disable iff (!rst_n) (own == 2'd0 && d_req) |-> (sel_d && !sel_i)) else $error("SVA ARB_prio_d: cap cho cache lenh khi cache du lieu dang yeu cau luc ranh");
    // khong doi: cache du lieu cho toi da 1 giao dich cua cache lenh; cache lenh cho toi da MAX_BYPASS giao dich lien tiep cua cache du lieu
    ARB_no_starve_d: assert property (@(posedge clk) disable iff (!rst_n) (d_req && i_ack) |=> !i_ack) else $error("SVA ARB_no_starve_d: cache lenh duoc cap 2 lan lien tiep trong khi cache du lieu dang doi");
    int unsigned cnt_i = 0, max_seen = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_i <= 0;
        else if (i_ack || !i_req) cnt_i <= 0;
        else if (d_ack) begin
            cnt_i <= cnt_i + 1;
            if (cnt_i + 1 > max_seen) max_seen <= cnt_i + 1;
        end
    end
    int unsigned wait_i = 0, wait_d = 0, max_wait_i = 0, max_wait_d = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wait_i <= 0; wait_d <= 0; end
        else begin
            wait_i <= (i_req && !i_ack) ? wait_i + 1 : 0;
            wait_d <= (d_req && !d_ack) ? wait_d + 1 : 0;
            if (wait_i > max_wait_i) max_wait_i <= wait_i;
            if (wait_d > max_wait_d) max_wait_d <= wait_d;
        end
    end
    ARB_i_timeout: assert property (@(posedge clk) disable iff (!rst_n) wait_i <= MAX_WAIT) else $error("SVA ARB_i_timeout: cache lenh doi qua %0d chu ky", MAX_WAIT);
    ARB_d_timeout: assert property (@(posedge clk) disable iff (!rst_n) wait_d <= MAX_WAIT) else $error("SVA ARB_d_timeout: cache du lieu doi qua %0d chu ky", MAX_WAIT);
`ifdef SVA_ARB_FAIRNESS
    // Chi dung khi luu luong cache du lieu do loi that sinh ra (-DSVA_ARB_FAIRNESS): pipeline tu han che so giao dich lien tiep cua cache
    // du lieu. Bo phan xu uu tien co dinh cho cache du lieu nen khong co dam bao cong bang khi cache du lieu bi kich thich
    // vo han (tb_cache_random): khi do cache lenh cho den hang chuc giao dich, chi bi chan boi ARB_i_timeout.
    ARB_no_starve_i: assert property (@(posedge clk) disable iff (!rst_n) cnt_i <= MAX_BYPASS) else $error("SVA ARB_no_starve_i: cache lenh doi qua %0d giao dich cua cache du lieu", MAX_BYPASS);
`endif
    final $display("SVA_STAT arbiter: cache lenh cho toi da %0d giao dich lien tiep cua cache du lieu (gioi han %0d)", max_seen, MAX_BYPASS);
    final $display("SVA_STAT arbiter: doi lau nhat: cache lenh %0d chu ky, cache du lieu %0d chu ky (gioi han %0d)", max_wait_i, max_wait_d, MAX_WAIT);
    // khong rong (non-vacuous): cac tinh huong co that
    cover property (@(posedge clk) disable iff (!rst_n) d_ack);
    cover property (@(posedge clk) disable iff (!rst_n) i_ack);
    cover property (@(posedge clk) disable iff (!rst_n) own == 2'd0 && d_req && i_req);
    cover property (@(posedge clk) disable iff (!rst_n) i_req && !i_ack && d_ack);
    cover property (@(posedge clk) disable iff (!rst_n) d_req && !d_ack && i_ack);
endmodule

bind rv32_bus_arbiter sva_arbiter u_sva_arb (.clk(clk), .rst_n(rst_n), .i_req(i_req), .i_ack(i_ack), .d_req(d_req), .d_we(d_we), .d_ack(d_ack),
    .m_req(m_req), .m_we(m_we), .m_ack(m_ack), .i_addr(i_addr), .d_addr(d_addr), .m_addr(m_addr), .d_wdata(d_wdata), .m_wdata(m_wdata),
    .d_wstrb(d_wstrb), .m_wstrb(m_wstrb), .own(own), .sel_i(sel_i), .sel_d(sel_d));
