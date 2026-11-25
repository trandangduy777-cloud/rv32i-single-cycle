// Kiem PMP (rv32im_pipeline.v, PMP_N = 8) so tung lenh voi Spike (cosim/irq/spike_irq.cc, pmpregions = 8):
// - muc khong khoa khong rang buoc che do M; WARL cua pmpcfg (R = 0 thi W bi xoa, bit 5-6 doc 0)
// - muc khoa: NA4, NAPOT, TOR; muc so nho nhat khop duoc dung; khong khop muc nao thi che do M duoc phep
// - khoa chan ghi pmpcfg / pmpaddr, khoa muc TOR chan ghi pmpaddr cua muc truoc
// - load / store bi cam: mcause 5 / 7, mtval = dia chi; lenh load bi cam khong ghi rd, store bi cam khong ghi bo nho
// - fetch bi cam (X = 0): mcause 1, mtval = pc; lenh 32 bit o dia chi le 2 byte ma nua sau bi cam: mtval = pc + 2
// - -DMA (loi MISALIGNED = 1): truy cap lech khop mot phan muc / hai muc khac nhau la loi
// Handler ghi (mcause, mtval, mepc) vao plog. TOHOST = 1: dat; 0x10 | ma: loi tu kiem.
#include "irq_defs.h"

#define PR   0x01
#define PW   0x02
#define PX   0x04
#define TOR  0x08
#define NA4  0x10
#define NAPOT 0x18
#define PL   0x80

// truy cap vua roi khong gay trap
.macro OK code
    li      a0, \code
    bne     s8, s9, fail
.endm
// truy cap vua roi gay trap dung mcause, mtval = \addr
.macro FAULT cause, addr, code
    li      a0, \code
    addi    s9, s9, 12
    bne     s8, s9, fail
    lw      t0, -12(s8)
    li      t1, \cause
    bne     t0, t1, fail
    lw      t0, -8(s8)
    bne     t0, \addr, fail
.endm

    .section .text.init
    .globl _start
_start:
    .option norvc                       // lenh bi trap dai 4 byte (handler: mepc += 4)
    li      sp, 0x8003F000
    la      t0, handler
    csrw    mtvec, t0
    la      s8, plog
    mv      s9, s8
    la      s10, pdata

    // 1. muc khong khoa: khong cam gi o che do M; WARL cua pmpcfg
    srli    t0, s10, 2
    ori     t0, t0, 31                  // NAPOT 256 byte tai pdata
    csrw    pmpaddr0, t0
    csrr    a3, pmpaddr0
    li      a0, 0x11
    bne     a3, t0, fail
    li      t0, 0x7A                    // bit 5-6 + W khong co R + NAPOT -> doc lai 0x18
    csrw    pmpcfg0, t0
    csrr    a3, pmpcfg0
    li      t1, NAPOT
    li      a0, 0x12
    bne     a3, t1, fail
    lw      a3, 0(s10)
    sw      a3, 4(s10)
    OK      0x13
    la      t0, xcode
    srli    t0, t0, 2
    ori     t0, t0, 7
    csrw    pmpaddr6, t0
    li      t0, NAPOT << 16             // muc 6: NAPOT khong co X, khong khoa
    csrw    pmpcfg1, t0
    li      a2, 0
    call    xcode
    li      a0, 0x14
    li      t1, 1
    bne     a2, t1, fail
    OK      0x15
    csrw    pmpcfg0, zero
    csrw    pmpcfg1, zero

    // 2. cai dat cac muc khoa
    //   0: NAPOT pdata[0, 64)     R       1: NA4 pdata[64, 68)   ---     2: OFF, dia chi = pdata + 128
    //   3: TOR [pdata+128, +192)  RW      4: NAPOT [192, 256)    RW      5: NAPOT pdata[0, 256) ---
    //   6: NAPOT xcode (64 byte)  R       7: NA4 xc2 + 4 (lenh nen) / pdata + 132 ---
    srli    t0, s10, 2
    ori     t0, t0, 7
    csrw    pmpaddr0, t0
    mv      s1, t0
    addi    t0, s10, 64
    srli    t0, t0, 2
    csrw    pmpaddr1, t0
    addi    t0, s10, 128
    srli    t0, t0, 2
    csrw    pmpaddr2, t0
    mv      s2, t0
    addi    t0, s10, 192
    srli    t0, t0, 2
    csrw    pmpaddr3, t0
    ori     t0, t0, 7
    csrw    pmpaddr4, t0
    srli    t0, s10, 2
    ori     t0, t0, 31
    csrw    pmpaddr5, t0
    la      t0, xcode
    srli    t0, t0, 2
    ori     t0, t0, 7
    csrw    pmpaddr6, t0
#ifdef __riscv_compressed
    la      t0, xc2
    addi    t0, t0, 4
#else
    addi    t0, s10, 132
