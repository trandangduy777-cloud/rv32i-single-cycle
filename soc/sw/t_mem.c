#include "soc.h"
/* Bo nho va bus: .data / .bss / .rodata, RAM theo byte-lane, ghi ROM va truy cap ngoai vung (dem BUSERR), SCRATCH, ghi byte vao thanh ghi. */
volatile u32 init_word = 0xCAFEBABEu;
volatile u8  init_bytes[4] = {1, 2, 3, 4};
volatile u32 zero_arr[8];
static const u32 rom_const[4] = {0x11111111u, 0x22222222u, 0x33333333u, 0x44444444u};
static int fails;
static volatile u32 resume_pc, trap_n, trap_cause, trap_pc;
void trap_c(void) {                      /* chi dung cho thu fetch ngoai ROM: ghi lai roi tiep tuc o resume_pc */
    trap_n++; trap_cause = csr_read(mcause); trap_pc = csr_read(mepc);
    csr_write(mepc, resume_pc);
}
static volatile u32 *at(u32 a) { volatile u32 *p = (volatile u32 *)a; __asm__ ("" : "+r"(p)); return p; }   /* tranh canh bao dia chi gan 0 */
static void chk(const char *name, u32 got, u32 want) {
    if (got != want) { fails++; puts_("FAIL "); puts_(name); putc_(' '); put_hex(got); putc_(' '); put_hex(want); putc_('\n'); }
}
int main(void) {
    chk("data", init_word, 0xCAFEBABEu);
    chk("bytes", *(volatile u32 *)init_bytes, 0x04030201u);
    u32 s = 0; for (int i = 0; i < 8; i++) s |= zero_arr[i];
    chk("bss", s, 0);
    chk("rodata", rom_const[0] + rom_const[3], 0x55555555u);

    volatile u32 *r = (volatile u32 *)0x10001000u;          /* RAM */
    r[0] = 0xFFFFFFFFu;
    ((volatile u8 *)r)[1] = 0x12;
    chk("sb", r[0], 0xFFFF12FFu);
    ((volatile unsigned short *)r)[1] = 0xABCD;
    chk("sh", r[0], 0xABCD12FFu);
    r[1] = 0x01020304u; r[255] = 0xA5A5A5A5u; r[2] = 7;
    chk("w1", r[1], 0x01020304u);
    chk("wlast", r[255], 0xA5A5A5A5u);
    chk("w2", r[2], 7);
    chk("lb", (u32)(int)(signed char)((volatile u8 *)r)[7], 0x01);
    chk("lhu", ((volatile unsigned short *)r)[2], 0x0304);

    /* BUSERR dem truy cap sai */
    SYS_BUSERR = 0;
    chk("be0", SYS_BUSERR, 0);
    volatile u32 *rom = at(0x00000100u);
    u32 old = *rom;
    *rom = ~old;                                             /* ghi ROM: bo qua + dem */
    chk("rom_ro", *rom, old);
    chk("be1", SYS_BUSERR, 1);
    chk("unm_rd", *(volatile u32 *)0x30000000u, 0);          /* doc ngoai vung: 0 + dem */
    *(volatile u32 *)0x10004000u = 5;                        /* sau het RAM: bo qua + dem */
    chk("be3", SYS_BUSERR, 3);
    chk("ram_alias", *(volatile u32 *)0x10004000u, 0);
    *(volatile u32 *)0x02000040u = 5;                        /* sau 32 byte CLINT: khong anh xa lai */
    chk("be5", SYS_BUSERR, 5);
    chk("uart_win", *(volatile u32 *)0x20000FF0u, 0);        /* cuoi cua so UART: doc 0 va khong dem */
    chk("gap", *(volatile u32 *)0x20003000u, 0);
    chk("be6", SYS_BUSERR, 6);                               /* 0x20003000 la ngoai vung */
    SYS_BUSERR = 0;
    chk("be_clr", SYS_BUSERR, 0);

    /* SCRATCH theo byte-lane */
    SYS_SCRATCH = 0x11223344u;
    REG8(SYS_BASE + 5) = 0xAA;
    chk("scr_b", SYS_SCRATCH, 0x1122AA44u);
    REG16(SYS_BASE + 6) = 0xBEEF;
    chk("scr_h", SYS_SCRATCH, 0xBEEFAA44u);
    chk("id", SYS_ID, 0x52563C01u);

    /* fetch ngoai ROM va RAM (cua so UART, vung trong): lenh doc ra 0 -> trap lenh khong hop le, mepc = dia chi nhay toi */
    for (u32 i = 0; i < 2; i++) {
        u32 tgt = i ? 0x30000000u : 0x20000000u;
        __asm__ volatile ("lla t0, 1f\n sw t0, 0(%0)\n jr %1\n 1:" :: "r"(&resume_pc), "r"(tgt) : "t0", "memory");
        chk("fetch_cause", trap_cause, 2);
        chk("fetch_pc", trap_pc, tgt);
        chk("fetch_n", trap_n, i + 1);
    }
    puts_(fails ? "MEM FAIL\n" : "MEM OK\n");
    return fails;
}
