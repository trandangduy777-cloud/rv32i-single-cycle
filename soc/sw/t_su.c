#include "soc.h"
/* Che do S / U voi MMU Sv32 tren SoC (cau hinh SU=1 MMU=1 CLINT_STD=1 PLIC_S=1, bien dich loi voi -DSEIP_PIN): giong cach OpenSBI + Linux dung phan cung.
   M: PMP mo, medeleg / mideleg, bang trang, doi sang S bang mret. S: page fault uy quyen (load / store / fetch, A / D / quyen ghi / SUM / U), bang hai muc, sfence.vma,
   mo U, lenh dac quyen o U (illegal vao M), ngat timer qua M (STIP), ngat phan mem qua MSIP (SSIP), ngat ngoai qua context S cua PLIC (SEIP), context M khong thay nguon.
   Cach quy uoc: moi truy cap loi chi 1 lenh 4 byte (.option norvc) de handler tang sepc 4; fetch loi thi handler tra ve ra. U khong dung stack (dung chung sp cua S). */
#define V 1u
#define R 2u
#define W 4u
#define X 8u
#define U_ 16u
#define A 0x40u
#define D 0x80u
#define PTE(pa, f) ((((pa) >> 12) << 10) | (f))
#define CL_MSIP  REG(0x02000000u)
#define CL_CMPL  REG(0x02004000u)
#define CL_CMPH  REG(0x02004004u)
#define CL_TL    REG(0x0200BFF8u)
#define CL_TH    REG(0x0200BFFCu)
#define PL_PRIO(i) REG(0x0C000000u + 4u * (i))
#define PL_ENS   REG(0x0C002080u)
#define PL_THRS  REG(0x0C201000u)
#define PL_CCS   REG(0x0C201004u)
#define PL_CCM   REG(0x0C200004u)
#define SSTATUS_SIE (1u << 1)
#define SSTATUS_SPP (1u << 8)
#define SSTATUS_SUM (1u << 18)
#define TOFF 0xF80u                      /* tu thu nam trong trang cua bang goc (muc goc 0x3E0 khong dung) */

static u32 root[1024] __attribute__((aligned(4096)));
static u32 leaf[1024] __attribute__((aligned(4096)));
volatile u32 udata[4];
volatile u32 sbi_fn, sbi_arg, s_sp;
volatile u32 fn, fc, ft, fp, stip_n, ssip_n, seip_n, uill_n, seip_ids[4];

/* ---- M: ecall tu S (dich vu kieu SBI), ngat timer / phan mem chuyen tiep cho S, illegal tu U ---- */
void trap_c(void) {
    u32 c = csr_read(mcause);
    if (c == 9) {
        csr_write(mepc, csr_read(mepc) + 4);
        if (sbi_fn == 1) csr_clear(mip, 0x20);                                      /* xoa STIP */
        else if (sbi_fn == 2) { CL_CMPH = 0xFFFFFFFFu; CL_CMPL = CL_TL + sbi_arg; CL_CMPH = CL_TH; csr_clear(mip, 0x20); }   /* hen gio sbi_arg chu ky */
        else if (sbi_fn == 3) { SYS_EXIT = sbi_arg; for (;;) ; }
        else if (sbi_fn == 5) CL_MSIP = 1;                                          /* gia lap IPI phan mem */
        else if (sbi_fn != 7) die(0xBAD00009u);
    } else if (c == 2) { uill_n++; csr_write(mepc, csr_read(mepc) + 4); }
    else if (c == 0x80000007u) { CL_CMPH = 0xFFFFFFFFu; CL_CMPL = 0xFFFFFFFFu; csr_set(mip, 0x20); }
    else if (c == 0x80000003u) { CL_MSIP = 0; csr_set(mip, 0x2); }
    else die(0xBAD00000u | (c & 0xFFFF));
}

