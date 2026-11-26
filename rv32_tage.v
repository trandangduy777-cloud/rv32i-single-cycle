// Bo du doan huong nhanh kieu TAGE (Seznec & Michaud) cho rv32im_pipeline.v (TAGE = 1).
// - Bang co so: 2^BB bo dem 2 bit, chi so = pc.
// - NT bang co tag, moi bang 2^IB muc {ctr 3 bit co dau, tag TB bit, u 2 bit}; bang i dung HL[i] bit lich su toan cuc
//   (do dai tang dan, mac dinh 4 / 8 / 16 / 32). Chi so = pc[PCB +: IB] ^ pc[PCB + IB +: IB] ^ gap(lich su, IB);
//   tag = pc[PCB +: TB] ^ gap(lich su, TB) ^ (gap(lich su, TB - 1) << 1); gap(h, L, W): bit k (k < L) cua h XOR vao
//   bit k mod W. Khong co bit hop le: sau reset moi muc la tag 0, ctr 0, u 0 (mo hinh tham chieu lam y het).
// - Du doan (to hop, doc o IF): bang trung dai nhat la provider, bang trung ke tiep (hoac bang co so) la alt.
//   Provider yeu (ctr 0 hoac -1) va bo dem use_alt (4 bit, khoi dau 8) >= 8 thi theo alt, khong thi theo provider;
//   khong bang nao trung thi theo bang co so.
// - Cap nhat (u_valid, theo meta luc du doan, doc lai muc hien tai):
//   . co provider: ctr bao hoa theo ket qua; provider khac alt thi u +1 neu provider dung, -1 neu sai; provider yeu
//     va khac alt thi use_alt +1 neu alt dung, -1 neu sai. Khong co provider: cap nhat bang co so.
//   . du doan cuoi sai va provider chua phai bang dai nhat: cap phat o bang dai hon ngan nhat co u = 0 (tag moi,
//     ctr yeu theo ket qua, u = 0); khong co bang nao u = 0 thi giam u cua moi bang dai hon.
//   . moi 2^RST_LOG lan cap nhat: xoa mot bit u cua moi muc (luan phien bit cao / bit thap).
// - Lich su (h_valid): dich ket qua nhanh vao GHR. Pipeline dich o EX (khong suy doan) va cap nhat bang o chu ky sau;
//   meta mang chi so / tag tinh luc du doan nen du doan va cap nhat luon dung cung lich su.
module rv32_tage #(
    parameter NT      = 4,
    parameter IB      = 6,
    parameter TB      = 8,
    parameter BB      = 7,
    parameter PCB     = 1,
    parameter [8*NT-1:0] HL = {8'd32, 8'd16, 8'd8, 8'd4},   // HL[8*i +: 8] = so bit lich su cua bang i
    parameter RST_LOG = 11
) (
    input  wire              clk,
    input  wire              rst_n,
    // du doan
    input  wire [31:0]       p_pc,
    output wire              p_taken,
    output wire [MW-1:0]     p_meta,
    // cap nhat bang
    input  wire              u_valid,
    input  wire              u_taken,
    input  wire [MW-1:0]     u_meta,
    // lich su
    input  wire              h_valid,
    input  wire              h_taken
);
    localparam PW = (NT + 1 > 1) ? $clog2(NT + 1) : 1;        // provider: 0 = khong co, i + 1 = bang i
    localparam MW = 3 + 1 + 2 * PW + BB + NT * (IB + TB);
    function integer hmax(input integer d);
        integer i; begin hmax = 1; for (i = 0; i < NT; i = i + 1) if (HL[8*i +: 8] > hmax) hmax = HL[8*i +: 8]; end
    endfunction
    localparam GL = hmax(0);

    reg  [GL-1:0] ghr;
    reg  [1:0]    bim  [0:(1<<BB)-1];
    reg  [2:0]    t_c  [0:NT*(1<<IB)-1];                      // muc cua bang i o chi so x: i * 2^IB + x
    reg  [TB-1:0] t_t  [0:NT*(1<<IB)-1];
    reg  [1:0]    t_u  [0:NT*(1<<IB)-1];
    reg  [3:0]    use_alt;
    reg  [RST_LOG-1:0] tick;
    reg           phase;

    // ---- chi so / tag ----
    function [31:0] fold(input [GL-1:0] h, input integer len, input integer w);
        integer k; begin
            fold = 32'd0;
            for (k = 0; k < GL; k = k + 1) if (k < len) fold[k % w] = fold[k % w] ^ h[k];
        end
    endfunction
    wire [NT*IB-1:0] idx;
    wire [NT*TB-1:0] tag;
    genvar g;
    generate for (g = 0; g < NT; g = g + 1) begin : g_h
        wire [31:0] f_i = fold(ghr, HL[8*g +: 8], IB);
        wire [31:0] f_t = fold(ghr, HL[8*g +: 8], TB);
        wire [31:0] f_s = fold(ghr, HL[8*g +: 8], TB - 1);
        assign idx[g*IB +: IB] = p_pc[PCB +: IB] ^ p_pc[PCB + IB +: IB] ^ f_i[IB-1:0];
        assign tag[g*TB +: TB] = p_pc[PCB +: TB] ^ f_t[TB-1:0] ^ {f_s[TB-2:0], 1'b0};
    end endgenerate
    wire [BB-1:0] bidx = p_pc[PCB +: BB];

    // ---- du doan ----
    wire [NT-1:0] hit;
    wire [3*NT-1:0] ctr;
    generate for (g = 0; g < NT; g = g + 1) begin : g_p
        assign hit[g] = (t_t[g*(1<<IB) + idx[g*IB +: IB]] == tag[g*TB +: TB]);
        assign ctr[3*g +: 3] = t_c[g*(1<<IB) + idx[g*IB +: IB]];
    end endgenerate
    reg  [PW-1:0] prov, altp;
    integer i;
    always @* begin
        prov = {PW{1'b0}}; altp = {PW{1'b0}};
        for (i = 0; i < NT; i = i + 1)
            if (hit[i]) begin altp = prov; prov = i + 1; end
    end
    wire       base_pred = bim[bidx][1];
    wire [2:0] pc_c      = (prov != 0) ? ctr[3*(prov-1) +: 3] : 3'd0;
    wire       prov_pred = ~pc_c[2];
    wire       prov_weak = (pc_c == 3'b000) | (pc_c == 3'b111);
    wire [2:0] ac_c      = (altp != 0) ? ctr[3*(altp-1) +: 3] : 3'd0;
    wire       alt_pred  = (altp != 0) ? ~ac_c[2] : base_pred;
    assign p_taken = (prov == 0) ? base_pred : ((prov_weak & use_alt[3]) ? alt_pred : prov_pred);
    assign p_meta  = {p_taken, alt_pred, prov_pred, prov_weak, prov, altp, bidx, idx, tag};

    // ---- cap nhat ----
    wire          m_fin   = u_meta[MW-1];
    wire          m_alt   = u_meta[MW-2];
    wire          m_ppred = u_meta[MW-3];
    wire          m_pweak = u_meta[MW-4];
    wire [PW-1:0] m_prov  = u_meta[MW-5 -: PW];
    wire [BB-1:0] m_bidx  = u_meta[NT*(IB+TB) +: BB];
    wire [NT*IB-1:0] m_idx = u_meta[NT*TB +: NT*IB];
    wire [NT*TB-1:0] m_tag = u_meta[0 +: NT*TB];
    // bang cap phat: bang dai hon provider ngan nhat co u = 0
    reg  [PW-1:0] alloc;                                      // 0 = khong co
    always @* begin
        alloc = {PW{1'b0}};
        for (i = NT - 1; i >= 0; i = i - 1)
            if (i + 1 > m_prov && t_u[i*(1<<IB) + m_idx[i*IB +: IB]] == 2'd0) alloc = i + 1;
    end
    wire mis = u_valid & (m_fin != u_taken) & (m_prov != NT);
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ghr <= {GL{1'b0}}; use_alt <= 4'd8; tick <= {RST_LOG{1'b0}}; phase <= 1'b0;
            for (k = 0; k < (1<<BB); k = k + 1) bim[k] <= 2'b01;
            for (k = 0; k < NT*(1<<IB); k = k + 1) begin t_c[k] <= 3'd0; t_t[k] <= {TB{1'b0}}; t_u[k] <= 2'd0; end
        end else begin
            if (h_valid) ghr <= {ghr[GL-2:0], h_taken};
            if (u_valid) begin
                if (m_prov != 0) begin : upd_p
                    integer e;
                    e = (m_prov - 1) * (1<<IB) + m_idx[(m_prov-1)*IB +: IB];
                    if (u_taken) begin if (t_c[e] != 3'b011) t_c[e] <= t_c[e] + 3'd1; end
                    else         begin if (t_c[e] != 3'b100) t_c[e] <= t_c[e] - 3'd1; end
                    if (m_ppred != m_alt) begin
                        if (m_ppred == u_taken) begin if (t_u[e] != 2'd3) t_u[e] <= t_u[e] + 2'd1; end
                        else                    begin if (t_u[e] != 2'd0) t_u[e] <= t_u[e] - 2'd1; end
                    end
                    if (m_pweak && m_ppred != m_alt) begin
                        if (m_alt == u_taken) begin if (use_alt != 4'd15) use_alt <= use_alt + 4'd1; end
                        else                  begin if (use_alt != 4'd0)  use_alt <= use_alt - 4'd1; end
                    end
                end else begin
                    if (u_taken) begin if (bim[m_bidx] != 2'b11) bim[m_bidx] <= bim[m_bidx] + 2'd1; end
                    else         begin if (bim[m_bidx] != 2'b00) bim[m_bidx] <= bim[m_bidx] - 2'd1; end
                end
                if (mis) begin
                    if (alloc != 0) begin : al
                        integer e;
                        e = (alloc - 1) * (1<<IB) + m_idx[(alloc-1)*IB +: IB];
                        t_t[e] <= m_tag[(alloc-1)*TB +: TB];
                        t_c[e] <= u_taken ? 3'b000 : 3'b111;
                        t_u[e] <= 2'd0;
                    end else begin
                        for (k = 0; k < NT; k = k + 1)
                            if (k + 1 > m_prov && t_u[k*(1<<IB) + m_idx[k*IB +: IB]] != 2'd0)
                                t_u[k*(1<<IB) + m_idx[k*IB +: IB]] <= t_u[k*(1<<IB) + m_idx[k*IB +: IB]] - 2'd1;
                    end
                end
                tick <= tick + 1'b1;
                if (&tick) begin                              // lao hoa u (sau cac cap nhat tren o cung chu ky)
                    phase <= ~phase;
                    for (k = 0; k < NT*(1<<IB); k = k + 1) t_u[k][phase ? 0 : 1] <= 1'b0;
                end
            end
        end
    end
endmodule
