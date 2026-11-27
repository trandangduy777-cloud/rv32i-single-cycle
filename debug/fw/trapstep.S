# step qua ECALL: lenh sau ECALL khi step phai la lenh dau cua trinh xu ly (handler), mcause = 11, mepc = pc cua ECALL
    .section .text.init
    .globl _start
_start:
    la   t0, handler
    csrw mtvec, t0
    nop
    .globl ecall_here
ecall_here:
    ecall
    li   t1, 0x80100000
    li   t2, 1
    sw   t2, 0(t1)
1:  j    1b
    .globl handler
handler:
    csrr t3, mcause
    csrr t4, mepc
    addi t4, t4, 4
    csrw mepc, t4
    mret
