// Harness cache du lieu: dau vao tu do; ghost va khang dinh nam trong rv32_dcache.v (ifdef RISCV_FORMAL_CACHE).
module dcache_harness #(parameter LINES = 4, parameter WORDS = 2, parameter WAYS = 2, parameter WBUF = 2,
                        parameter [31:0] CMASK = 32'h0, parameter [31:0] CBASE = 32'h0) (
    input clk, input [31:0] addr, input re, input we, input fence, input [3:0] wstrb, input [31:0] wdata,
    input m_ack, input [31:0] m_rdata);
    reg [5:0] step = 6'd0;
    always @(posedge clk) if (step != 6'd63) step <= step + 6'd1;
    wire [31:0] rdata; wire ready, wb_empty, m_req, m_we; wire [31:0] m_addr, m_wdata; wire [3:0] m_wstrb; wire [31:0] n_miss;
    rv32_dcache #(.LINES(LINES), .WORDS(WORDS), .WAYS(WAYS), .WBUF(WBUF), .CMASK(CMASK), .CBASE(CBASE)) dut (
        .clk(clk), .rst_n(step != 6'd0), .addr(addr), .re(re), .we(we), .fence(fence), .wstrb(wstrb), .wdata(wdata),
        .rdata(rdata), .ready(ready), .wb_empty(wb_empty), .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_wstrb(m_wstrb), .m_ack(m_ack), .m_rdata(m_rdata), .n_miss(n_miss));
endmodule