/* ---- S: vao trap, luu thanh ghi, goi strap_c(frame) ---- */
__asm__(".balign 4\n.globl strap_entry\nstrap_entry:\n addi sp,sp,-64\n sw ra,0(sp)\n sw t0,4(sp)\n sw t1,8(sp)\n sw t2,12(sp)\n sw a0,16(sp)\n sw a1,20(sp)\n"
        " sw a2,24(sp)\n sw a3,28(sp)\n sw a4,32(sp)\n sw a5,36(sp)\n sw a6,40(sp)\n sw a7,44(sp)\n sw t3,48(sp)\n sw t4,52(sp)\n sw t5,56(sp)\n sw t6,60(sp)\n"
        " mv a0,sp\n call strap_c\n lw ra,0(sp)\n lw t0,4(sp)\n lw t1,8(sp)\n lw t2,12(sp)\n lw a0,16(sp)\n lw a1,20(sp)\n lw a2,24(sp)\n lw a3,28(sp)\n lw a4,32(sp)\n"
        " lw a5,36(sp)\n lw a6,40(sp)\n lw a7,44(sp)\n lw t3,48(sp)\n lw t4,52(sp)\n lw t5,56(sp)\n lw t6,60(sp)\n fence\n addi sp,sp,64\n sret\n");
/* vao U: luu s0-s11 va sp, sret toi U; user_ret (S) khoi phuc va tra ve cho noi goi */
__asm__(".globl enter_user\nenter_user:\n addi sp,sp,-52\n sw ra,0(sp)\n sw s0,4(sp)\n sw s1,8(sp)\n sw s2,12(sp)\n sw s3,16(sp)\n sw s4,20(sp)\n sw s5,24(sp)\n"
        " sw s6,28(sp)\n sw s7,32(sp)\n sw s8,36(sp)\n sw s9,40(sp)\n sw s10,44(sp)\n sw s11,48(sp)\n la t0,s_sp\n sw sp,0(t0)\n csrw sepc,a0\n li t0,0x120\n csrc sstatus,t0\n sret\n"
        ".globl user_ret\nuser_ret:\n la t0,s_sp\n lw sp,0(t0)\n lw ra,0(sp)\n lw s0,4(sp)\n lw s1,8(sp)\n lw s2,12(sp)\n lw s3,16(sp)\n lw s4,20(sp)\n lw s5,24(sp)\n lw s6,28(sp)\n"
        " lw s7,32(sp)\n lw s8,36(sp)\n lw s9,40(sp)\n lw s10,44(sp)\n lw s11,48(sp)\n addi sp,sp,52\n ret\n");
/* ma U (khong phu thuoc vi tri): ghi + doc trang U, doc trang chi S (loi 13), csrr satp (illegal -> M), ecall thoat */
__asm__(".option push\n.option norvc\n.balign 4\n.globl u_code\nu_code:\n li t0,0x600DF00D\n sw t0,0(a1)\n lw t1,0(a1)\n sw t1,4(a1)\n lui t2,0x10000\n lw t3,0(t2)\n"
        " csrr t4,satp\n li a7,1\n ecall\n j .\n.option pop\n");
extern void strap_entry(void);
extern void enter_user(u32 pc, u32 a1);
extern char u_code[];
extern void user_ret(void);

void strap_c(u32 *fr) {
    u32 c = csr_read(scause);
    if (c == 0x80000005u) { stip_n++; sbi_fn = 1; __asm__ volatile ("ecall" ::: "memory"); }
    else if (c == 0x80000001u) { ssip_n++; csr_clear(sip, 2); }
    else if (c == 0x80000009u) { u32 id; while ((id = PL_CCS) != 0) { if (seip_n < 4) seip_ids[seip_n] = id; seip_n++; } }
    else if (c == 8) { csr_write(sepc, (u32)user_ret); csr_set(sstatus, SSTATUS_SPP); }      /* "syscall" thoat U */
    else if (c == 12 || c == 13 || c == 15) {
        fn++; fc = c; ft = csr_read(stval); fp = (csr_read(sstatus) >> 8) & 1;
        csr_write(sepc, (c == 12) ? fr[0] : csr_read(sepc) + 4);
    } else die(0xBAD50000u | (c & 0xFFFF));
}

