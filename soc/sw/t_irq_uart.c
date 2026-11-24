#include "soc.h"
/* Ngat ngoai tu UART qua PLIC (nguon 1 = RX, 2 = TX san sang): RX ngat nhan ky tu vao bo dem vong, TX ngat gui chuoi (ISR cap nhat ky tu tiep theo).
   Testbench (scenario 3) gui "ping\n" khi thay "RDY". */
volatile u32 rx_n, tx_i, tx_done;
volatile char rxbuf[16];
static const char msg[] = "tx by irq\n";
void trap_c(void) {
    u32 c = csr_read(mcause);
    if (c != 0x8000000Bu) die(0xBAD00000u | (c & 0xFFFF));
    u32 id;
    while ((id = PLIC_CLAIM) != 0) {                       /* claim: moi nguon mot lan, xong thi complete */
        if (id == IRQ_UART_RX) { rxbuf[rx_n & 15] = (char)UART_RXDATA; rx_n++; }
        else if (id == IRQ_UART_TX) {
            if (msg[tx_i]) UART_TXDATA = (u8)msg[tx_i++];
            else { UART_IE &= ~2u; tx_done = 1; }
        } else die(0xBAD10000u | id);
        PLIC_CLAIM = id;
    }
}
int main(void) {
    PLIC_PRIO(IRQ_UART_RX) = 2; PLIC_PRIO(IRQ_UART_TX) = 1; PLIC_EN = (1u << IRQ_UART_RX) | (1u << IRQ_UART_TX); PLIC_THR = 0;
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
