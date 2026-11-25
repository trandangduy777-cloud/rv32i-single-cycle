// Harness cache lenh: dau vao tu do (addr, flush, m_ack, m_rdata); ghost va khang dinh nam trong rv32_icache.v (ifdef RISCV_FORMAL_CACHE).
module icache_harness #(parameter LINES = 4, parameter WORDS = 2, parameter WAYS = 2) (
    input clk, input [31:0] addr, input flush, input m_ack, input [31:0] m_rdata);
    reg [5:0] step = 6'd0;
    always @(posedge clk) if (step != 6'd63) step <= step + 6'd1;
    wire [31:0] data; wire ready, m_req; wire [31:0] m_addr; wire [31:0] n_miss;
    rv32_icache #(.LINES(LINES), .WORDS(WORDS), .WAYS(WAYS)) dut (.clk(clk), .rst_n(step != 6'd0), .addr({addr[31:1], 1'b0}),
        .data(data), .ready(ready), .flush(flush), .m_req(m_req), .m_addr(m_addr), .m_ack(m_ack), .m_rdata(m_rdata), .n_miss(n_miss));
endmodule
