# EBREAK: dcsr.ebreakm = 0 -> trap (mcause 3), tohost = 1; ebreakm = 1 -> halt, debugger bo qua EBREAK -> tohost = 3
    .section .text.init
    .globl _start
_start:
    la   t0, handler
    csrw mtvec, t0
    li   s2, 0
    li   t3, 0x80100000
    .globl ebreak_here
ebreak_here:
    ebreak
    li   t1, 1
    beq  s2, t1, ok
    li   t2, 3
    j    done
ok: li   t2, 1
done:
    sw   t2, 0(t3)
1:  j    1b
handler:
    csrr t0, mcause
    li   t1, 3
    bne  t0, t1, bad
    addi s2, s2, 1
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
bad:
    li   t2, 9
    sw   t2, 0(t3)
2:  j    2b
