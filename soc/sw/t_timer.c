#include "soc.h"
/* CLINT: mtime tang don dieu moi chu ky, ngat timer dinh ky (mtimecmp += PERIOD trong ISR) khong den som va tre it,
   ngat phan mem qua MSIP, thu tu uu tien khi ca hai cung cho (phan mem 3 truoc timer 7). */
volatile u32 ticks, soft, early, late, seq[2], nseq;
#define PERIOD 200u
void trap_c(void) {
    u32 c = csr_read(mcause);
    if (nseq < 2) seq[nseq++] = c & 0xF;
    if (c == 0x80000007u) {
        u32 cmp = MTIMECMP_LO, now = MTIME_LO;
        if (ticks < 6) {
            if (now < cmp) early++;
            if (now - cmp > T_LAT_MAX) late++;
        }
        if (ticks < 5) MTIMECMP_LO = cmp + PERIOD;                      /* ngat thu 1..5 nap lai; ngat thu 6 (va sau do) cam mtimecmp */
        else { MTIMECMP_HI = 0xFFFFFFFFu; MTIMECMP_LO = 0xFFFFFFFFu; }
        ticks++;
    } else if (c == 0x80000003u) {
        soft++; MSIP = 0;
    } else die(0xBAD00000u | (c & 0xFFFF));
}
int main(void) {
    u32 a = MTIME_LO; wait_mtime(10); u32 b = MTIME_LO;
    puts_((b - a >= 10 && b - a < T_WAIT_MAX) ? "mtime ok\n" : "mtime BAD\n");

    MTIMECMP_HI = 0; MTIMECMP_LO = MTIME_LO + PERIOD;
    sync_io();
    csr_write(mie, MIE_MTIE);
    u32 t0 = MTIME_LO;
    WAIT_IRQ(ticks >= 6);
    u32 span = MTIME_LO - t0;
    puts_("ticks="); put_dec(ticks);
    puts_(" early="); put_dec(early); puts_(" late="); put_dec(late);
    if (span >= 6 * PERIOD - 30 && span < 6 * PERIOD + T_SPAN_SLACK) puts_(" span ok\n");
    else { puts_(" span BAD "); put_dec(span); putc_('\n'); }

    csr_write(mie, MIE_MSIE);
    MSIP = 1;
    WAIT_IRQ(soft);
    puts_("soft="); put_dec(soft); puts_(" msip="); put_dec(MSIP); putc_('\n');

    /* ca hai cung cho khi bat MIE: phan mem truoc, timer sau */
    soft = 0; ticks = 100; nseq = 0;
    csr_clear(mstatus, MSTATUS_MIE);
    csr_write(mie, MIE_MSIE | MIE_MTIE);
    MTIMECMP_HI = 0; MTIMECMP_LO = 0; MSIP = 1;
    WAIT_IRQ(soft && ticks != 100);
    puts_("both order="); put_dec(seq[0]); putc_(','); put_dec(seq[1]);
    puts_(" soft="); put_dec(soft); puts_(" ticks="); put_dec(ticks); putc_('\n');
    return 0;
}
