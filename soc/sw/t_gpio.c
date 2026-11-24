#include "soc.h"
/* GPIO: huong, doc lai o chan, SET/CLR/TGL, ghi theo byte-lane, ngat canh len / xuong qua irq_ext (ISR xoa PEND).
   Testbench (scenario 2) doi chan ngoai khi thay dau nhac "G1", "G2", "G3". */
volatile u32 irqs, last_pend;
void trap_c(void) {
    u32 c = csr_read(mcause);
    if (c == 0x8000000Bu) {
        u32 id = PLIC_CLAIM;                              /* claim qua PLIC */
        if (id == IRQ_GPIO) { last_pend = GPIO_PEND; GPIO_PEND = last_pend; irqs++; }
        else die(0xBAD10000u | id);
        PLIC_CLAIM = id;                                  /* complete */
    }
    else die(0xBAD00000u | (c & 0xFFFF));
}
int main(void) {
    GPIO_DIR = 0x00FF;                       /* 8 chan thap la xuat */
    GPIO_OUT = 0x00A5;
    puts_("out="); put_hex(GPIO_IN & 0xFFFF);        /* chan xuat doc lai gia tri, chan vao = 0 luc dau */
    GPIO_SET = 0x0F00 | 0x0002; GPIO_CLR = 0x0004; GPIO_TGL = 0x0081;
    puts_(" out2="); put_hex(GPIO_OUT);
    REG8(GPIO_BASE + 1) = 0x3C;               /* byte 1 cua OUT */
    puts_(" out3="); put_hex(GPIO_OUT);
    REG8(GPIO_BASE + 0x08) = 0xF0;            /* DIR byte thap chi doi 8 bit */
    puts_(" dir="); put_hex(GPIO_DIR); putc_('\n');
    GPIO_DIR = 0x00FF; GPIO_OUT = 0;

    puts_("G1\n");                            /* testbench dua chan 12 len cao */
    wait_mtime(300);
    puts_("in="); put_hex(GPIO_IN & 0xFF00); putc_('\n');

    /* ngat canh len chan 12 va canh xuong chan 13 */
    GPIO_EDGE = 1u << 13; GPIO_PEND = 0xFFFF; GPIO_IE = (1u << 12) | (1u << 13);
    PLIC_PRIO(IRQ_GPIO) = 1; PLIC_EN = 1u << IRQ_GPIO; PLIC_THR = 0;
    csr_write(mie, MIE_MEIE); csr_set(mstatus, MSTATUS_MIE);
    puts_("G2\n");                            /* tb: chan 12 xuong roi len (chi canh len tinh), chan 13 len roi xuong */
    WAIT_IRQ(irqs >= 2);
    wait_mtime(300);
    puts_("irqs="); put_dec(irqs); puts_(" pend="); put_hex(last_pend); puts_(" now="); put_hex(GPIO_PEND); putc_('\n');
    csr_clear(mstatus, MSTATUS_MIE);
    /* PEND giu su kien khi chua cho phep; xoa W1C theo tung chan */
    GPIO_IE = 0;
    puts_("G3\n");                            /* tb: chan 12 xuong roi len lan nua */
    wait_mtime(300);
    puts_("pend="); put_hex(GPIO_PEND);
    GPIO_PEND = 1u << 13;
    puts_(" after="); put_hex(GPIO_PEND); putc_('\n');
    return 0;
}
