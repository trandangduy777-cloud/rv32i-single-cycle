#include "soc.h"
/* PLIC o muc he thong: 4 nguon ngoai (ID 4..7, testbench scenario 4 keo ext_irq len muc cao khi thay "P1", ha khi thay "P2") voi
   uu tien 2, 5, 5, 1. Kiem: pending, thu tu claim theo uu tien (hoa -> ID nho), nguon dang xu ly khong bao ngat lai, complete + nguon
   van cao -> ngat lai, threshold, pending giu khi nguon ha, claim muon sau khi doi threshold. */
volatile u32 n, order[8];
void trap_c(void) {
    u32 c = csr_read(mcause), id;
    if (c != 0x8000000Bu) die(0xBAD00000u | (c & 0xFFFF));
    while ((id = PLIC_CLAIM) != 0) order[n++ & 7] = id;      /* chi claim, chua complete */
}
int main(void) {
    PLIC_PRIO(4) = 2; PLIC_PRIO(5) = 5; PLIC_PRIO(6) = 5; PLIC_PRIO(7) = 1;
    PLIC_EN = 0xF0; PLIC_THR = 0;
    puts_("P1\n");
    wait_mtime(300);
    puts_("pend="); put_hex(PLIC_PEND); putc_('\n');
    csr_write(mie, MIE_MEIE); csr_set(mstatus, MSTATUS_MIE);
    WAIT_IRQ(n >= 4);
    csr_clear(mstatus, MSTATUS_MIE);
    puts_("order=");
    for (u32 i = 0; i < 4; i++) put_dec(order[i]);
    putc_('\n');
    wait_mtime(300);
    u32 g = PLIC_CLAIM;                                       /* ca 4 nguon dang xu ly: khong con gi de claim */
    puts_("again="); put_dec(g); putc_('\n');
    PLIC_CLAIM = 5; PLIC_CLAIM = 6; PLIC_CLAIM = 4; PLIC_CLAIM = 7;   /* complete ca 4, nguon van cao: pending lai */
    wait_mtime(300);
    PLIC_THR = 2;                                             /* chi uu tien > 2 */
    u32 a = PLIC_CLAIM, b = PLIC_CLAIM, d = PLIC_CLAIM;
    puts_("thr2="); put_dec(a); putc_(','); put_dec(b); putc_(','); put_dec(d); putc_('\n');
    puts_("P2\n");                                            /* tb ha ext_irq */
    wait_mtime(300);
    puts_("pend2="); put_hex(PLIC_PEND); putc_('\n');         /* 4, 7 van pending du nguon da ha; 5, 6 dang xu ly */
    PLIC_THR = 0;
    a = PLIC_CLAIM; b = PLIC_CLAIM; d = PLIC_CLAIM;
    puts_("late="); put_dec(a); putc_(','); put_dec(b); putc_(','); put_dec(d); putc_('\n');
    PLIC_CLAIM = 5; PLIC_CLAIM = 6; PLIC_CLAIM = 4; PLIC_CLAIM = 7;
    wait_mtime(300);
    puts_("idle="); put_dec(PLIC_CLAIM); putc_(' '); put_hex(PLIC_PEND); putc_('\n');
    puts_("OK\n");
    return 0;
}
