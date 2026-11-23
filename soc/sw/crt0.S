/* crt0 cho SoC: sp, chep .data tu ROM sang RAM, xoa .bss, dat mtvec, goi main, ghi ma tra ve vao SYSCON.EXIT roi WFI mai.
   trap_entry luu thanh ghi goi (ra, t0-t6, a0-a7), goi trap_c() (C, mac dinh o trap_default.c: ket thuc voi ma 0xDEAD0000|mcause), mret. */
    .section .text.init, "ax"
    .globl _start
_start:
    la    sp, _estack
    la    a0, _sidata
    la    a1, _sdata
    la    a2, _edata
1:  bgeu  a1, a2, 2f
    lw    t0, 0(a0)
    sw    t0, 0(a1)
    addi  a0, a0, 4
    addi  a1, a1, 4
    j     1b
2:  la    a0, _sbss
    la    a1, _ebss
3:  bgeu  a0, a1, 4f
    sw    zero, 0(a0)
    addi  a0, a0, 4
    j     3b
4:  la    t0, trap_entry
    csrw  mtvec, t0
    call  main
    li    t0, 0x20002008          /* SYSCON.EXIT */
    sw    a0, 0(t0)
5:  wfi
    j     5b

    .balign 4
    .globl trap_entry
trap_entry:
    addi  sp, sp, -64
    sw    ra,  0(sp)
    sw    t0,  4(sp)
    sw    t1,  8(sp)
    sw    t2, 12(sp)
    sw    a0, 16(sp)
    sw    a1, 20(sp)
    sw    a2, 24(sp)
    sw    a3, 28(sp)
    sw    a4, 32(sp)
    sw    a5, 36(sp)
    sw    a6, 40(sp)
    sw    a7, 44(sp)
    sw    t3, 48(sp)
    sw    t4, 52(sp)
    sw    t5, 56(sp)
    sw    t6, 60(sp)
    call  trap_c
    lw    ra,  0(sp)
    lw    t0,  4(sp)
    lw    t1,  8(sp)
    lw    t2, 12(sp)
    lw    a0, 16(sp)
    lw    a1, 20(sp)
    lw    a2, 24(sp)
    lw    a3, 28(sp)
    lw    a4, 32(sp)
    lw    a5, 36(sp)
    lw    a6, 40(sp)
    lw    a7, 44(sp)
    lw    t3, 48(sp)
    lw    t4, 52(sp)
    lw    t5, 56(sp)
    lw    t6, 60(sp)
    addi  sp, sp, 64
    mret
