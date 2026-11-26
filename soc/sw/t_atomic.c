#include "soc.h"
/* Mo rong A tren SoC (SOC_A_EXT = 1, bien dich voi -march=rv32imac): 9 AMO so voi tham chieu C, LR / SC, ngat giua LR va SC (SC phai that bai),
   dem nguyen tu giua chuong trinh chinh va ISR (ngat khong duoc xen vao giua doc va ghi cua AMO), khoa swap voi ISR tranh khoa,
   LR / SC / AMO lech dia chi trap (cause 4 / 6, mtval = dia chi). */
typedef int s32;
#define AMO(name, ins) static inline u32 name(volatile u32 *p, u32 v) { u32 o; __asm__ volatile (ins " %0, %2, (%1)" : "=&r"(o) : "r"(p), "r"(v) : "memory"); return o; }
AMO(amo_swap, "amoswap.w") AMO(amo_add, "amoadd.w") AMO(amo_xor, "amoxor.w") AMO(amo_and, "amoand.w") AMO(amo_or, "amoor.w")
AMO(amo_min, "amomin.w") AMO(amo_max, "amomax.w") AMO(amo_minu, "amominu.w") AMO(amo_maxu, "amomaxu.w")
static inline u32 lr_w(volatile u32 *p) { u32 o; __asm__ volatile ("lr.w %0, (%1)" : "=&r"(o) : "r"(p) : "memory"); return o; }
static inline u32 sc_w(volatile u32 *p, u32 v) { u32 o; __asm__ volatile ("sc.w %0, %2, (%1)" : "=&r"(o) : "r"(p), "r"(v) : "memory"); return o; }

#define PERIOD 150u
volatile u32 ticks, timer_on, isr_amo, isr_lock_fail, cnt, lock, nex, ex_cause[4], ex_tval[4];
void trap_c(void) {
    u32 c = csr_read(mcause);
    if (c == 0x80000007u) {
        ticks++;
        if (timer_on) MTIMECMP_LO = MTIME_LO + PERIOD;
        else { MTIMECMP_HI = 0xFFFFFFFFu; MTIMECMP_LO = 0xFFFFFFFFu; }
        amo_add(&cnt, 1); isr_amo++;
        if (amo_swap(&lock, 1)) isr_lock_fail++; else amo_swap(&lock, 0);   /* khoa dang bi chuong trinh chinh giu: that bai, khong ghi de */
    } else if (c == 4 || c == 6) {
        if (nex < 4) { ex_cause[nex] = c; ex_tval[nex] = csr_read(mtval); nex++; }
        csr_write(mepc, csr_read(mepc) + 4);                                  /* LR / SC / AMO luon 4 byte */
    } else die(0xBAD00000u | (c & 0xFFFF));
}
static void timer_start(void) { timer_on = 1; MTIMECMP_HI = 0; MTIMECMP_LO = MTIME_LO + PERIOD; sync_io(); csr_write(mie, MIE_MTIE); }
static void timer_stop(void)  { timer_on = 0; csr_clear(mstatus, MSTATUS_MIE); csr_write(mie, 0); MTIMECMP_HI = 0xFFFFFFFFu; MTIMECMP_LO = 0xFFFFFFFFu; sync_io(); }

