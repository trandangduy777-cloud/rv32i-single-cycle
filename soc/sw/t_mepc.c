#include "soc.h"
/* mepc voi lenh nen: ngat, ECALL, C.EBREAK roi vao dung lenh o dia chi 2 mod 4 thi MRET phai quay lai dung cho cu (loi cu cua loi: mepc chi luu bit [31:2]);
   ghi/doc CSR mepc giu bit 1 va xoa bit 0. */
volatile u32 got_irq, got_ecall, got_ebreak, mepc_irq, mepc_ecall, mepc_ebreak;
void trap_c(void) {
    u32 c = csr_read(mcause), e = csr_read(mepc);
    if (c == 0x80000003u) { got_irq++; mepc_irq = e; MSIP = 0; }
    else if (c == 11) { got_ecall++; mepc_ecall = e; csr_write(mepc, e + 4); }
    else if (c == 3)  { got_ebreak++; mepc_ebreak = e; csr_write(mepc, e + 2); }
    else die(0xBAD00000u | (c & 0xFFFF));
}
int main(void) {
    u32 a_irq, a_ecall, a_ebreak;
    /* 1. ngat phan mem dang cho, bat MIE bang CSRRS o 2 mod 4: ngat roi vao c.nop dau tien sau CSRRS (dia chi 2 mod 4 + 4 = 2 mod 4) */
    csr_write(mie, MIE_MSIE);
    MSIP = 1;
    __asm__ volatile (
        ".option push\n.option rvc\n.balign 4\n"
        "c.nop\n"
        "csrs mstatus, %1\n"
        "1: c.nop\n c.nop\n c.nop\n"
        "lla %0, 1b\n"
        ".option pop\n" : "=r"(a_irq) : "r"(MSTATUS_MIE) : "memory");
    csr_clear(mstatus, MSTATUS_MIE);
    puts_((got_irq == 1 && mepc_irq == a_irq && (a_irq & 3) == 2) ? "irq ok\n" : "irq BAD\n");
    if (!(got_irq == 1 && mepc_irq == a_irq)) { put_hex(mepc_irq); putc_(' '); put_hex(a_irq); putc_('\n'); }

    /* 2. ECALL (4 byte) o 2 mod 4: handler cong mepc 4, chay tiep ngay sau */
    __asm__ volatile (
        ".option push\n.option rvc\n.balign 4\n"
        "c.nop\n"
        "1: ecall\n"
        "c.nop\n"
        "lla %0, 1b\n"
        ".option pop\n" : "=r"(a_ecall) : : "memory");
    puts_((got_ecall == 1 && mepc_ecall == a_ecall && (a_ecall & 3) == 2) ? "ecall ok\n" : "ecall BAD\n");

    /* 3. C.EBREAK (2 byte) o 2 mod 4 */
    __asm__ volatile (
        ".option push\n.option rvc\n.balign 4\n"
        "c.nop\n"
        "1: c.ebreak\n"
        "c.nop\n"
        "lla %0, 1b\n"
        ".option pop\n" : "=r"(a_ebreak) : : "memory");
    puts_((got_ebreak == 1 && mepc_ebreak == a_ebreak && (a_ebreak & 3) == 2) ? "ebreak ok\n" : "ebreak BAD\n");

    /* 4. CSR mepc: bit 1 ghi/doc duoc, bit 0 luon 0 */
    csr_write(mepc, 0x0000123Fu);
    u32 v = csr_read(mepc);
    puts_(v == 0x0000123Eu ? "csr ok\n" : "csr BAD\n");
    return 0;
}
