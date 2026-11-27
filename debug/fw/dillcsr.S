# CSR debug (dcsr 0x7B0) va DRET ngoai D-mode phai la lenh bat hop le (mcause 2); tselect (0x7A0) truy cap duoc o M-mode.
# tohost = 1 neu dung 2 exception illegal-instruction va tselect doc duoc, 9 neu sai.
    .section .text.init
    .globl _start
_start:
    la   t0, handler
    csrw mtvec, t0
    li   s2, 0
    li   s3, 0
    li   t3, 0x80100000
    csrr t1, tselect            # hop le
    csrr t1, 0x7B0              # bat hop le (dcsr)
    .word 0x7B200073            # DRET ngoai D-mode: bat hop le
    csrr t1, 0x7B1              # bat hop le (dpc)
    li   t2, 3
    beq  s2, t2, ok
    li   t2, 9
    j    done
ok: li   t2, 1
done:
    sw   t2, 0(t3)
1:  j    1b
handler:
    csrr t0, mcause
    li   t1, 2
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
