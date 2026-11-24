// mie / mip / mvendorid / mimpid phai ton tai (marchid cua Spike = 5, khac 0 cua lõi nay, nen khong so) (CSR bat buoc cua che do M, co the WARL = 0), doc khong duoc trap thanh illegal instruction.
// Loi that do bo sinh ngau nhien (cosim/gen_rand.py) tim ra: loi single-cycle khong co 0x304 / 0x344 nen csrr mie vao trap.
// Chi doc mie va ghi 0 vao no (Spike cung doc ra 0); khong doc mip vi Spike dat san MTIP (mtimecmp = 0 luc reset).
// Tu kiem: s11 = so lan vao handler (phai = 0). TOHOST = 1 neu dat, nguoc lai 3.
#ifndef TOHOST_ADDR
#define TOHOST_ADDR 0x80100000
#endif
    .section .text.init
    .globl _start
_start:
    li   s11, 0
    la   t0, handler
    csrw mtvec, t0
    csrr t1, mie
    csrrs t2, mie, x0
    csrw mie, x0
    csrrc t3, mie, x0
    csrrsi t4, mie, 0
    csrr t5, mvendorid
    or   t4, t4, t5
    csrr t5, mimpid
    or   t4, t4, t5
    or   t1, t1, t2
    or   t1, t1, t3
    or   t1, t1, t4
    bnez t1, bad
    bnez s11, bad
    li   t5, 1
    j    done
bad:
    li   t5, 3
done:
    li   t6, TOHOST_ADDR
    sw   t5, 0(t6)
1:  j    1b
    .balign 4
handler:
    addi s11, s11, 1
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