#endif
    srli    t0, t0, 2
    csrw    pmpaddr7, t0
    mv      s3, t0
    li      s4, ((PL | TOR | PR | PW) << 24) | (0 << 16) | ((PL | NA4) << 8) | (PL | NAPOT | PR)
    csrw    pmpcfg0, s4
    li      s5, ((PL | NA4) << 24) | ((PL | NAPOT | PR) << 16) | ((PL | NAPOT) << 8) | (PL | NAPOT | PR | PW)
    csrw    pmpcfg1, s5
    csrr    a3, pmpcfg0
    li      a0, 0x21
    bne     a3, s4, fail
    csrr    a3, pmpcfg1
    li      a0, 0x22
    bne     a3, s5, fail

    // 3. khoa: ghi pmpcfg chi doi muc 2 (khong khoa); pmpaddr0 (khoa), pmpaddr2 (muc 3 TOR khoa), pmpaddr7 bo qua
    li      t0, 0x00070000
    csrw    pmpcfg0, t0
    csrr    a3, pmpcfg0
    li      t1, 0x00070000
    or      t1, t1, s4
    li      a0, 0x23
    bne     a3, t1, fail
    csrw    pmpaddr0, zero
    addi    t0, s2, 1                   // chi doi nhe can duoi TOR: neu ghi lot qua thi khong lam hong vung ma
    csrw    pmpaddr2, t0
    csrw    pmpaddr7, zero
    csrw    pmpcfg1, zero
    csrr    a3, pmpaddr0
    li      a0, 0x24
    bne     a3, s1, fail
    csrr    a3, pmpaddr2
    li      a0, 0x25
    bne     a3, s2, fail
    csrr    a3, pmpaddr7
    li      a0, 0x26
    bne     a3, s3, fail
    csrr    a3, pmpcfg1
    li      a0, 0x27
    bne     a3, s5, fail

    // 4. load / store
    addi    a1, s10, 8                  // muc 0: R
    lw      a3, 0(a1)
    OK      0x31
    sw      zero, 0(a1)
    FAULT   7, a1, 0x32
    lw      a4, 0(a1)
    OK      0x33
    li      a0, 0x34
    bne     a4, a3, fail                // store bi cam khong ghi bo nho
    addi    a1, s10, 64                 // muc 1: khong quyen
    li      a5, 0x777
    lw      a5, 0(a1)
    FAULT   5, a1, 0x35
    li      t1, 0x777
    li      a0, 0x36
    bne     a5, t1, fail                // load bi cam khong ghi rd
    addi    a1, s10, 65
    sb      zero, 0(a1)
    FAULT   7, a1, 0x37
    addi    a1, s10, 66
    lhu     a5, 0(a1)
    FAULT   5, a1, 0x38
    addi    a1, s10, 100                // chi muc 5 khop: cam
    lw      a5, 0(a1)
    FAULT   5, a1, 0x39
    addi    a1, s10, 124                // ngay duoi can TOR
    sh      zero, 0(a1)
    FAULT   7, a1, 0x3a
    addi    a1, s10, 128                // muc 3 TOR: RW (dung truoc muc 5)
    sw      a3, 0(a1)
    lw      a4, 60(a1)
    lw      a4, 4(a1)                   // pdata + 132: muc 3 dung truoc muc 7
    OK      0x3b
    li      a0, 0x3c
    bne     a4, a3, fail
    addi    a1, s10, 200                // muc 4: RW (dung truoc muc 5)
    sw      a3, 0(a1)
    lbu     a4, 52(a1)
    lw      a4, 0(a1)
    OK      0x3d
    addi    a1, s10, 256                // ngoai moi muc: che do M duoc phep
    sw      a3, 0(a1)
    lw      a4, 0(a1)
    OK      0x3e

    // 5. fetch
    li      a2, 0
    call    xcode                       // muc 6: khong co X
    la      a1, xcode
    FAULT   1, a1, 0x41
    li      a0, 0x42
    bnez    a2, fail
    lw      t0, -4(s8)                  // mepc = xcode
    bne     t0, a1, fail
#ifdef __riscv_compressed
    call    xc2                         // c.nop chay duoc, lenh 32 bit tai xc2 + 2 co nua sau bi muc 7 cam
    la      a1, xc2
    addi    a1, a1, 4
    FAULT   1, a1, 0x43
    lw      t0, -4(s8)                  // mepc = xc2 + 2
    addi    t1, a1, -2
    li      a0, 0x44
    bne     t0, t1, fail
    bnez    a2, fail
#endif

#ifdef MA
    // 6. truy cap lech: hai tu thuoc hai muc khac nhau, hoac mot phan ra ngoai muc -> loi
    addi    a1, s10, 62                 // muc 0 | muc 1
    lw      a5, 0(a1)
    FAULT   5, a1, 0x51
    addi    a1, s10, 190                // muc 3 | muc 4
    lw      a5, 0(a1)
    FAULT   5, a1, 0x52
    addi    a1, s10, 254                // muc 4 | ngoai
    sw      zero, 0(a1)
    FAULT   7, a1, 0x53
    addi    a1, s10, 129                // ca hai tu trong muc 3: duoc
    lw      a5, 0(a1)
    sh      a5, 1(a1)
    OK      0x54
#endif

    li      a0, 1
fail:
    li      t0, TOHOST_ADDR
    sw      a0, 0(t0)
1:  j       1b

    .text
    .balign 4
handler:                                // ghi (mcause, mtval, mepc); fetch: ve ra, con lai: mepc += 4
    csrr    t6, mcause
    sw      t6, 0(s8)
    csrr    t6, mtval
    sw      t6, 4(s8)
    csrr    t6, mepc
    sw      t6, 8(s8)
    addi    s8, s8, 12
    csrr    t6, mcause
    addi    t6, t6, -1
    bnez    t6, 1f
    csrw    mepc, ra
    mret
1:  csrr    t6, mepc
    addi    t6, t6, 4
    csrw    mepc, t6
    mret

    .balign 64
xcode:                                  // vung 64 byte cua muc 6
    addi    a2, a2, 1
    ret
#ifdef __riscv_compressed
    .balign 64
xc2:
    .option push
    .option rvc
    c.nop
    .option pop
    addi    a2, a2, 1                   // 4 byte tai xc2 + 2: nua sau nam o xc2 + 4 (muc 7)
    ret
#endif
    .balign 64

    .data
    .balign 256
pdata:
    .fill   128, 4, 0x5a5aa5a5
plog:
    .space  256
