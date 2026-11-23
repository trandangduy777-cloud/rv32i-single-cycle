// Trinh xu ly trap dung chung cho cac chuong trinh cosim co ngat (irq_storm.S, crt0_irq.S).
// - mscratch giu dia chi vung hsave (dinh nghia o duoi). Vao handler: hoan doi a0 <-> mscratch, luu a1-a5 vao hsave,
//   nen chuong trinh chinh (ke ca ma C) khong mat thanh ghi nao.
// - Ngat timer: mtimecmp = mtime + 15..142 (LFSR 32 bit) + do tre testbench bao o 0x0300_0008, thinh thoang bat them
//   msip (ngat phan mem).
// - Ngat phan mem: xoa msip. Ngat ngoai: ghi 0x0300_0000 de ha irq_ext.
// - Exception: chi chap nhan ECALL (mepc += 4); loai khac ghi 3 vao TOHOST (FAIL).
// - Dem so lan moi loai trong hsave: CNT_T, CNT_S, CNT_E, CNT_EC.
#include "irq_defs.h"
    .balign 4
handler:
    csrrw   a0, mscratch, a0
    sw      a1, H_A1(a0)
    sw      a2, H_A2(a0)
    sw      a3, H_A3(a0)
    sw      a4, H_A4(a0)
    sw      a5, H_A5(a0)
    csrr    a1, mcause
    bltz    a1, h_irq
    li      a2, 11
    bne     a1, a2, h_fail
    csrr    a2, mepc                # ECALL: tiep tuc sau lenh ecall (4 byte)
    addi    a2, a2, 4
    csrw    mepc, a2
    lw      a2, CNT_EC(a0)
    addi    a2, a2, 1
    sw      a2, CNT_EC(a0)
    j       h_ret
h_irq:
    andi    a1, a1, 0xf
    li      a2, 7
    beq     a1, a2, h_timer
    li      a2, 3
    beq     a1, a2, h_soft
    li      a2, 11
    beq     a1, a2, h_ext
    j       h_fail
h_timer:
    lw      a3, H_LFSR(a0)          # LFSR Galois 32 bit
    srli    a4, a3, 1
    andi    a5, a3, 1
    neg     a5, a5
    li      a2, 0x80200003
    and     a5, a5, a2
    xor     a3, a4, a5
    sw      a3, H_LFSR(a0)
    andi    a4, a3, 127
    addi    a4, a4, 15
    lw      a2, H_DLY(a0)           # cong them do tre do testbench bao (bo nho cham)
    add     a4, a4, a2
    li      a2, TMR
    lw      a5, 0(a2)
    add     a5, a5, a4
    sw      a5, 8(a2)               # mtimecmp moi (phan cao = 0): xoa MTIP
    andi    a4, a3, 0x300           # 1/4 so lan: bat them ngat phan mem
    bnez    a4, 1f
    li      a4, 1
    sw      a4, 16(a2)
1:  lw      a2, CNT_T(a0)
    addi    a2, a2, 1
    sw      a2, CNT_T(a0)
    j       h_ret
h_soft:
    li      a2, TMR
    sw      zero, 16(a2)
    lw      a2, CNT_S(a0)
    addi    a2, a2, 1
    sw      a2, CNT_S(a0)
    j       h_ret
h_ext:
    li      a2, EXT
    sw      zero, 0(a2)
    lw      a2, CNT_E(a0)
    addi    a2, a2, 1
    sw      a2, CNT_E(a0)
h_ret:
    lw      a1, H_A1(a0)
    lw      a2, H_A2(a0)
    lw      a3, H_A3(a0)
    lw      a4, H_A4(a0)
    lw      a5, H_A5(a0)
    csrrw   a0, mscratch, a0
    mret
h_fail:
    li      a2, TOHOST_ADDR
    li      a1, 3
    sw      a1, 0(a2)
2:  j       2b

// cai dat ngat: mtvec, mscratch, LFSR, mtimecmp = mtime + 60, bat MEIE | MTIE | MSIE va mstatus.MIE.
// Dung t0, t1.
irq_setup:
#ifdef VEC
    la      t0, vtable                # mtvec vectored: bang 12 muc, moi muc nhay toi handler
    ori     t0, t0, 1
#else
    la      t0, handler
#endif
    csrw    mtvec, t0
    la      t0, hsave
    csrw    mscratch, t0
    li      t1, 0x1d872b41
    sw      t1, H_LFSR(t0)
    li      t1, EXT
    lw      t1, 8(t1)               # do tre them cho ngat timer (testbench, 0x0300_0008)
    sw      t1, H_DLY(t0)
    li      t0, TMR
    lw      t1, 0(t0)
    addi    t1, t1, 60
    sw      t1, 8(t0)               # phan cao dang la 0xFFFFFFFF nen chua co ngat gia
    sw      zero, 12(t0)
    li      t0, 0x888
    csrw    mie, t0
    csrsi   mstatus, 8
    ret

#ifdef VEC
    .balign 64
vtable:                             // muc 0: exception, 3 / 7 / 11: ngat phan mem / timer / ngoai
    .option push
    .option norvc                   // moi muc dung 4 byte
    .rept 12
    j       handler
    .endr
    .option pop
#endif

    .data
    .balign 4
hsave:
    .space  64
    .text