#define NORVC(i) ".option push\n.option norvc\n" i "\n.option pop"
static inline u32 ld(u32 va) { u32 v; __asm__ volatile (NORVC("lw %0,0(%1)") : "=r"(v) : "r"(va) : "memory"); return v; }
static inline void st(u32 va, u32 v) { __asm__ volatile (NORVC("sw %1,0(%0)") :: "r"(va), "r"(v) : "memory"); }
static inline void jmp(u32 va) { __asm__ volatile ("jalr ra,0(%0)" :: "r"(va) : "ra", "memory"); }
static void rep(const char *s) { puts_(s); putc_(' '); put_dec(fn); putc_(' '); put_dec(fc); putc_(' '); put_hex(ft); putc_(' '); put_dec(fp); putc_('\n'); fn = fc = ft = fp = 0; }
#define PG(i) (0xC0000000u + (i) * 4096u + TOFF)

static void s_main(void) {
    puts_("S\n");
    sbi_fn = 7; __asm__ volatile ("ecall" ::: "memory"); puts_("ecall ok\n");
    u32 v;
    v = ld(0x70000000u); rep("unmapped-ld");
    st(0x70000000u, 1); rep("unmapped-st");
    st(PG(0), 0x1234ABCDu); v = ld(PG(0));                                           /* bang hai muc, RW */
    puts_("two-level "); put_hex(v); putc_(' '); put_hex(root[TOFF / 4]); putc_('\n');   /* alias danh tinh phai thay cung gia tri */
    rep("rw-page");
    st(PG(1), 5); rep("ro-st");
    v = ld(PG(1)); rep("ro-ld"); if (v != 0x1234ABCDu) die(0xE1);
    v = ld(PG(2)); rep("a0-ld");
    v = ld(PG(3)); rep("d0-ld");
    st(PG(3), 7); rep("d0-st");
    jmp(0x10000000u); rep("fetch-ram");
    v = ld(PG(4)); rep("u-ld-nosum");
    csr_set(sstatus, SSTATUS_SUM); v = ld(PG(4)); st(PG(4), 0x77u); v = ld(PG(4)); csr_clear(sstatus, SSTATUS_SUM);
    puts_("sum "); put_hex(v); putc_('\n'); rep("sum-ok");
    leaf[1] = PTE((u32)root, V | R | W | A | D); __asm__ volatile ("fence; sfence.vma zero,zero" ::: "memory");   /* doi quyen trang 1 thanh RW */
    st(PG(1), 0x99u); v = ld(PG(1)); puts_("sfence "); put_hex(v); putc_('\n'); rep("sfence-ok");
    enter_user(0x80000000u + (u32)u_code, 0x44000000u + ((u32)udata - 0x10000000u));
    puts_("user "); put_hex(udata[0]); putc_(' '); put_hex(udata[1]); putc_(' '); put_dec(uill_n); putc_('\n'); rep("user-fault");
    /* ngat timer: M chuyen tiep thanh STIP */
    csr_write(sie, 0x222u); csr_set(sstatus, SSTATUS_SIE);
    sbi_fn = 2; sbi_arg = 600; __asm__ volatile ("ecall" ::: "memory");
    while (!stip_n) ;
    puts_("stip "); put_dec(stip_n); putc_('\n');
    sbi_fn = 5; __asm__ volatile ("ecall" ::: "memory");
    while (!ssip_n) ;
    puts_("ssip "); put_dec(ssip_n); putc_('\n');
    /* ngat ngoai: P1 -> tb keo ext_irq cao (nguon 4, 5, 6, 7), chi bat nguon 4, 5 o context S */
    PL_PRIO(4) = 3; PL_PRIO(5) = 1; PL_PRIO(6) = 7; PL_THRS = 0; PL_ENS = 0x30;
    csr_write(sie, 0x22u);                                                          /* SEIE = 0: SEIP phai len o sip nhung khong gay ngat */
    puts_("P1\n");
    for (volatile u32 i = 0; i < 4000; i++) ;
    puts_("masked "); put_dec(seip_n); putc_(' '); put_dec((csr_read(sip) >> 9) & 1); putc_('\n');
    csr_set(sie, 0x200u);
    while (!seip_n) ;
    for (volatile u32 i = 0; i < 2000; i++) ;
    puts_("seip-ids "); put_dec(seip_n); putc_(' '); put_dec(seip_ids[0]); put_dec(seip_ids[1]); putc_('\n');
    puts_("mctx "); put_dec(PL_CCM); putc_('\n');                                  /* context M khong thay nguon nao */
    puts_("P2\n");
    for (volatile u32 i = 0; i < 2000; i++) ;
    PL_CCS = 4; PL_CCS = 5;
    for (volatile u32 i = 0; i < 2000; i++) ;
    puts_("done "); put_dec(seip_n); putc_(' '); put_dec(PL_CCS); putc_('\n');
    puts_("OK\n");
    sbi_fn = 3; sbi_arg = 0; __asm__ volatile ("ecall" ::: "memory");
}

