    .section .text.init
    .globl _start
_start:
    li   sp, 0xF000
    call main
    li   t0, 0x00100000
    li   t1, 1
    sw   t1, 0(t0)
1:  j 1b
