#include "soc.h"
/* Chay lenh tu RAM: nap ma may (lenh nen + lenh 32 bit vat qua ranh gioi tu) vao RAM luc chay, goi qua con tro ham, tu sua ma + FENCE.I,
   va ngat timer roi vao giua vong lap nam trong RAM (mepc nam trong RAM, o dia chi 0 hoac 2 mod 4): vong lap phai dem du 8192 lan. */
#define RAMC ((volatile unsigned short *)0x10002000u)
typedef u32 (*fn_t)(void);
static const unsigned short A[] = { 0x4515, 0x050D, 0x050A, 0x8082 };                       /* c.li a0,5; c.addi a0,3; c.slli a0,2; c.jr ra -> 32 */
static const unsigned short B[] = { 0x4515, 0x050D, 0x0513, 0x0645, 0x8082 };               /* ... addi a0,a0,100 (32 bit, vat o duoi tu) -> 108 */
static const unsigned short L[] = { 0x4581, 0x6509, 0x157D, 0x0585, 0xFD75, 0x852E, 0x8082 }; /* c.li a1,0; lui a0,2; {c.addi a0,-1; c.addi a1,1; c.bnez} ; c.mv a0,a1; ret */
volatile u32 got_irq, mepc_irq;
void trap_c(void) {
    u32 c = csr_read(mcause);
    if (c == 0x80000007u) {
        got_irq++; mepc_irq = csr_read(mepc);
        MTIMECMP_HI = 0xFFFFFFFFu; MTIMECMP_LO = 0xFFFFFFFFu;
    } else die(0xBAD00000u | (c & 0xFFFF));
}
static fn_t load(const unsigned short *code, int n, u32 byte_off) {
    for (int i = 0; i < n; i++) RAMC[byte_off / 2 + i] = code[i];
    __asm__ volatile (".option push\n.option arch, +zifencei\nfence.i\n.option pop" ::: "memory");
    return (fn_t)(0x10002000u + byte_off);
}
static void res(const char *what, u32 got, u32 want) {
    puts_(what); puts_(got == want ? " ok\n" : " BAD ");
    if (got != want) { put_hex(got); putc_(' '); put_hex(want); putc_('\n'); }
}
int main(void) {
    res("ram4", load(A, 4, 0)(), 32);
    res("ram2", load(A, 4, 2)(), 32);                       /* bat dau o 2 mod 4 */
    res("strad", load(B, 5, 2)(), 108);                     /* lenh 32 bit vat qua ranh gioi tu trong RAM */
    res("strad0", load(B, 5, 0)(), 108);
    fn_t f = load(A, 4, 2);
    f();
    RAMC[1] = 0x4519;                                       /* sua c.li a0,5 thanh c.li a0,6 (o byte 2 cua RAM + 2) */
    __asm__ volatile (".option push\n.option arch, +zifencei\nfence.i\n.option pop" ::: "memory");
    res("smc", f(), 36);                                    /* (6 + 3) << 2 */

    /* ngat timer giua vong lap trong RAM: 8192 vong, ngat o nhieu thoi diem; mepc trong vong lap, ket qua van dung 8192 */
    static const u32 delay[] = { 211, 503, 997, 1511, 2003, 2999, 4001, 5009 };
    u32 n2 = 0, bad = 0;
    for (int i = 0; i < 8; i++) {
        u32 off = (i & 1) ? 2 : 0;
        fn_t g = load(L, 7, off);
        got_irq = 0; MTIMECMP_HI = 0; MTIMECMP_LO = MTIME_LO + delay[i];
        csr_write(mie, MIE_MTIE); csr_set(mstatus, MSTATUS_MIE);
        u32 r = g();
        csr_clear(mstatus, MSTATUS_MIE);
        u32 lo = 0x10002000u + off + 4, hi = 0x10002000u + off + 12;          /* lenh dau vong .. lenh cuoi vong */
        if (r != 8192 || got_irq != 1 || mepc_irq < lo || mepc_irq > hi) {
            bad++; put_hex(i); putc_(' '); put_hex(r); putc_(' '); put_hex(got_irq); putc_(' '); put_hex(mepc_irq); putc_('\n');
        }
        if ((mepc_irq & 3) == 2) n2++;
    }
    res("irq_loop", bad, 0);
    res("irq_2mod4", n2 != 0, 1);                           /* it nhat mot lan ngat roi vao lenh o dia chi 2 mod 4 trong RAM */
    return 0;
}
