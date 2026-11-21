// Bo phan xu bus 2 nguon (cache lenh, cache du lieu) -> 1 bo nho chung, tu viet.
// - Giao thuc moi phia: req giu cho toi khi ack (1 chu ky); 1 yeu cau moi lan.
// - Khi bus ranh va ca hai cung yeu cau: uu tien cache du lieu (lenh o MEM dang dong bang ca pipeline).
// - Da cap bus cho phia nao thi giu cho toi khi bo nho ack, du phia kia yeu cau.
module rv32_bus_arbiter (
    input  wire        clk,
    input  wire        rst_n,
    // cache lenh (chi doc)
    input  wire        i_req,
    input  wire [31:0] i_addr,
    output wire        i_ack,
    // cache du lieu
    input  wire        d_req,
    input  wire        d_we,
    input  wire [31:0] d_addr,
    input  wire [31:0] d_wdata,
    input  wire [3:0]  d_wstrb,
    output wire        d_ack,
    // bo nho
    output wire        m_req,
    output wire        m_we,
    output wire [31:0] m_addr,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    input  wire        m_ack
);
    localparam NONE = 2'd0, OWN_I = 2'd1, OWN_D = 2'd2;
    reg [1:0] own;

    wire sel_d = (own == OWN_D) | ((own == NONE) & d_req);
    wire sel_i = (own == OWN_I) | ((own == NONE) & ~d_req & i_req);

    assign m_req   = (sel_d & d_req) | (sel_i & i_req);
    assign m_we    = sel_d & d_we;
    assign m_addr  = sel_d ? d_addr : i_addr;
    assign m_wdata = d_wdata;
    assign m_wstrb = sel_d ? d_wstrb : 4'b1111;
    assign d_ack   = sel_d & m_ack;
    assign i_ack   = sel_i & m_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            own <= NONE;
        else if (m_ack)        own <= NONE;
        else if (own == NONE)  own <= sel_d & d_req ? OWN_D : (sel_i & i_req ? OWN_I : NONE);
    end
endmodule
