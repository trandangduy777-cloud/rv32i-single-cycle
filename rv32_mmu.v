// MMU Sv32 cho rv32im_pipeline.v (SU = 1, MMU = 1): TLB ket hop toan phan dung chung cho lenh va du lieu, bo duyet
// bang trang 2 muc dung chung cong bo nho du lieu voi tang MEM.
// - TLB_N muc, thay the xoay vong. Moi muc: VPN, ASID, G, trang lon 4 MiB (muc 1), PPN, co R W X U A D.
//   TLB chi giu PTE la hop le ve cau truc; quyen (R / W / X / U / SUM / MXR) va A / D duoc kiem o pipeline moi lan
//   dung, nen doi mstatus hay che do khong can xoa TLB. flush (SFENCE.VMA, ghi satp) xoa het va huy lan duyet dang chay.
// - Hai cong tra cuu to hop: i_va (fetch) va d_va (load / store), ket qua hit, PA 34 bit, co.
// - Duyet: req + req_va -> doc PTE muc 1 tai satp.PPN * 4096 + VPN[1] * 4; la thi xong (trang lon), con khong thi doc
//   muc 0. Loi cau truc (giong Spike, khong co Svadu / Svnapot / Svpbmt): V = 0, W = 1 ma R = 0, la o muc 1 co
//   PPN[9:0] != 0, PTE khong la ma co D / A / U, PTE khong la o muc 0 -> pf (page fault). Dia chi PTE >= 2^32 hoac bi
//   PMP cam (pte_ok = 0, pipeline kiem voi quyen S) -> af (access fault).
// - Cong bo nho: m_req giu toi khi m_ready (cung giao thuc dmem_re / dmem_ready); m_grant = 0 thi chua duoc dung.
module rv32_mmu #(
    parameter TLB_N = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [8:0]  asid,
    input  wire [21:0] root_ppn,
    input  wire        flush,
    // tra cuu
    input  wire [31:0] i_va,
    output wire        i_hit,
    output wire [33:0] i_pa,
    output wire [5:0]  i_fl,          // {D, A, U, X, W, R}
    input  wire [31:0] d_va,
    output wire        d_hit,
    output wire [33:0] d_pa,
    output wire [5:0]  d_fl,
    // duyet
    input  wire        req,           // giu 1 toi khi done
    input  wire [31:0] req_va,
    output reg         done,          // 1 chu ky: xong (pf / af hoac da nap TLB)
    output reg         pf,
    output reg         af,
    // cong bo nho (doc 32 bit)
    output wire        m_req,
    output wire [33:0] m_addr,
    input  wire        m_grant,       // tang MEM khong dung cong: duoc phat yeu cau
    input  wire        m_ready,
    input  wire [31:0] m_rdata,
    input  wire        pte_ok         // PMP cho phep doc PTE tai m_addr (quyen S)
);
    localparam TB = (TLB_N > 1) ? $clog2(TLB_N) : 1;
    reg        t_v   [0:TLB_N-1];
    reg [19:0] t_vpn [0:TLB_N-1];
    reg [8:0]  t_asid[0:TLB_N-1];
    reg        t_g   [0:TLB_N-1];
    reg        t_sp  [0:TLB_N-1];
    reg [21:0] t_ppn [0:TLB_N-1];
    reg [5:0]  t_fl  [0:TLB_N-1];
    reg [TB-1:0] rr;

    // ---- tra cuu (mang bit theo tung muc, khong dung ham: iverilog khong theo doi mang doc trong ham) ----
    wire [TLB_N-1:0] im, dm;
    genvar g;
    generate for (g = 0; g < TLB_N; g = g + 1) begin : g_m
        wire base_ok = t_v[g] & (t_g[g] | (t_asid[g] == asid));
        assign im[g] = base_ok & (t_sp[g] ? (t_vpn[g][19:10] == i_va[31:22]) : (t_vpn[g] == i_va[31:12]));
        assign dm[g] = base_ok & (t_sp[g] ? (t_vpn[g][19:10] == d_va[31:22]) : (t_vpn[g] == d_va[31:12]));
    end endgenerate
    reg  [33:0] ipa, dpa;
    reg  [5:0]  ifl, dfl;
    integer j;
    always @* begin
        ipa = 34'd0; dpa = 34'd0; ifl = 6'd0; dfl = 6'd0;
        for (j = 0; j < TLB_N; j = j + 1) begin
            if (im[j]) begin
                ipa = ipa | (t_sp[j] ? {t_ppn[j][21:10], i_va[21:0]} : {t_ppn[j], i_va[11:0]});
                ifl = ifl | t_fl[j];
            end
            if (dm[j]) begin
                dpa = dpa | (t_sp[j] ? {t_ppn[j][21:10], d_va[21:0]} : {t_ppn[j], d_va[11:0]});
                dfl = dfl | t_fl[j];
            end
        end
    end
    assign i_hit = |im;
    assign i_pa  = ipa;
    assign i_fl  = ifl;
    assign d_hit = |dm;
    assign d_pa  = dpa;
    assign d_fl  = dfl;

    // ---- duyet bang trang ----
    localparam S_IDLE = 2'd0, S_L1 = 2'd1, S_L0 = 2'd2;
    reg  [1:0]  st;
    reg  [33:0] base;                 // dia chi bang trang cua muc dang doc
    reg  [31:0] va_q;
    wire [9:0]  vidx = (st == S_L1) ? va_q[31:22] : va_q[21:12];
    assign m_addr = base + {22'd0, vidx, 2'b00};
    wire        ad_ok = (m_addr[33:32] == 2'b00) & pte_ok;
    assign m_req  = (st != S_IDLE) & m_grant & ad_ok & ~flush;
    wire [31:0] pte   = m_rdata;
    wire        pv = pte[0], pr = pte[1], pw = pte[2], px = pte[3];
    wire        table_ = pv & ~pr & ~pw & ~px;
    wire        bad_leaf  = ~pv | (pw & ~pr);
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; done <= 1'b0; pf <= 1'b0; af <= 1'b0; rr <= {TB{1'b0}};
            for (k = 0; k < TLB_N; k = k + 1) t_v[k] <= 1'b0;
        end else begin
            done <= 1'b0;
            if (flush) begin
                for (k = 0; k < TLB_N; k = k + 1) t_v[k] <= 1'b0;
                st <= S_IDLE;
            end else case (st)
                S_IDLE: if (req && !done) begin
                    va_q <= req_va;
                    base <= {root_ppn, 12'd0};
                    st   <= S_L1;
                end
                default: if (m_grant && !ad_ok) begin               // dia chi PTE ngoai 32 bit / PMP cam
                    done <= 1'b1; pf <= 1'b0; af <= 1'b1; st <= S_IDLE;
                end else if (m_req && m_ready) begin
                    if (table_ && st == S_L1 && !(pte[7] | pte[6] | pte[4])) begin   // tro toi bang muc 0
                        base <= {pte[31:10], 12'd0};
                        st   <= S_L0;
                    end else if (table_ || bad_leaf || (st == S_L1 && pte[19:10] != 10'd0)) begin
                        done <= 1'b1; pf <= 1'b1; af <= 1'b0; st <= S_IDLE;
                    end else begin                                   // la hop le: nap TLB
                        t_v[rr]    <= 1'b1;
                        t_vpn[rr]  <= va_q[31:12];
                        t_asid[rr] <= asid;
                        t_g[rr]    <= pte[5];
                        t_sp[rr]   <= (st == S_L1);
                        t_ppn[rr]  <= pte[31:10];
                        t_fl[rr]   <= {pte[7], pte[6], pte[4], pte[3], pte[2], pte[1]};
                        rr   <= (rr == TLB_N - 1) ? {TB{1'b0}} : rr + 1'b1;
                        done <= 1'b1; pf <= 1'b0; af <= 1'b0; st <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
