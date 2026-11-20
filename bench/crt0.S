// STACK_TOP va TOHOST_ADDR co the doi khi bien dich (cosim/run_cosim.py dat chuong trinh o 0x8000_0000 cho Spike)
#ifndef STACK_TOP
#define STACK_TOP   0xF000
#endif
#ifndef TOHOST_ADDR
#define TOHOST_ADDR 0x00100000
#endif
    .section .text.init
    .globl _start
_start:
    li   sp, STACK_TOP
    call main
    li   t0, TOHOST_ADDR
    li   t1, 1
    sw   t1, 0(t0)
1:  j 1b
