`timescale 1ns/1ps
// Test rieng cho soc_plic (NSRC = 7, PRIO_W = 3): thanh ghi, uu tien, hoa (ID nho nhat), threshold, claim/complete, nhieu nguon cung luc,
// ngat muc (gateway), cac truong hop complete bi bo qua, ghi theo byte-lane, doc claim khong co re; roi 60000 chu ky ngau nhien so voi mo hinh
// viet doc lap trong testbench.
module tb_plic;
    localparam N = 7;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg sel = 0, we = 0, re = 0; reg [21:2] addr = 0; reg [3:0] wstrb = 0; reg [31:0] wdata = 0;
    wire [31:0] rdata; reg [N:1] src = 0; wire eip;
    integer errors = 0;
    soc_plic #(.NSRC(N), .PRIO_W(3)) dut (.clk(clk), .rst_n(rst_n), .sel(sel), .addr(addr), .we(we), .re(re), .wstrb(wstrb),
                                          .wdata(wdata), .rdata(rdata), .src(src), .eip(eip));
    localparam [21:2] A_PEND = 20'h00400, A_EN = 20'h00800, A_THR = 20'h80000, A_CC = 20'h80001;
    function [21:2] a_prio(input integer i); a_prio = i; endfunction

    task wr(input [21:2] a, input [31:0] d, input [3:0] s);
        begin @(negedge clk); sel = 1; we = 1; re = 0; addr = a; wdata = d; wstrb = s; @(negedge clk); sel = 0; we = 0; wstrb = 0; end
    endtask
    task rd(input [21:2] a, output [31:0] d);                      // doc co re (claim co tac dung phu)
        begin @(negedge clk); sel = 1; re = 1; we = 0; addr = a; #1 d = rdata; @(negedge clk); sel = 0; re = 0; end
    endtask
    task peek(input [21:2] a, output [31:0] d);                    // doc khong re (khong co tac dung phu)
        begin @(negedge clk); sel = 1; re = 0; we = 0; addr = a; #1 d = rdata; @(negedge clk); sel = 0; end
    endtask
    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin errors = errors + 1; $display("[PLIC] LOI %0s: %h, mong doi %h", what, got, want); end
    endtask
    task setp(input integer i, input integer p); wr(a_prio(i), p, 4'b0001); endtask

    reg [31:0] v; integer k;
    // ---- mo hinh doc lap (cho phan ngau nhien); chay song song, chi duoc so sanh khi rand_on = 1 ----
    reg rand_on = 0;
    integer m_prio [0:N]; integer m_thr; reg [N:0] m_en, m_pend, m_infl;
    function integer m_best(input integer dummy);
        integer q, bp, bi;
        begin
            bi = 0; bp = 0;
            for (q = 1; q <= N; q = q + 1)
                if (m_pend[q] && m_en[q] && m_prio[q] > m_thr && m_prio[q] > bp) begin bp = m_prio[q]; bi = q; end
            m_best = bi;
        end
    endfunction
    integer mb, q2;
    reg m_claim, m_comp; integer m_id;
    always @(posedge clk) if (!rst_n) begin
        for (q2 = 0; q2 <= N; q2 = q2 + 1) m_prio[q2] = 0;
        m_thr = 0; m_en = 0; m_pend = 0; m_infl = 0;
    end else begin
        mb = m_best(0);
        if (rand_on) begin
            check("eip == mo hinh", eip, (mb != 0));
            if (sel && !we && addr == A_CC)   check("claim == mo hinh", rdata, mb);
            if (sel && !we && addr == A_PEND) check("pending == mo hinh", rdata, m_pend);
            if (sel && !we && addr == A_EN)   check("enable == mo hinh", rdata, m_en);
            if (sel && !we && addr == A_THR)  check("thr == mo hinh", rdata, m_thr);
            if (sel && !we && addr >= 20'd1 && addr <= N) check("prio == mo hinh", rdata, m_prio[addr]);
        end
        m_claim = sel && re && addr == A_CC;
        m_comp = sel && we && addr == A_CC && wstrb[0];
        m_id = wdata[7:0];
        // thu tu: claim thang cong; cong nguon dung trang thai cu
        for (q2 = 1; q2 <= N; q2 = q2 + 1) begin
            if (m_claim && mb == q2) begin m_pend[q2] = 0; m_infl[q2] = 1; end
            else begin
                if (src[q2] && !m_infl[q2] && !m_pend[q2]) m_pend[q2] = 1;
                if (m_comp && m_id == q2 && m_en[q2] && m_infl[q2]) m_infl[q2] = 0;
            end
        end
        if (sel && we && addr >= 20'd1 && addr <= N && wstrb[0]) m_prio[addr] = wdata[2:0];
        if (sel && we && addr == A_EN) begin
            for (q2 = 1; q2 <= N; q2 = q2 + 1) if (wstrb[q2 / 8]) m_en[q2] = wdata[q2];
        end
        if (sel && we && addr == A_THR && wstrb[0]) m_thr = wdata[2:0];
    end
    integer r, op;
    initial begin
        for (k = 0; k <= N; k = k + 1) m_prio[k] = 0;
        m_thr = 0; m_en = 0; m_pend = 0; m_infl = 0;
        repeat (3) @(posedge clk); #1 rst_n = 1;
        // ---- reset ----
        peek(A_PEND, v); check("pending luc reset", v, 0); peek(A_EN, v); check("enable luc reset", v, 0);
        peek(A_THR, v); check("threshold luc reset", v, 0); peek(A_CC, v); check("claim luc reset", v, 0); check("eip luc reset", eip, 0);
        // ---- thanh ghi uu tien: 3 bit, nguon 0 va nguon > N khong ton tai ----
        for (k = 1; k <= N; k = k + 1) begin setp(k, 8'hFF); peek(a_prio(k), v); check("prio mask 3 bit", v, 7); setp(k, k % 8); end
        for (k = 1; k <= N; k = k + 1) begin peek(a_prio(k), v); check("prio doc lai", v, k % 8); end
        wr(a_prio(0), 7, 4'hF); peek(a_prio(0), v); check("prio[0] doc 0", v, 0);
        wr(a_prio(N + 1), 7, 4'hF); peek(a_prio(N + 1), v); check("prio[N+1] doc 0", v, 0);
        wr(a_prio(1023), 7, 4'hF); peek(a_prio(1023), v); check("prio[1023] doc 0", v, 0);
        for (k = 1; k <= N; k = k + 1) setp(k, 0);
        // ---- enable: bit 0 va bit > N doc 0, ghi theo byte-lane ----
        wr(A_EN, 32'hFFFF_FFFF, 4'hF); peek(A_EN, v); check("enable chi bit 1..N", v, 32'h0000_00FE);
        wr(A_EN, 32'h0, 4'b0010); peek(A_EN, v); check("ghi byte 1 khong dung byte 0", v, 32'h0000_00FE);
        wr(A_EN, 32'h0, 4'b0001); peek(A_EN, v); check("ghi byte 0", v, 0);
        // ---- mot nguon, muc: pending, claim, in-flight, complete, nguon van cao -> yeu cau moi ----
        setp(3, 1); wr(A_EN, 32'h8, 4'hF);
        check("chua co nguon: eip=0", eip, 0);
        src[3] = 1; repeat (3) @(posedge clk); #1;
        peek(A_PEND, v); check("pending bit 3", v, 32'h8); check("eip=1", eip, 1);
        peek(A_CC, v); check("peek claim = 3 (khong claim)", v, 3); peek(A_PEND, v); check("peek khong doi pending", v, 32'h8);
        rd(A_CC, v); check("claim = 3", v, 3); repeat (2) @(posedge clk); #1;
        peek(A_PEND, v); check("claim xoa pending", v, 0); check("eip=0 sau claim (nguon cao nhung dang xu ly)", eip, 0);
        peek(A_CC, v); check("claim lai = 0", v, 0);
        wr(A_CC, 3, 4'hF); repeat (3) @(posedge clk); #1;
        peek(A_PEND, v); check("complete + nguon van cao: pending lai", v, 32'h8); check("eip lai", eip, 1);
        rd(A_CC, v); check("claim 3 lan 2", v, 3); src[3] = 0; wr(A_CC, 3, 4'hF); repeat (3) @(posedge clk); #1;
        peek(A_PEND, v); check("nguon ha thap truoc complete: khong pending", v, 0); check("eip=0", eip, 0);
        // ---- uu tien va hoa ----
        for (k = 1; k <= N; k = k + 1) setp(k, 0);
        setp(2, 2); setp(3, 6); setp(5, 6); setp(6, 4); wr(A_EN, 32'hFE, 4'hF);
        src[2] = 1; src[3] = 1; src[5] = 1; src[6] = 1; src[4] = 1; src[7] = 1; repeat (3) @(posedge clk); #1;      // 4 va 7 co uu tien 0
        peek(A_PEND, v); check("pending 2,3,4,5,6,7", v, 32'hFC);
        rd(A_CC, v); check("claim 1: uu tien cao nhat, hoa -> ID nho (3)", v, 3);
        rd(A_CC, v); check("claim 2: 5", v, 5);
        rd(A_CC, v); check("claim 3: 6 (uu tien 4)", v, 6);
        rd(A_CC, v); check("claim 4: 2 (uu tien 2)", v, 2);
        rd(A_CC, v); check("claim 5: 0 (4 va 7 co uu tien 0)", v, 0); check("eip=0", eip, 0);
        // don dep: ha nguon, nang uu tien 4 va 7 de claim het pending cua chung, complete tat ca, tra uu tien ve 0
        src = 0; setp(4, 1); setp(7, 1); rd(A_CC, v); check("don dep claim 4", v, 4); rd(A_CC, v); check("don dep claim 7", v, 7);
        wr(A_CC, 3, 4'hF); wr(A_CC, 5, 4'hF); wr(A_CC, 6, 4'hF); wr(A_CC, 2, 4'hF); wr(A_CC, 4, 4'hF); wr(A_CC, 7, 4'hF);
        setp(4, 0); setp(7, 0); repeat (3) @(posedge clk); #1; peek(A_PEND, v); check("sau don dep khong con pending", v, 0);
        // ---- complete bi bo qua ----
        wr(A_CC, 0, 4'hF); wr(A_CC, N + 1, 4'hF); wr(A_CC, 255, 4'hF); wr(A_CC, 4, 4'hF);                       // ID 0, ngoai tam, khong in-flight
        wr(A_CC, 3, 4'b0010);                                                                                        // khong co wstrb[0]
        src = 0; repeat (3) @(posedge clk); #1;
        src[3] = 1; repeat (3) @(posedge clk); #1; check("nguon 3 len cao: pending", eip, 1);
        rd(A_CC, v); check("claim 3", v, 3); repeat (2) @(posedge clk); #1; check("3 dang in-flight: khong pending du nguon cao", eip, 0);
        wr(A_CC, 3, 4'b0010); wr(A_CC, 4, 4'hF); wr(A_CC, 0, 4'hF); wr(A_CC, N + 1, 4'hF); repeat (2) @(posedge clk); #1;
        check("complete sai/bo qua khong giai phong 3", eip, 0);
        wr(A_CC, 3, 4'hF); repeat (3) @(posedge clk); #1; check("complete 3 -> pending lai", eip, 1);
        rd(A_CC, v); check("claim 3 lan nua", v, 3);
        wr(A_EN, 32'hF6, 4'hF);                                                                                      // tat enable nguon 3
        wr(A_CC, 3, 4'hF); repeat (3) @(posedge clk); #1; check("complete bi bo qua khi nguon khong enable", eip, 0);
        peek(A_PEND, v); check("khong pending", v, 0);
        wr(A_EN, 32'hFE, 4'hF); wr(A_CC, 3, 4'hF); repeat (3) @(posedge clk); #1; check("enable lai + complete", eip, 1);
        rd(A_CC, v); wr(A_CC, 3, 4'hF); src = 0; repeat (4) @(posedge clk); #1;
        rd(A_CC, v); check("het nguon: claim 0 (nguon da ha, da hoan thanh)", v, 0);
        // ---- threshold ----
        for (k = 1; k <= N; k = k + 1) setp(k, 0);
        setp(1, 3); setp(2, 5); wr(A_EN, 32'hFE, 4'hF); src[1] = 1; src[2] = 1; repeat (3) @(posedge clk); #1;
        wr(A_THR, 3, 4'hF); peek(A_THR, v); check("thr doc lai", v, 3); #1; check("thr=3: nguon 2 (uu tien 5) qua", eip, 1);
        peek(A_CC, v); check("claim theo threshold: 2", v, 2);
        wr(A_THR, 5, 4'hF); #1; check("thr=5: uu tien 5 khong du (phai > thr)", eip, 0); peek(A_CC, v); check("claim = 0", v, 0);
        wr(A_THR, 8'hFF, 4'hF); peek(A_THR, v); check("thr mask 3 bit", v, 7);
        wr(A_THR, 4, 4'hF); #1; check("thr=4: nguon 2 qua", eip, 1);
        wr(A_THR, 7, 4'b1110); peek(A_THR, v); check("ghi thr khong co byte 0: bo qua", v, 4);
        wr(a_prio(2), 1, 4'b1110); peek(a_prio(2), v); check("ghi prio khong co byte 0: bo qua", v, 5);
        wr(A_THR, 0, 4'hF);
        rd(A_CC, v); check("claim 2", v, 2); rd(A_CC, v); check("claim 1", v, 1); wr(A_CC, 1, 4'hF); wr(A_CC, 2, 4'hF); src = 0;
        repeat (4) @(posedge clk); #1; rd(A_CC, v);
        // ---- nguon pending khi bi tat enable: khong ngat, bat lai thi ngat ----
        wr(A_EN, 0, 4'hF); src[4] = 1; setp(4, 2); repeat (3) @(posedge clk); #1;
        peek(A_PEND, v); check("pending du nguon bi tat", v, 32'h10); check("eip=0 khi tat", eip, 0);
        wr(A_EN, 32'h10, 4'hF); #1; check("bat enable -> eip", eip, 1);
        // nguon ha truoc claim: pending giu nguyen (dac ta), claim van tra ID
        src[4] = 0; repeat (2) @(posedge clk); #1; check("pending giu khi nguon ha", eip, 1);
        rd(A_CC, v); check("claim sau khi nguon ha", v, 4); wr(A_CC, 4, 4'hF); repeat (3) @(posedge clk); #1; check("khong pending lai", eip, 0);
        // ---- vung dia chi ngoai danh sach ----
        peek(20'h01234, v); check("dia chi la doc 0", v, 0); peek(20'h00401, v); check("pending cao doc 0", v, 0);
        wr(20'h00400, 32'hFFFF, 4'hF); peek(A_PEND, v); check("pending la RO", v, 0);
        // ---- ngau nhien so voi mo hinh ----
        rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1; src = 0; rand_on = 1;
        for (r = 0; r < 60000; r = r + 1) begin
            @(negedge clk);
            sel = 0; we = 0; re = 0; wstrb = 4'hF;
            if ($urandom % 3 == 0) src = src ^ (1 << ($urandom % N)) ;
            if ($urandom % 11 == 0) src = $urandom;
            op = $urandom % 12;
            case (op)
                0, 1: begin sel = 1; we = 1; addr = 1 + $urandom % N; wdata = $urandom; wstrb = $urandom; end
                2:    begin sel = 1; we = 1; addr = A_EN; wdata = $urandom; wstrb = $urandom; end
                3:    begin sel = 1; we = 1; addr = A_THR; wdata = $urandom % 8; wstrb = $urandom; end
                4, 5, 6: begin sel = 1; re = 1; addr = A_CC; end
                7, 8: begin sel = 1; we = 1; addr = A_CC; wdata = ($urandom % 10 < 6) ? m_best(0) + ($urandom % 3 == 0) : $urandom % 10; wstrb = ($urandom % 8 == 0) ? 4'b1110 : 4'hF; end
                9:    begin sel = 1; re = $urandom; addr = $urandom % 1030; end
                default: ;
            endcase
            if (r % 20000 == 19999) begin rst_n = 0; @(negedge clk); rst_n = 1; end
        end
        rand_on = 0;
        if (errors == 0) $display("[PLIC] PASS"); else $display("[PLIC] FAIL %0d loi", errors);
        $finish;
    end
    initial begin #50_000_000; $display("[PLIC] FAIL het gio"); $finish; end
endmodule
