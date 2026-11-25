#include "soc.h"
/* DMA 2 kenh tren SoC AXI4: burst INCR, buoc dia chi (stride), nguon / dich co dinh (FIXED), loi DECERR / SLVERR, qua cau ngoai vi, do toc do so voi CPU,
   hai kenh cung chay khi loi van tinh toan, ngat qua PLIC (nguon 8, 9). Bo dem trong RAM 0x1000_xxxx; CPU doc ket qua qua bi danh 0x4000_xxxx (khong qua cache). */
#define N 256u
static u32 a[N], b[N], c[N];
static u32 big[2400];                                   /* 9600 byte: chua chac chan 1 ranh gioi 4 KB cho thu burst khong duoc vuot 4 KB */
volatile u32 done0, done1, spur, work;

void trap_c(void) {
    u32 cause = csr_read(mcause), id;
    if (cause != 0x8000000Bu) die(0xBAD00000u | (cause & 0xFFFF));
    while ((id = PLIC_CLAIM) != 0) {
        if (id == IRQ_DMA0) { DMA_REG(0, DMA_STAT) = 2; done0++; }       /* xoa DONE */
        else if (id == IRQ_DMA1) { DMA_REG(1, DMA_STAT) = 2; done1++; }
        else spur++;
        PLIC_CLAIM = id;
    }
}

static void dma_cfg(u32 ch, u32 src, u32 dst, u32 len, u32 ss, u32 ds) {
    DMA_REG(ch, DMA_SRC) = src; DMA_REG(ch, DMA_DST) = dst; DMA_REG(ch, DMA_LEN) = len; DMA_REG(ch, DMA_SS) = ss; DMA_REG(ch, DMA_DS) = ds;
}
static u32 dma_wait(u32 ch) { u32 s; while ((s = DMA_REG(ch, DMA_STAT)) & 1u) ; return s; }
static void fill(volatile u32 *p, u32 n, u32 v) { for (u32 i = 0; i < n; i++) p[i] = v; }
static u32 alias_eq(volatile u32 *p, u32 i, u32 v) { return RAM_ALIAS(p)[i] == v; }

