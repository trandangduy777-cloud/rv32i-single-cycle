// Cache lenh set-associative (WAYS duong, WAYS = 1: anh xa truc tiep), chi doc, tu viet.
// - Phia loi: addr (chia het cho 2) -> data = 32 bit bat dau tu addr, ready = 1 khi co du trong cache (to hop, cung
//   chu ky). Voi addr[1] = 1 (lenh nen, mo rong C) cua so 32 bit nam vat qua 2 tu, co the qua 2 dong cache khac
//   nhau: ca 2 dong phai co mat; dong nao thieu thi nap dong do truoc.
// - Thay the: duong con trong (valid = 0) co chi so nho nhat; neu tap day thi theo cay pseudo-LRU (WAYS - 1 bit moi
//   tap; WAYS = 2 la LRU dung). Moi lan trung (tu thu nhat, roi tu thu hai neu can) va moi lan nap xong deu danh dau
//   duong do la moi dung nhat. Duong bi chon duoc xoa valid ngay khi bat dau nap.
// - Phia bus: moi lan doc 1 tu (m_req giu cho toi khi m_ack); nap ca dong theo thu tu tu dau dong.
// - Khi dang nap ma dia chi phia loi doi (redirect), viec nap van lam xong roi moi xet dia chi moi.
// - flush: xoa het bit valid (dung cho FENCE.I). Neu dang nap, dong do khong duoc danh dau valid khi nap xong
//   (cac tu da doc truoc flush co the la du lieu cu).
// - Tham so: LINES tong so dong (luy thua 2), WAYS so duong (luy thua 2, <= LINES), WORDS so tu moi dong
//   (luy thua 2, >= 2). So tap = LINES / WAYS; dung luong khong doi khi doi WAYS.
module rv32_icache #(
    parameter LINES = 16,
    parameter WORDS = 4,
    parameter WAYS  = 1
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
    localparam SETS = LINES / WAYS;
    localparam LS = $clog2(SETS);         // bit chi so tap (co the bang 0)
    localparam SB = (LS > 0) ? LS : 1;    // do rong thanh ghi chi so tap
    localparam WB = $clog2(WORDS);        // bit chi so tu trong dong
    localparam TB = 30 - LS - WB;         // bit tag (dia chi tu 30 bit)
    localparam AB = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam PB = (WAYS > 1) ? WAYS - 1 : 1;   // so bit pseudo-LRU moi tap

    // dong vat ly = tap * WAYS + duong
    reg [TB-1:0] tag_r [0:LINES-1];
    reg          val_r [0:LINES-1];
    reg [31:0]   mem_r [0:LINES*WORDS-1];
    reg [PB-1:0] plru_r [0:SETS-1];

    // tu thu nhat (w0) va tu ke tiep (w1, chi can khi addr[1] = 1)
    wire [29:0] w0 = addr[31:2];
    wire [29:0] w1 = w0 + 30'd1;
    wire        need1 = addr[1];

    wire [SB-1:0] s0 = (LS > 0) ? w0[WB +: SB] : {SB{1'b0}};
    wire [SB-1:0] s1 = (LS > 0) ? w1[WB +: SB] : {SB{1'b0}};
    wire [TB-1:0] t0 = w0[29 -: TB], t1 = w1[29 -: TB];

    // tim duong trung cho moi tu
    reg          hit0, hit1;
    reg [AB-1:0] way0, way1;
    integer      q, qv;
    always @* begin
        hit0 = 1'b0; hit1 = 1'b0; way0 = {AB{1'b0}}; way1 = {AB{1'b0}};
        for (q = 0; q < WAYS; q = q + 1) begin
            if (val_r[s0 * WAYS + q] && tag_r[s0 * WAYS + q] == t0) begin hit0 = 1'b1; way0 = q; end
            if (val_r[s1 * WAYS + q] && tag_r[s1 * WAYS + q] == t1) begin hit1 = 1'b1; way1 = q; end
        end
    end

    wire [31:0] d0 = mem_r[(s0 * WAYS + way0) * WORDS + w0[WB-1:0]];
    wire [31:0] d1 = mem_r[(s1 * WAYS + way1) * WORDS + w1[WB-1:0]];

    // ---- pseudo-LRU dang cay: nut n co con trai 2n+1, con phai 2n+2; la (nut WAYS-1+w) la duong w.
    //      bit = 0: nan nhan o cay con trai, 1: o cay con phai. Danh dau w moi dung: moi nut tren duong tu goc
    //      xuong w tro sang phia ben kia.
    function [PB-1:0] plru_touch(input [PB-1:0] b, input [AB-1:0] w);
        integer lv, node, half, lo;
        begin
            plru_touch = b;
            if (WAYS > 1) begin
                node = 0; lo = 0; half = WAYS / 2;
                for (lv = 0; lv < AB; lv = lv + 1) begin
                    if (w < lo + half) begin plru_touch[node] = 1'b1; node = 2 * node + 1; end
                    else               begin plru_touch[node] = 1'b0; node = 2 * node + 2; lo = lo + half; end
                    half = half / 2;
                end
            end
        end
    endfunction
    function [AB-1:0] plru_victim(input [PB-1:0] b);
        integer lv, node;
        begin
            node = 0;
            if (WAYS > 1)
                for (lv = 0; lv < AB; lv = lv + 1) node = b[node] ? 2 * node + 2 : 2 * node + 1;
            plru_victim = (WAYS > 1) ? node - (WAYS - 1) : {AB{1'b0}};
        end
    endfunction

    localparam IDLE = 1'b0, FILL = 1'b1;
    reg          state;
    reg [29:WB]  fill_line;              // dia chi dong dang nap (bo bit tu)
    reg [SB-1:0] fill_set;
    reg [AB-1:0] fill_way;
    reg [WB-1:0] fill_cnt;
    reg          fill_kill;              // co flush trong luc nap: bo dong nay

    assign ready = (state == IDLE) & hit0 & (~need1 | hit1);
    assign data  = need1 ? {d1[15:0], d0[31:16]} : d0;

    assign m_req  = (state == FILL);
    assign m_addr = {fill_line, fill_cnt, 2'b00};

    // dong can nap (tu dau tien con thieu) va duong se thay trong tap cua no. Nan nhan tinh tren trang thai LRU da
    // cap nhat cac lan trung cua chinh chu ky nay (tu thu nhat, roi tu thu hai) neu cung tap (chi xay ra khi SETS = 1),
    // de khong day dong cua tu kia ra.
    wire [SB-1:0] miss_set = !hit0 ? s0 : s1;
    reg  [PB-1:0] plru_m;
    reg  [AB-1:0] victim;
    always @* begin
        plru_m = plru_r[miss_set];
        if (hit0 && s0 == miss_set)          plru_m = plru_touch(plru_m, way0);
        if (need1 && hit1 && s1 == miss_set) plru_m = plru_touch(plru_m, way1);
        victim = plru_victim(plru_m);
        for (qv = WAYS - 1; qv >= 0; qv = qv - 1)
            if (!val_r[miss_set * WAYS + qv]) victim = qv;
    end

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            fill_cnt <= {WB{1'b0}};
            fill_kill <= 1'b0;
            n_miss   <= 32'd0;
            for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;
            for (k = 0; k < SETS; k = k + 1) plru_r[k] <= {PB{1'b0}};
        end else begin
            if (flush)
                for (k = 0; k < LINES; k = k + 1) val_r[k] <= 1'b0;
            case (state)
                IDLE: begin
                    // cap nhat LRU theo thu tu: tu thu nhat roi tu thu hai (neu cung tap, lan sau thang)
                    if (hit0 & need1 & hit1 & (s0 == s1))
                        plru_r[s0] <= plru_touch(plru_touch(plru_r[s0], way0), way1);
                    else begin
                        if (hit0) plru_r[s0] <= plru_touch(plru_r[s0], way0);
                        if (need1 & hit1) plru_r[s1] <= plru_touch(plru_r[s1], way1);
                    end
                    if (!ready) begin
                        fill_line <= !hit0 ? w0[29:WB] : w1[29:WB];
                        fill_set  <= miss_set;
                        fill_way  <= victim;
                        fill_cnt  <= {WB{1'b0}};
                        fill_kill <= flush;
                        state     <= FILL;
                        n_miss    <= n_miss + 32'd1;
                        if (!flush) val_r[miss_set * WAYS + victim] <= 1'b0;   // dong cu bi thay
                    end
                end
                FILL: begin
                    if (flush) fill_kill <= 1'b1;
                    if (m_ack) begin
                        mem_r[(fill_set * WAYS + fill_way) * WORDS + fill_cnt] <= m_rdata;
                        fill_cnt <= fill_cnt + 1'b1;
                        if (fill_cnt == {WB{1'b1}}) begin
                            tag_r[fill_set * WAYS + fill_way] <= fill_line[29 -: TB];
                            val_r[fill_set * WAYS + fill_way] <= ~(fill_kill | flush);
                            plru_r[fill_set] <= plru_touch(plru_r[fill_set], fill_way);
                            state <= IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule
