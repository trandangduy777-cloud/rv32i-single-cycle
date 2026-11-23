#include "soc.h"
/* Ngat ngoai tu UART (irq_ext): RX ngat nhan ky tu vao bo dem vong, TX ngat gui chuoi (ISR cap nhat ky tu tiep theo).
   Testbench (scenario 3) gui "ping\n" khi thay "RDY". */
volatile u32 rx_n, tx_i, tx_done;
volatile char rxbuf[16];
static const char msg[] = "tx by irq\n";
void trap_c(void) {
    u32 c = csr_read(mcause);
    if (c != 0x8000000Bu) die(0xBAD00000u | (c & 0xFFFF));
    u32 st = UART_STATUS;
    if (st & ST_RXVALID) { rxbuf[rx_n & 15] = (char)UART_RXDATA; rx_n++; }
    if ((UART_IE & 2) && (st & ST_TXREADY)) {
        if (msg[tx_i]) UART_TXDATA = (u8)msg[tx_i++];
        else { UART_IE &= ~2u; tx_done = 1; }
    }
}
int main(void) {
    csr_write(mie, MIE_MEIE); csr_set(mstatus, MSTATUS_MIE);
    UART_IE = 1;
    puts_("RDY\n");
    WAIT_IRQ(rx_n >= 5);
    UART_IE = 0;
    puts_("rx=");
    for (u32 i = 0; i < rx_n; i++) { char ch = rxbuf[i]; if (ch != '\n') putc_(ch); }
    puts_(" n="); put_dec(rx_n); putc_('\n');
    UART_IE = 2;                                   /* gui chuoi bang ngat TX: ISR lo toan bo */
    WAIT_IRQ(tx_done);
    while (!(UART_STATUS & ST_TXREADY)) ;
    puts_("done\n");
    return 0;
}
