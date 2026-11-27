    .section .text.init
    .globl _start
_start:
    la   sp, _stack_top
    call main
    li   t0, 0x80100000        # TOHOST: ket thuc, ma ra = gia tri tra ve cua main (1 = dung)
    sw   a0, 0(t0)
1:  j    1b
