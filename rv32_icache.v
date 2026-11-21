// Cache lenh anh xa truc tiep (direct-mapped), chi doc, tu viet.
// - Phia loi: addr (chia het cho 2) -> data = 32 bit bat dau tu addr, ready = 1 khi co du trong cache (to hop, cung
//   chu ky). Voi addr[1] = 1 (lenh nen, mo rong C) cua so 32 bit nam vat qua 2 tu, co the qua 2 dong cache khac
//   nhau: ca 2 dong phai co mat; dong nao thieu thi nap dong do truoc.
// - Phia bus: moi lan doc 1 tu (m_req giu cho toi khi m_ack); nap ca dong theo thu tu tu dau dong.
// - Khi dang nap ma dia chi phia loi doi (redirect), viec nap van lam xong roi moi xet dia chi moi.
// - flush: xoa het bit valid (dung cho FENCE.I). Neu dang nap, dong do khong duoc danh dau valid khi nap xong
//   (cac tu da doc truoc flush co the la du lieu cu).
// - Tham so: LINES so dong (luy thua 2), WORDS so tu moi dong (luy thua 2, >= 2).
module rv32_icache #(
    parameter LINES = 16,
    parameter WORDS = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    // phia loi
    input  wire [31:0] addr,
    output wire [31:0] data,
    output wire        ready,
    input  wire        flush,
    // phia bus (chi doc)
    output wire        m_req,
    output wire [31:0] m_addr,
    input  wire        m_ack,
    input  wire [31:0] m_rdata,
    // thong ke (cho testbench)
    output reg  [31:0] n_miss
);
    localparam IB = $clog2(LINES);       // bit chi so dong
    localparam WB = $clog2(WORDS);       // bit chi so tu trong dong
    localparam TB = 30 - IB - WB;        // bit tag (dia chi tu 30 bit)

    reg [TB-1:0] tag_r [0:LINES-1];
    reg          val_r [0:LINES-1];
    reg [31:0]   mem_r [0:LINES*WORDS-1];

    // tu thu nhat (w0) va tu ke tiep (w1, chi can khi addr[1] = 1)
    wire [29:0] w0 = addr[31:2];
    wire [29:0] w1 = w0 + 30'd1;
    wire        need1 = addr[1];

    wire [IB-1:0] i0 = w0[WB +: IB], i1 = w1[WB +: IB];
    wire [TB-1:0] t0 = w0[29 -: TB], t1 = w1[29 -: TB];
    wire hit0 = val_r[i0] & (tag_r[i0] == t0);
    wire hit1 = val_r[i1] & (tag_r[i1] == t1);

    wire [31:0] d0 = mem_r[w0[IB+WB-1:0]];
    wire [31:0] d1 = mem_r[w1[IB+WB-1:0]];

    localparam IDLE = 1'b0, FILL = 1'b1;
    reg          state;
    reg [29:WB]  fill_line;              // dia chi dong dang nap (bo bit tu)
    reg [WB-1:0] fill_cnt;
    reg          fill_kill;              // co flush trong luc nap: bo dong nay

    assign ready = (state == IDLE) & hit0 & (~need1 | hit1);
    assign data  = need1 ? {d1[15:0], d0[31:16]} : d0;

    assign m_req  = (state == FILL);
    assign m_addr = {fill_line, fill_cnt, 2'b00};

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            fill_cnt <= {WB{1'b0}};
            fill_kill <= 1'b0;
            n_miss   <= 32'd0;
            for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;
        end else begin
            if (flush)
                for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;
            case (state)
                IDLE: if (!ready) begin
                    // nap dong cua tu dau tien con thieu
                    fill_line <= !hit0 ? w0[29:WB] : w1[29:WB];
                    fill_cnt  <= {WB{1'b0}};
                    fill_kill <= flush;
                    state     <= FILL;
                    n_miss    <= n_miss + 32'd1;
                    if (!flush) val_r[!hit0 ? i0 : i1] <= 1'b0;     // dong cu bi thay
                end
                FILL: begin
                    if (flush) fill_kill <= 1'b1;
                    if (m_ack) begin
                    mem_r[{fill_line[IB+WB-1:WB], fill_cnt}] <= m_rdata;
                    fill_cnt <= fill_cnt + 1'b1;
                    if (fill_cnt == {WB{1'b1}}) begin
                        tag_r[fill_line[IB+WB-1:WB]] <= fill_line[29 -: TB];
                        val_r[fill_line[IB+WB-1:WB]] <= ~(fill_kill | flush);
                        state <= IDLE;
                    end
                    end
                end
            endcase
        end
    end
endmodule
