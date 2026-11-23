// crt0 cho benchmark C (bench/*.c, CoreMark) chay duoi "bao" ngat: cai trinh xu ly (irq_handler.S), bat ngat timer
// (15-142 chu ky), phan mem va ngoai, goi main, khoa ngat, kiem co ngat timer da xay ra, ghi 1 vao TOHOST.
// Trinh xu ly chi dung a0-a5 va luu / khoi phuc chung, nen ma C khong biet minh bi ngat.
#include "irq_defs.h"
#ifndef STACK_TOP
#define STACK_TOP   0x8003F000
#endif
    .section .text.init
    .globl _start
_start:
    li      sp, STACK_TOP
    call    irq_setup
    call    main
    csrci   mstatus, 8
    la      t0, hsave
    lw      t1, CNT_T(t0)
    li      a0, 0x12
    beqz    t1, 1f                  # khong co ngat timer nao: cau hinh sai
    li      a0, 1
1:  li      t0, TOHOST_ADDR
    sw      a0, 0(t0)
2:  j       2b

    .text
#include "irq_handler.S"
