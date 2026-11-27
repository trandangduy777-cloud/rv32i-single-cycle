# Vung debug 0xFFFF_F800-0xFFFF_FFFF chi truy cap duoc o D-mode: o M-mode lay lenh tu do -> illegal instruction (mcause 2),
# lw / sw vao do khong tac dong gi (doc ra 0). tohost = 1 neu dung, 9 neu sai.
    .section .text.init
    .globl _start
_start:
    la   t0, handler
    csrw mtvec, t0
    li   s2, 0
    li   t3, 0x80100000
    li   t0, 0xFFFFF800
    jalr ra, t0                 # lay lenh trong ROM debug
    li   t2, 1
    bne  s2, t2, bad
    li   t4, 0xAAAA5555
    sw   t4, -0x300(x0)         # 0xFFFFFD00: data0 / mailbox khong duoc ghi ngoai D-mode
    sw   t4, -0x500(x0)
    lw   t5, -0x500(x0)
    bnez t5, bad
    lw   t5, -0x300(x0)
    bnez t5, bad
    li   t2, 1
    j    done
bad:
    li   t2, 9
done:
    sw   t2, 0(t3)
1:  j    1b
handler:
    csrr t0, mcause
    li   t1, 2
    bne  t0, t1, bad
    csrr t0, mepc
    li   t1, 0xFFFFF800
    bne  t0, t1, bad
    addi s2, s2, 1
    csrw mepc, ra
    mret
