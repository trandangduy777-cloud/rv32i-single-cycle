# ngat ngoai (ghi 1 vao 0x80100008) khong duoc nhan khi single-step, nhung duoc nhan sau khi chay tiep
    .section .text.init
    .globl _start
_start:
    la   t0, handler
    csrw mtvec, t0
    li   t0, 0x800
    csrw mie, t0
    li   s2, 0
    li   s3, 0x80100008
    csrsi mstatus, 8
    .globl loop
loop:
    addi s4, s4, 1
    j    loop
    .globl handler
handler:
    addi s2, s2, 1
    sw   x0, 0(s3)
    mret