static u32 ref(int op, u32 a, u32 b) {
    switch (op) {
    case 0: return b;
    case 1: return a + b;
    case 2: return a ^ b;
    case 3: return a & b;
    case 4: return a | b;
    case 5: return (s32)a < (s32)b ? a : b;
    case 6: return (s32)a > (s32)b ? a : b;
    case 7: return a < b ? a : b;
    default: return a > b ? a : b;
    }
}
static u32 do_amo(int op, volatile u32 *p, u32 v) {
    switch (op) {
    case 0: return amo_swap(p, v); case 1: return amo_add(p, v); case 2: return amo_xor(p, v);
    case 3: return amo_and(p, v);  case 4: return amo_or(p, v);  case 5: return amo_min(p, v);
    case 6: return amo_max(p, v);  case 7: return amo_minu(p, v); default: return amo_maxu(p, v);
    }
}
static const u32 EV[] = {0u, 1u, 5u, 0x7FFFFFFFu, 0x80000000u, 0xFFFFFFFFu, 0x12345678u, 0xA5A5A5A5u};
volatile u32 mem[4] __attribute__((aligned(16)));
int main(void) {
    u32 bad = 0;
    /* 1. 9 AMO x 8 x 8 gia tri: rd = gia tri cu, bo nho = tham chieu */
    for (int op = 0; op < 9; op++)
        for (unsigned i = 0; i < 8; i++)
            for (unsigned j = 0; j < 8; j++) {
                mem[0] = EV[i]; mem[1] = 0x77u;
                u32 old = do_amo(op, &mem[0], EV[j]);
                if (old != EV[i] || mem[0] != ref(op, EV[i], EV[j]) || mem[1] != 0x77u) bad++;
            }
    puts_(bad ? "amo ops BAD\n" : "amo ops ok\n");

    /* 2. LR / SC: thanh cong 1 lan, SC thu hai khong con dat cho; SC khong co LR that bai va khong ghi */
    bad = 0; mem[0] = 7;
    if (lr_w(&mem[0]) != 7) bad++;
    if (sc_w(&mem[0], 9) != 0 || mem[0] != 9) bad++;
    if (sc_w(&mem[0], 11) != 1 || mem[0] != 9) bad++;
    u32 k = 0;                                                   /* vong thu lai LR / SC kieu tang nguyen tu */
    do { u32 v = lr_w(&mem[1]); k++; if (sc_w(&mem[1], v + 1) == 0) break; } while (k < 4);
    if (mem[1] != 0x78u || k != 1) bad++;
    puts_(bad ? "lr/sc BAD\n" : "lr/sc ok\n");

    /* 3. ngat giua LR va SC: trap xoa dat cho, SC that bai, bo nho khong doi */
    bad = 0; mem[0] = 100; ticks = 0; timer_start();
    (void)lr_w(&mem[0]);
    csr_set(mstatus, MSTATUS_MIE);
    while (!ticks) ;
    csr_clear(mstatus, MSTATUS_MIE);
    if (sc_w(&mem[0], 555) != 1 || mem[0] != 100) bad++;
    timer_stop();
    puts_(bad ? "sc after irq BAD\n" : "sc after irq ok\n");

    /* 4. dem nguyen tu: chuong trinh chinh amoadd lien tuc, ISR cung amoadd; ngat khong xen vao giua AMO nen khong mat dem */
    cnt = 0; isr_amo = 0; ticks = 0; timer_start();
    csr_set(mstatus, MSTATUS_MIE);
    for (u32 n = 0; n < 4000; n++) amo_add(&cnt, 1);
    timer_stop();
    puts_((cnt == 4000u + isr_amo && isr_amo > 0) ? "atomic count ok\n" : "atomic count BAD\n");

    /* 5. khoa swap: chuong trinh chinh giu khoa, ISR thay khoa ban (that bai) roi chuong trinh chinh nha */
    lock = 0; isr_lock_fail = 0; ticks = 0;
    if (amo_swap(&lock, 1) != 0) bad++;
    timer_start(); csr_set(mstatus, MSTATUS_MIE);
    while (!isr_lock_fail) ;
    csr_clear(mstatus, MSTATUS_MIE);
    if (amo_swap(&lock, 0) != 1) bad++;
    timer_stop();
    puts_((bad || lock != 0) ? "lock BAD\n" : "lock ok\n");

    /* 6. lech dia chi: AMO / SC cause 6, LR cause 4, mtval = dia chi; bo nho khong doi */
    mem[2] = 0x600DF00Du; mem[3] = 0x600DF00Du;
    volatile u32 *mis = (volatile u32 *)((u32)&mem[2] + 2);
    nex = 0;
    (void)amo_add(mis, 1);
    (void)lr_w((volatile u32 *)((u32)&mem[2] + 1));
    (void)sc_w(mis, 1);
    bad = (nex != 3 || ex_cause[0] != 6 || ex_cause[1] != 4 || ex_cause[2] != 6 ||
           ex_tval[0] != (u32)mis || ex_tval[1] != (u32)&mem[2] + 1 || ex_tval[2] != (u32)mis ||
           mem[2] != 0x600DF00Du || mem[3] != 0x600DF00Du);
    puts_(bad ? "misaligned BAD\n" : "misaligned ok\n");
    return 0;
}