int main(void) {
    u32 i, ok, t0, t1, cpu, dm, st;
    for (i = 0; i < N; i++) a[i] = 0x1000u + i * 7u;
    fill(b, N, 0); fill(c, N, 0);
    sync_io();

    /* 1. chep 64 tu bang burst INCR (toi da 16 beat moi manh) */
    t0 = csr_read(mcycle);
    dma_cfg(0, (u32)a, (u32)b, 64, 4, 4); DMA_REG(0, DMA_CTRL) = 1;
    st = dma_wait(0);
    t1 = csr_read(mcycle); dm = t1 - t0;
    for (ok = 1, i = 0; i < 64; i++) ok &= alias_eq(b, i, 0x1000u + i * 7u);
    ok &= alias_eq(b, 64, 0);                                             /* khong ghi lan */
    puts_((ok && st == 2 && DMA_REG(0, DMA_LEN) == 0) ? "D1 ok\n" : "D1 BAD\n");
    DMA_REG(0, DMA_STAT) = 2;

    /* 2. toc do: cung viec do bang vong lap CPU (doc qua cache, ghi xuyen) */
    fill(c, N, 0); sync_io();
    t0 = csr_read(mcycle);
    for (i = 0; i < 64; i++) c[i] = a[i];
    sync_io();
    t1 = csr_read(mcycle); cpu = t1 - t0;
    puts_("CYC cpu="); put_dec(cpu); puts_(" dma="); put_dec(dm); putc_('\n');
    puts_(dm * 2 < cpu ? "SPEED OK\n" : "SPEED BAD\n");

    /* 3. scatter: nguon buoc 4, dich buoc 8 (giao dich tung tu) */
    fill(b, N, 0); sync_io();
    dma_cfg(0, (u32)a, (u32)b, 16, 4, 8); DMA_REG(0, DMA_CTRL) = 1; dma_wait(0); DMA_REG(0, DMA_STAT) = 2;
    for (ok = 1, i = 0; i < 16; i++) ok &= alias_eq(b, 2 * i, 0x1000u + i * 7u) & alias_eq(b, 2 * i + 1, 0);
    /* 3b. gather: nguon buoc 8 (chi lay tu chan), dich buoc 4 (giao dich tung tu, kenh 1) */
    fill(b, N, 0); sync_io();
    dma_cfg(1, (u32)a, (u32)b, 16, 8, 4); DMA_REG(1, DMA_CTRL) = 1; dma_wait(1); DMA_REG(1, DMA_STAT) = 2;
    for (i = 0; i < 16; i++) ok &= alias_eq(b, i, 0x1000u + 2u * i * 7u);
    ok &= alias_eq(b, 16, 0);
    puts_(ok ? "D3 ok\n" : "D3 BAD\n");

    /* 4. nguon co dinh (burst FIXED) dien hang so; dich co dinh giu tu cuoi */
    fill(b, N, 0); sync_io();
    dma_cfg(1, (u32)a, (u32)b, 20, 0, 4); DMA_REG(1, DMA_CTRL) = 1; dma_wait(1); DMA_REG(1, DMA_STAT) = 2;
    for (ok = 1, i = 0; i < 20; i++) ok &= alias_eq(b, i, 0x1000u);
    ok &= alias_eq(b, 20, 0);
    dma_cfg(1, (u32)a, (u32)b, 8, 4, 0); DMA_REG(1, DMA_CTRL) = 1; dma_wait(1); DMA_REG(1, DMA_STAT) = 2;
    ok &= alias_eq(b, 0, 0x1000u + 7u * 7u);
    puts_(ok ? "D4 ok\n" : "D4 BAD\n");

    /* 5. loi: dich ngoai ban do (DECERR), dich la ROM (SLVERR), nguon ngoai ban do; sau do chay lai binh thuong */
    dma_cfg(0, (u32)a, 0x50000000u, 4, 4, 4); DMA_REG(0, DMA_CTRL) = 1; st = dma_wait(0); ok = (st & 4u) != 0; DMA_REG(0, DMA_STAT) = 4;
    dma_cfg(0, (u32)a, 0x00000100u, 4, 4, 4); DMA_REG(0, DMA_CTRL) = 1; st = dma_wait(0); ok &= (st & 4u) != 0; DMA_REG(0, DMA_STAT) = 4;
    dma_cfg(1, 0x50000000u, (u32)b, 4, 4, 4); DMA_REG(1, DMA_CTRL) = 1; st = dma_wait(1); ok &= (st & 4u) != 0; DMA_REG(1, DMA_STAT) = 4;
    dma_cfg(1, (u32)a, 0x20004000u, 2, 4, 4); DMA_REG(1, DMA_CTRL) = 1; st = dma_wait(1); ok &= (st & 4u) != 0; DMA_REG(1, DMA_STAT) = 4;   /* trong cua so cau ngoai vi, khong co ngoai vi: DECERR tu cau */
    ok &= (DMA_REG(0, DMA_STAT) == 0) && (DMA_REG(1, DMA_STAT) == 0);
    fill(b, N, 0); sync_io();
    dma_cfg(0, (u32)a, (u32)b, 8, 4, 4); DMA_REG(0, DMA_CTRL) = 1; st = dma_wait(0); DMA_REG(0, DMA_STAT) = 2;
    for (i = 0; i < 8; i++) ok &= alias_eq(b, i, 0x1000u + i * 7u);
    puts_((ok && st == 2) ? "D5 ok\n" : "D5 BAD\n");

    /* 6. qua ngoai vi: ghi FIXED 4 tu vao SYSCON.SCRATCH (cau AXI -> bus cu), doc FIXED lai vao RAM */
    SYS_SCRATCH = 0; sync_io();
    dma_cfg(0, (u32)a, SYS_SCRATCH_ADDR, 4, 4, 0); DMA_REG(0, DMA_CTRL) = 1; dma_wait(0); DMA_REG(0, DMA_STAT) = 2;
    ok = (SYS_SCRATCH == 0x1000u + 3u * 7u);
    fill(b, N, 0); sync_io();
    dma_cfg(1, SYS_SCRATCH_ADDR, (u32)b, 4, 0, 4); DMA_REG(1, DMA_CTRL) = 1; dma_wait(1); DMA_REG(1, DMA_STAT) = 2;
    for (i = 0; i < 4; i++) ok &= alias_eq(b, i, 0x1000u + 3u * 7u);
    a[0] = 0xA5A55A5Au; a[1] = 0x0F1E2D3Cu; sync_io();                       /* burst INCR 2 tu vao MTIMECMP_LO / HI qua cau (moi beat 1 truy cap ngoai vi), doc lai bang INCR */
    dma_cfg(0, (u32)a, CLINT_BASE + 8u, 2, 4, 4); DMA_REG(0, DMA_CTRL) = 1; dma_wait(0); DMA_REG(0, DMA_STAT) = 2;
    ok &= (MTIMECMP_LO == 0xA5A55A5Au) && (MTIMECMP_HI == 0x0F1E2D3Cu);
    fill(b, N, 0); sync_io();                                              /* doc lai burst INCR: hai tu phai khac nhau (bat loi khong tang dia chi ben cau) */
    dma_cfg(1, CLINT_BASE + 8u, (u32)b, 2, 4, 4); DMA_REG(1, DMA_CTRL) = 1; dma_wait(1); DMA_REG(1, DMA_STAT) = 2;
    ok &= alias_eq(b, 0, 0xA5A55A5Au) & alias_eq(b, 1, 0x0F1E2D3Cu);
    MTIMECMP_HI = 0xFFFFFFFFu; MTIMECMP_LO = 0xFFFFFFFFu;
    a[0] = 0x1000u; a[1] = 0x1007u; sync_io();
    puts_(ok ? "D6 ok\n" : "D6 BAD\n");

    /* 6b. do dai 0 xong ngay; thanh ghi CYCLES co gia tri */
    dma_cfg(0, (u32)a, (u32)b, 0, 4, 4); DMA_REG(0, DMA_CTRL) = 1;
    ok = (DMA_REG(0, DMA_STAT) == 2) && (DMA_REG(0, DMA_CYC) == 0); DMA_REG(0, DMA_STAT) = 2;
    dma_cfg(0, (u32)a, (u32)b, 32, 4, 4); DMA_REG(0, DMA_CTRL) = 1; dma_wait(0); DMA_REG(0, DMA_STAT) = 2;
    ok &= DMA_REG(0, DMA_CYC) > 20 && DMA_REG(0, DMA_CYC) < 400;
    puts_(ok ? "D6b ok\n" : "D6b BAD\n");

    /* 6c. burst khong duoc vuot ranh gioi 4 KB (bo kiem giao thuc cua testbench bat vi pham): nguon vat qua 1 ranh gioi, roi dich vat qua 1 ranh gioi */
    {
        u32 base = (u32)big, p = (base + 120u + 0xFFFu) & ~0xFFFu, p2 = p + 0x1000u, k;
        volatile u32 *bg = (volatile u32 *)big;
        for (k = 0; k < 64; k++) { bg[(p - 120u - base) / 4u + k] = 0x5000u + k; bg[(p + 256u - base) / 4u + k] = 0x6000u + k; }
        sync_io();
        dma_cfg(0, p - 120u, p2 + 256u, 64, 4, 4); DMA_REG(0, DMA_CTRL) = 1; dma_wait(0); DMA_REG(0, DMA_STAT) = 2;
        dma_cfg(1, p + 256u, p2 - 120u, 64, 4, 4); DMA_REG(1, DMA_CTRL) = 1; dma_wait(1); DMA_REG(1, DMA_STAT) = 2;
        for (ok = 1, k = 0; k < 64; k++)
            ok &= (RAM_ALIAS(big)[(p2 + 256u - base) / 4u + k] == 0x5000u + k) & (RAM_ALIAS(big)[(p2 - 120u - base) / 4u + k] == 0x6000u + k);
        puts_(ok ? "D8 ok\n" : "D8 BAD\n");
    }

    /* 7. 2 kenh cung chay + ngat PLIC, loi tinh toan trong luc do */
    fill(b, N, 0); fill(c, N, 0); sync_io();
    PLIC_PRIO(IRQ_DMA0) = 1; PLIC_PRIO(IRQ_DMA1) = 1; PLIC_EN = (1u << IRQ_DMA0) | (1u << IRQ_DMA1); PLIC_THR = 0;
    csr_write(mie, MIE_MEIE); csr_set(mstatus, MSTATUS_MIE);
    dma_cfg(0, (u32)a, (u32)b, 8, 4, 4); DMA_REG(0, DMA_CTRL) = 1; dma_wait(0);          /* IE = 0: xong nhung khong ngat du PLIC da bat */
    for (i = 0; i < 100; i++) work++;
    ok = (done0 == 0) && (DMA_REG(0, DMA_STAT) == 2); DMA_REG(0, DMA_STAT) = 2;
    puts_(ok ? "NOIE ok\n" : "NOIE BAD\n");
    dma_cfg(0, (u32)a, (u32)b, N, 4, 4); dma_cfg(1, (u32)a, (u32)c, N, 4, 4);
    DMA_REG(0, DMA_CTRL) = 3; DMA_REG(1, DMA_CTRL) = 3;
    u32 sum = 0;
    while (!(done0 && done1)) { work++; sum += work; }
    csr_clear(mstatus, MSTATUS_MIE);
    for (ok = 1, i = 0; i < N; i++) ok &= alias_eq(b, i, 0x1000u + i * 7u) & alias_eq(c, i, 0x1000u + i * 7u);
    puts_((ok && done0 == 1 && done1 == 1 && spur == 0) ? "D7 ok\n" : "D7 BAD\n");
    puts_(work > 20 ? "CONC ok\n" : "CONC BAD\n");
    { u32 y0 = DMA_REG(0, DMA_CYC), y1 = DMA_REG(1, DMA_CYC), df = y0 > y1 ? y0 - y1 : y1 - y0;   /* luan phien tung manh: hai kenh cung dai xong gan nhu cung luc */
      puts_(df < 100 ? "FAIR ok\n" : "FAIR BAD\n"); }
    (void)sum;
    puts_("OK\n");
    return 0;
}