int main(void) {
    u32 rp = (u32)root, lp = (u32)leaf;
    puts_("SU\n");
    root[0x000] = PTE(0x00000000u, V | R | X | A | D);               /* ROM danh tinh */
    root[0x008] = PTE(0x02000000u, V | R | W | A | D);               /* CLINT */
    root[0x030] = PTE(0x0C000000u, V | R | W | A | D);               /* PLIC */
    root[0x080] = PTE(0x20000000u, V | R | W | A | D);               /* ngoai vi */
    root[0x040] = PTE(0x10000000u, V | R | W | A | D);               /* RAM, chi S */
    root[0x110] = PTE(0x10000000u, V | R | W | U_ | A | D);          /* 0x4400_0000: RAM cho U */
    root[0x200] = PTE(0x00000000u, V | R | X | U_ | A | D);          /* 0x8000_0000: ROM cho U (chay ma U) */
    root[0x300] = PTE(lp, V);                                         /* 0xC000_0000: bang muc 0 */
    leaf[0] = PTE(rp, V | R | W | A | D);                             /* RW */
    leaf[1] = PTE(rp, V | R | A | D);                                 /* chi doc */
    leaf[2] = PTE(rp, V | R | W);                                     /* A = 0 */
    leaf[3] = PTE(rp, V | R | W | A);                                 /* D = 0 */
    leaf[4] = PTE(rp, V | R | W | U_ | A | D);                        /* trang U */
    CL_CMPH = 0xFFFFFFFFu; CL_CMPL = 0xFFFFFFFFu;
    CL_TH = 7;                                                         /* mtime hi doc / ghi duoc; ghi vao dia chi trong cua so nhung khong phai thanh ghi bi bo qua */
    REG(0x02000008u) = 0x55u; REG(0x02004008u) = 0x66u; REG(0x0200BFF0u) = 0x77u; REG(0x0200BFC0u) = 0x88u; REG(0x0200FFFCu) = 0x99u;
    puts_("clint "); put_hex(CL_TH); putc_(' '); put_hex(CL_CMPH); putc_(' '); put_dec(MSIP); putc_('\n');
    csr_write(pmpaddr0, 0xFFFFFFFFu); csr_write(pmpcfg0, 0x1Fu);      /* NAPOT toan bo, RWX */
    csr_write(medeleg, (1u << 8) | (1u << 12) | (1u << 13) | (1u << 15));
    csr_write(mideleg, 0x222u);
    csr_write(stvec, (u32)strap_entry);
    csr_write(mie, MIE_MSIE | MIE_MTIE);
    sync_io();
    csr_write(satp, 0x80000000u | (rp >> 12));
    __asm__ volatile ("sfence.vma zero,zero");
    csr_clear(mstatus, 0x1800u); csr_set(mstatus, 0x0800u);          /* MPP = S */
    csr_write(mepc, (u32)s_main);
    __asm__ volatile ("mret");
    return 1;
}
