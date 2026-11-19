# Kiem tra ngat cua rv32im_pipeline (chay voi irq/tb_irq.v)
# Ban do bo nho: lenh 0x0000 (4 KB), du lieu 0x0000-0x0FFF, TOHOST 0x1000,
#                mtimer 0x0200_0000 (mtime lo/hi, mtimecmp lo/hi),
#                ngat ngoai: ghi 0x0300_0000 = ha irq_ext, ghi 0x0300_0004 = bat irq_ext
# - Vong lap chinh tinh checksum bang mul/remu/load/store/nhanh, trong khi ngat timer (moi 40-103 chu ky) va
#   3 ngat ngoai tu testbench xen vao giua bat ky lenh nao. Checksum phai bang gia tri tinh truoc (EXPECTED):
#   lenh bi ngat phai duoc chay lai dung mot lan, khong mat, khong lap tac dung.
# - Bo xu ly ngat chi dung a0-a3, s4 (dem ngat timer), s5 (dem ngat ngoai); kiem tra mcause, mstatus, mepc.
# - Sau vong lap: tat MIE (va sau do tat mie) khi van con ngat dang cho, ngat khong duoc nhan; mip phai bao
#   MTIP va MEIP. Cuoi cung bat mie cho ca hai ngat dang cho cung luc: ngat ngoai phai duoc nhan truoc.
# Ket qua: TOHOST = 1 la PASS, (0x400 | ma loi) la FAIL. 0x300 = so ngat timer, 0x304 = so ngat ngoai.

#ifndef EXPECTED
#error "can -DEXPECTED=<checksum>"
#endif
#define TICK   97
#define NITER  300

    .text
    .globl _start
_start:
    la      t0, handler
    csrw    mtvec, t0
    li      s0, 0x02000000          # mtimer
    li      s6, 0x1000              # TOHOST
    li      s4, 0
    li      s5, 0
    li      s7, -1                  # s7 = 0 thi trinh xu ly ghi ma ngat dau tien vao s7
    lw      t1, 0(s0)               # mtimecmp = mtime + TICK (ghi phan cao truoc de khong co ngat gia)
    addi    t1, t1, TICK
    sw      zero, 12(s0)
    sw      t1, 8(s0)
    li      t0, 0x880               # MEIE | MTIE
    csrw    mie, t0
    csrsi   mstatus, 8              # MIE = 1

    li      s1, 0                   # i
    li      s2, 0                   # checksum
    li      s3, NITER
main_start:
loop:
    mul     t2, s1, s1
    add     s2, s2, t2
    andi    t3, s1, 7
    slli    t3, t3, 2
    sw      s2, 0x200(t3)
    lw      t4, 0x200(t3)
    bne     t4, s2, fail_mem
    remu    t5, s2, s3
    xor     s2, s2, t5
    slli    t6, s2, 3
    srli    t5, s2, 29
    or      s2, t6, t5              # quay trai 3 bit
    addi    s1, s1, 1
    blt     s1, s3, loop
main_end:
    li      t0, EXPECTED
    bne     s2, t0, fail_sum

    # cho cho du 3 ngat ngoai (testbench phat o chu ky co dinh), co gioi han
    li      t0, 100000
wait_ext:
    li      t1, 3
    beq     s5, t1, ext_done
    addi    t0, t0, -1
    bnez    t0, wait_ext
    j       fail_ext
ext_done:
    li      t1, 10
    blt     s4, t1, fail_tmr        # vong lap chinh dai hon 10 * TICK chu ky nen phai co it nhat 10 ngat timer

    # ngat bi che: MIE = 0 trong khi MTIP dang bat
    csrci   mstatus, 8
    sw      zero, 8(s0)             # mtimecmp = 0 -> MTIP bat ngay
    mv      t2, s4
    li      t0, 50
spin1:
    addi    t0, t0, -1
    bnez    t0, spin1
    bne     s4, t2, fail_mask
    csrr    t1, mip
    andi    t1, t1, 0x80
    beqz    t1, fail_mip
    # MIE = 1 nhung mie.MTIE = 0: van khong nhan
    csrw    mie, zero
    csrsi   mstatus, 8
    li      t0, 50
spin2:
    addi    t0, t0, -1
    bnez    t0, spin2
    bne     s4, t2, fail_mask
    # ngat ngoai dang cho nhung mie.MEIE = 0: khong nhan, mip.MEIP = 1
    li      t1, 0x03000000
    sw      zero, 4(t1)             # testbench bat irq_ext
    mv      t3, s5
    li      t0, 50
spin3:
    addi    t0, t0, -1
    bnez    t0, spin3
    bne     s5, t3, fail_mask
    csrr    t1, mip
    li      t0, 0x880
    bne     t1, t0, fail_mip        # ca MEIP va MTIP dang cho
    # bat ca hai: ngat ngoai (uu tien cao hon) phai duoc nhan truoc
    li      s7, 0
    csrw    mie, t0
    li      t0, 1000
spin4:
    addi    t3, s5, -4
    beqz    t3, spin4_done
    addi    t0, t0, -1
    bnez    t0, spin4
    j       fail_ext
spin4_done:
    beq     s4, t2, fail_tmr        # ngat timer dang cho cung phai duoc nhan sau do
    li      t0, 11
    bne     s7, t0, fail_prio

    csrci   mstatus, 8              # khoa ngat truoc khi bao so dem cho testbench
    sw      s4, 0x300(zero)
    sw      s5, 0x304(zero)
    li      t0, 1
    sw      t0, 0(s6)
1:  j       1b

fail_mem:  li a0, 1; j fail
fail_sum:  li a0, 2; j fail
fail_ext:  li a0, 3; j fail
fail_tmr:  li a0, 4; j fail
fail_mask: li a0, 5; j fail
fail_mip:  li a0, 6; j fail
fail_cause:li a0, 7; j fail
fail_stat: li a0, 8; j fail
fail_epc:  li a0, 9; j fail
fail_prio: li a0, 10; j fail
fail:
    ori     a0, a0, 0x400
    sw      s4, 0x300(zero)
    sw      s5, 0x304(zero)
    sw      a0, 0(s6)
2:  j       2b

    .balign 4
handler:
    # trong trinh xu ly: MIE = 0, MPIE = 1
    csrr    a1, mstatus
    andi    a1, a1, 0x88
    li      a2, 0x80
    bne     a1, a2, fail_stat
    # mepc phai la mot lenh cua chuong trinh (chia het cho 4, truoc handler)
    csrr    a1, mepc
    andi    a2, a1, 3
    bnez    a2, fail_epc
    la      a2, handler
    bgeu    a1, a2, fail_epc
    csrr    a0, mcause
    li      a1, 0x80000007
    beq     a0, a1, h_timer
    li      a1, 0x8000000B
    beq     a0, a1, h_ext
    j       fail_cause
h_timer:
    bnez    s7, 4f
    andi    s7, a0, 0xF
4:
    # mtimecmp = mtime + 40 + (7 * s4 mod 64): khoang cach thay doi de ngat roi vao moi vi tri trong vong lap
    slli    a2, s4, 3
    sub     a2, a2, s4
    andi    a2, a2, 63
    lw      a3, 0(s0)
    add     a3, a3, a2
    addi    a3, a3, 40
    sw      a3, 8(s0)               # xoa MTIP
    addi    s4, s4, 1
    mret
h_ext:
    bnez    s7, 3f                  # ghi lai ma ngat dau tien sau khi s7 = 0
    andi    s7, a0, 0xF
3:  li      a3, 0x03000000          # bao testbench ha irq_ext
    sw      zero, 0(a3)
    addi    s5, s5, 1
    mret
