// Kiem bo dem Zicntr / Zihpm (rv32im_pipeline.v, ZICNTR = 1, HPM_N >= 4), chay voi cosim/irq/spike_irq.cc:
// minstret / instret so tung lenh voi Spike (dai luong kien truc); mcycle, mhpmcounter chi tu kiem (Spike khong mo hinh
// chu ky). Moi loi tu kiem ghi 0x10 | ma vao TOHOST; dat thi ghi 1.
#include "irq_defs.h"


    .section .text.init
    .globl _start
_start:
    li      sp, 0x8003F000
    la      t0, handler                 # ECALL (bo dem su kien exception)
    csrw    mtvec, t0
    la      t0, hsave
    csrw    mscratch, t0

    // 1. misa co I, M (va C neu bien dich voi lenh nen): Spike doc cung CSR nay
    csrr    t0, misa
    li      t1, 0x1100
    and     t2, t0, t1
    li      a0, 0x11
    bne     t2, t1, fail

    // 2. minstret dem dung so lenh: giua 2 lan doc co 5 lenh -> hieu = 6 (doc lay gia tri truoc lenh doc)
    csrr    s0, minstret
    addi    t0, zero, 1
    addi    t0, t0, 1
    mul     t0, t0, t0
    addi    t0, t0, 1
    nop
    csrr    s1, minstret
    sub     t1, s1, s0
    li      t2, 6
    li      a0, 0x12
    bne     t1, t2, fail
    // instret (0xC02) la ban chi doc: doc ngay sau minstret thi lon hon 1
    csrr    s0, minstret
    csrr    s1, instret
    sub     t1, s1, s0
    li      t2, 1
    li      a0, 0x13
    bne     t1, t2, fail

    // 3. ghi minstret thay cho tang: sau khi ghi 1000, lenh doc ngay sau thay 1000
    li      t0, 1000
    csrw    minstret, t0
    csrr    s0, minstret
    li      a0, 0x14
    bne     s0, t0, fail
    // nho tu nua thap sang nua cao: lo = FFFFFFFE, hi = 5, them 2 lenh -> hi = 6, lo = 0
    li      t0, -2
    csrw    minstret, t0
    li      t0, 5
    csrw    minstreth, t0
    nop
    csrr    s0, minstret
    csrr    s1, minstreth
    li      a0, 0x15
    bnez    s0, fail
    li      t2, 6
    bne     s1, t2, fail

    // 4. mcountinhibit: IR = 1 dung minstret, CY = 1 dung mcycle
    csrwi   mcountinhibit, 5
    csrr    s0, minstret
    csrr    s2, mcycle
    addi    t0, zero, 3
    mul     t0, t0, t0
    nop
    csrr    s1, minstret
    csrr    s3, mcycle
    csrwi   mcountinhibit, 0
    li      a0, 0x16
    bne     s0, s1, fail
    bne     s2, s3, fail

    // 5. mcycle tang va khong it hon so lenh trong vong lap (moi lenh it nhat 1 chu ky)
    csrr    s0, mcycle
    csrr    s2, minstret
    li      t0, 200
1:  addi    t0, t0, -1
    bnez    t0, 1b
    csrr    s1, mcycle
    csrr    s3, minstret
    sub     t1, s1, s0
    sub     t2, s3, s2
    li      a0, 0x17
    bltu    t1, t2, fail

    // 6. bo dem su kien: 3 = lenh hoan tat, 4 = nhanh, 5 = nhanh doan sai, 6 = exception
    li      t0, 13
    csrw    mhpmevent3, t0
    li      t0, 7
    csrw    mhpmevent4, t0
    li      t0, 8
    csrw    mhpmevent5, t0
    li      t0, 12
    csrw    mhpmevent6, t0
    csrw    mhpmcounter3, zero
    csrw    mhpmcounter4, zero
    csrw    mhpmcounter5, zero
    csrw    mhpmcounter6, zero
    csrr    s2, minstret
    li      t0, 100                     # 100 lenh nhanh (bnez), 99 lan nhay
2:  addi    t0, t0, -1
    bnez    t0, 2b
    ecall
    ecall
    ecall
    csrr    s3, minstret
    csrr    s4, mhpmcounter3
    csrr    s5, mhpmcounter4
    csrr    s6, mhpmcounter5
    csrr    s7, mhpmcounter6
    // lenh hoan tat: hpm3 bat dau dem tu truoc lan doc minstret dau (5 lenh) va doc o EX nen co the thieu toi 2 lenh
    // cu hon con trong pipeline: hpm3 - (hieu minstret) trong [0, 8]
    sub     t1, s3, s2
    sub     t2, s4, t1
    li      a0, 0x18
    bltz    t2, fail
    li      t3, 8
    bgt     t2, t3, fail
    li      t3, 106                     # nhanh: 100 cua vong lap + 2 moi lan vao handler ECALL (bltz, bne) x 3
    li      a0, 0x19
    bne     s5, t3, fail
    li      a0, 0x1a                    # nhanh doan sai: >= 1 (lan thoat vong), <= 100
    beqz    s6, fail
    bgt     s6, t3, fail
    li      t3, 3                       # exception: dung 3 (3 ECALL)
    li      a0, 0x1b
    bne     s7, t3, fail
    // bo dem ngoai HPM_N: doc 0
    csrr    t0, mhpmcounter31
    li      a0, 0x1c
    bnez    t0, fail

    li      a0, 1
fail:
    li      t0, TOHOST_ADDR
    sw      a0, 0(t0)
3:  j       3b

    .text
#include "irq_handler.S"
