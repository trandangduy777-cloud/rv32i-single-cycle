#include "soc.h"
/* UART: DIV (nho nhat, theo byte-lane, doi DIV tren duong day), TXDROP, nhan voi overrun / loi khung, echo.
   Testbench (scenario 1) chuyen do dai bit mong doi khi thay "D24"/"D16" va gui du lieu khi thay "R1", "R2", "R3" trong luong TX. */
static void wait_rx(void) { while (!(UART_STATUS & ST_RXVALID)) ; }
static void tx_idle(void) { while (!(UART_STATUS & ST_TXREADY)) ; }
int main(void) {
    puts_("DIV="); put_dec(UART_DIV); putc_('\n');
    tx_idle();
    UART_DIV = 2; u32 m = UART_DIV; UART_DIV = 16;                     /* nho hon 4 thi lay 4 */
    puts_("min="); put_dec(m); putc_('\n');
    tx_idle();
    REG8(UART_BASE + 0xD) = 0x01; u32 d = UART_DIV; UART_DIV = 16;     /* ghi byte cao: DIV = 0x0110 */
    puts_("hi="); put_hex(d); putc_('\n');

    puts_("D24\n"); tx_idle(); UART_DIV = 24;                          /* doi toc do tren duong day */
    puts_("div24 ok\n");
    puts_("D16\n"); tx_idle(); UART_DIV = 16;

    UART_STATUS = ST_TXDROP;
    UART_TXDATA = 'X';
    UART_TXDATA = 'Y';                                                 /* dang ban: bi bo, dat TXDROP */
    tx_idle();
    puts_("\ndrop="); put_dec((UART_STATUS >> 4) & 1);
    UART_STATUS = ST_TXDROP;
    puts_(" cleared="); put_dec((UART_STATUS >> 4) & 1); putc_('\n');

    /* pha 1: overrun, 3 byte lien tiep, khong doc */
    puts_("R1\n");
    wait_mtime(3000);
    u32 st = UART_STATUS;
    puts_("st="); put_hex(st & 0x1F);
    UART_RXDATA = 0x7F;                                                /* ghi RXDATA bi bo qua: khong pop */
    puts_(" keep="); put_dec((UART_STATUS >> 1) & 1);
    u32 first = UART_RXDATA;
    puts_(" got="); putc_(first); putc_('\n');
    UART_STATUS = ST_RXOVR;
    puts_("ovr_clr="); put_dec((UART_STATUS >> 2) & 1);
    puts_(" valid="); put_dec((UART_STATUS >> 1) & 1); putc_('\n');

    /* pha 2: loi khung */
    puts_("R2\n");
    wait_rx();
    st = UART_STATUS; u32 q = UART_RXDATA;
    puts_("ferr="); put_dec((st >> 3) & 1); puts_(" byte="); putc_(q); putc_('\n');
    UART_STATUS = ST_RXFERR;

    /* pha 3: echo chu hoa den het dong */
    puts_("R3\n");
    for (;;) {
        wait_rx();
        u32 c = UART_RXDATA;
        if (c == '\n') break;
        putc_((c >= 'a' && c <= 'z') ? c - 32 : c);
    }
    puts_("\nOK\n");
    return 0;
}
