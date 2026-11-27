# Trigger action 0 (exception breakpoint) dat tu M-mode: lenh bi chan, mcause 3, mtval = dia chi (load / store) hoac pc (exec).
# tohost = 1 neu dung, 9 neu sai.
    .section .text.init
    .globl _start
_start:
    la   t0, handler
    csrw mtvec, t0
    li   s2, 0
    li   t3, 0x80100000
    csrw tselect, zero
    la   s4, var
    li   t0, 0x28001000         # ghi dmode = 1, action 1 tu M-mode: khong duoc phep, doc lai dmode phai = 0
    csrw tdata1, t0
    csrr t1, tdata1
    srli t1, t1, 27
    andi t1, t1, 1
    bnez t1, bad
    csrw tdata2, s4
    li   t0, 0x20000042         # type 2, m = 1, store = 1, action 0
    csrw tdata1, t0
    li   s6, 7
    .globl store_here
store_here:
    sw   s6, 0(s4)              # trigger -> exception, mtval = &var
    csrw tselect, zero
    li   t0, 0x20000041         # load
    csrw tdata1, t0
    .globl load_here
load_here:
    lw   t2, 0(s4)
    la   s5, exec_here
    csrw tdata2, s5
    li   t0, 0x20000044         # execute
    csrw tdata1, t0
    .globl exec_here
exec_here:
    nop
    csrw tdata1, zero
    li   t2, 3
    bne  s2, t2, bad
    lw   t1, 0(s4)
    li   t2, 7
    bne  t1, t2, bad
    li   t2, 1
    j    done
bad:
    li   t2, 9
done:
    sw   t2, 0(t3)
1:  j    1b
handler:
    csrr t0, mcause
    li   t1, 3
    bne  t0, t1, bad
    csrr t0, mtval
    addi s2, s2, 1
    li   t1, 1
    beq  s2, t1, e1
    li   t1, 2
    beq  s2, t1, e2
    la   t1, exec_here          # lan 3: mtval = pc cua lenh exec
    bne  t0, t1, bad
    j    off
e1: bne  t0, s4, bad            # store: mtval = &var
    j    off
e2: bne  t0, s4, bad            # load: mtval = &var
off:
    csrw tselect, zero
    csrw tdata1, zero           # tat trigger de chay lai lenh bi chan
    mret
    .data
var: .word 0
