`timescale 1ns/1ps
// Test rieng cho soc_plic voi S_CTX = 1 (hai context M va S): thanh ghi ENABLE / THRESHOLD / CLAIM cua context S theo bo cuc chuan, hai context
// doc lap, claim o context nao thi nguon dang xu ly cho toi khi complete o context do (complete chi hop le neu nguon duoc enable o context do),
// claim cua context nay khong lam mat nguon cua context kia khi nguon da bi nhan; roi 80000 chu ky ngau nhien so voi mo hinh doc lap.
module tb_plic_s;
    localparam N = 9;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg sel = 0, we = 0, re = 0; reg [21:2] addr = 0; reg [3:0] wstrb = 0; reg [31:0] wdata = 0;
    wire [31:0] rdata; reg [N:1] src = 0; wire eip, eip_s;
    integer errors = 0;
    soc_plic #(.NSRC(N), .PRIO_W(3), .S_CTX(1)) dut (.clk(clk), .rst_n(rst_n), .sel(sel), .addr(addr), .we(we), .re(re), .wstrb(wstrb),
                                                     .wdata(wdata), .rdata(rdata), .src(src), .eip(eip), .eip_s(eip_s));
    localparam [21:2] A_EN_M = 20'h00800, A_EN_S = 20'h00820, A_THR_M = 20'h80000, A_CC_M = 20'h80001, A_THR_S = 20'h80400, A_CC_S = 20'h80401;
    task wr(input [21:2] a, input [31:0] d, input [3:0] s);
        begin @(negedge clk); sel = 1; we = 1; re = 0; addr = a; wdata = d; wstrb = s; @(negedge clk); sel = 0; we = 0; wstrb = 0; end
    endtask
    task rd(input [21:2] a, output [31:0] d);
        begin @(negedge clk); sel = 1; re = 1; we = 0; addr = a; #1 d = rdata; @(negedge clk); sel = 0; re = 0; end
    endtask
    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin errors = errors + 1; $display("[PLIC_S] LOI %0s: %h, mong doi %h", what, got, want); end
    endtask

    // ---- mo hinh doc lap ----
    integer m_prio [0:N]; integer m_thr [0:1]; reg [N:0] m_en [0:1]; reg [N:0] m_pend, m_infl;
    function integer m_best(input integer c);
        integer q, bp, bi;
        begin bi = 0; bp = 0;
            for (q = 1; q <= N; q = q + 1)
                if (m_pend[q] && m_en[c][q] && m_prio[q] > m_thr[c] && m_prio[q] > bp) begin bp = m_prio[q]; bi = q; end
            m_best = bi; end
    endfunction
    integer q2, seed, k, c, op, id, claim_id, compl_id, nprio, nid, nen0, nen1, nthr0, nthr1; reg [31:0] v; reg [N:1] s_prev;
    initial begin
        seed = 7; k = $urandom(seed);
        for (q2 = 0; q2 <= N; q2 = q2 + 1) m_prio[q2] = 0;
        m_thr[0] = 0; m_thr[1] = 0; m_en[0] = 0; m_en[1] = 0; m_pend = 0; m_infl = 0;
        repeat (3) @(negedge clk); rst_n = 1;
        // ---- test co huong ----
        wr(20'd2, 3, 4'b0001); wr(20'd5, 5, 4'b0001); wr(20'd1, 1, 4'b0001);              // prio[2]=3 prio[5]=5 prio[1]=1
        wr(A_EN_S, 32'h0000_0024, 4'b1111);                                                // context S: nguon 2 va 5
        rd(A_EN_S, v); check("en_s", v, 32'h24);
        rd(A_EN_M, v); check("en_m van 0", v, 0);
        src[2] = 1; src[5] = 1; repeat (3) @(negedge clk);
        check("eip_s", eip_s, 1); check("eip m = 0 (chua enable)", eip, 0);
        rd(A_CC_S, v); check("claim s = 5", v, 5);
        rd(A_CC_S, v); check("claim s lan 2 = 2", v, 2);
        rd(A_CC_S, v); check("claim s het = 0", v, 0);
        wr(A_CC_M, 5, 4'b0001);                                                            // complete tu context M: nguon 5 khong enable o M -> bo qua
        src[5] = 0; repeat (2) @(negedge clk); src[5] = 1; repeat (3) @(negedge clk);
        rd(A_CC_S, v); check("5 van dang xu ly (complete sai context bi bo)", v, 0);
        wr(A_CC_S, 5, 4'b0001); src[5] = 0; repeat (2) @(negedge clk); src[5] = 1; repeat (3) @(negedge clk);
        rd(A_CC_S, v); check("sau complete dung context: 5 ve lai", v, 5);
        wr(A_THR_S, 4, 4'b0001); rd(A_THR_S, v); check("thr_s", v, 4);
        wr(A_CC_S, 5, 4'b0001); src = 0; repeat (3) @(negedge clk);
        rd(A_THR_M, v); check("thr_m van 0", v, 0);
        // ---- ngau nhien so voi mo hinh ----
        for (q2 = 1; q2 <= N; q2 = q2 + 1) begin wr(q2, 0, 4'b0001); m_prio[q2] = 0; end
        wr(A_THR_S, 0, 4'b0001); wr(A_EN_S, 0, 4'b1111); wr(A_EN_M, 0, 4'b1111); wr(A_THR_M, 0, 4'b0001);
        src = 0; m_pend = 0; m_infl = 0; m_en[0] = 0; m_en[1] = 0; m_thr[0] = 0; m_thr[1] = 0;
        repeat (4) @(negedge clk); m_pend = 0; m_infl = 0;   // dong bo mo hinh sau cac complete con lai
        s_prev = 0;
        for (k = 0; k < 80000; k = k + 1) begin
            op = $urandom % 16;
            @(negedge clk);
            #1 check("eip", eip, m_best(0) != 0); check("eip_s", eip_s, m_best(1) != 0);   // trang thai sau posedge truoc
            sel = 0; we = 0; re = 0;
            claim_id = 0; compl_id = 0; nprio = -1; nid = 0; nen0 = -1; nen1 = -1; nthr0 = -1; nthr1 = -1;
            case (op)
                0, 1, 2, 3: src[1 + ($urandom % N)] = $urandom;
                4: begin nid = 1 + ($urandom % N); v = $urandom % 8; addr = nid; wdata = v; wstrb = 4'b0001; sel = 1; we = 1; nprio = v; end
                5: begin v = $urandom; addr = A_EN_M; wdata = v; wstrb = 4'b1111; sel = 1; we = 1; nen0 = {v[N:1], 1'b0}; end
                6: begin v = $urandom; addr = A_EN_S; wdata = v; wstrb = 4'b1111; sel = 1; we = 1; nen1 = {v[N:1], 1'b0}; end
                7: begin v = $urandom % 8; addr = A_THR_M; wdata = v; wstrb = 4'b0001; sel = 1; we = 1; nthr0 = v; end
                8: begin v = $urandom % 8; addr = A_THR_S; wdata = v; wstrb = 4'b0001; sel = 1; we = 1; nthr1 = v; end
                9, 10: begin
                    c = op - 9; addr = c ? A_CC_S : A_CC_M; sel = 1; re = 1; #1;
                    claim_id = m_best(c); check("claim", rdata, claim_id);
                end
                11, 12, 13: begin
                    c = op - 11; if (c == 2) c = $urandom % 2; id = $urandom % (N + 1);
                    addr = c ? A_CC_S : A_CC_M; wdata = id; wstrb = 4'b0001; sel = 1; we = 1;
                    if (id >= 1 && id <= N && m_en[c][id] && m_infl[id]) compl_id = id;
                end
                default: ;
            endcase
            // cap nhat mo hinh cho posedge sap toi: cong nguon dung src moi, claim / complete dung trang thai cu
            for (q2 = 1; q2 <= N; q2 = q2 + 1) begin
                if (claim_id == q2) begin m_pend[q2] = 0; m_infl[q2] = 1; end
                else begin
                    if (src[q2] && !m_infl[q2] && !m_pend[q2]) m_pend[q2] = 1;
                    if (compl_id == q2) m_infl[q2] = 0;
                end
            end
            if (nprio >= 0) m_prio[nid] = nprio;
            if (nen0 >= 0) m_en[0] = nen0; if (nen1 >= 0) m_en[1] = nen1;
            if (nthr0 >= 0) m_thr[0] = nthr0; if (nthr1 >= 0) m_thr[1] = nthr1;
        end
        sel = 0; we = 0; re = 0;
        if (errors == 0) $display("[PLIC_S] PASS hai context, 80000 chu ky ngau nhien khop mo hinh"); else $display("[PLIC_S] FAIL %0d loi", errors);
        $finish;
    end
endmodule
