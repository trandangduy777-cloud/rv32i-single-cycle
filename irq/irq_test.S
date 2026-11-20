# Kiem tra ngat va WFI cua rv32im_pipeline (chay voi irq/tb_irq.v)
# Ban do bo nho: lenh 0x0000 (4 KB), du lieu 0x0000-0x0FFF, TOHOST 0x1000,
#                mtimer 0x0200_0000 (mtime lo/hi, mtimecmp lo/hi, msip o +0x10),
#                ngat ngoai: ghi 0x0300_0000 = ha irq_ext, ghi 0x0300_0004 = bat irq_ext
# - Vong lap chinh tinh checksum bang mul/remu/load/store/nhanh, trong khi ngat timer (moi 40-103 chu ky), ngat
#   phan mem (cu 4 ngat timer thi trinh xu ly timer bat msip mot lan) va 3 ngat ngoai tu testbench xen vao giua bat
#   ky lenh nao. Checksum phai bang gia tri tinh truoc (EXPECTED): lenh bi ngat phai chay lai dung mot lan.
# - Bo xu ly ngat chi dung a0-a3 va s4 (dem timer), s5 (dem ngoai), s8 (dem phan mem), s10 (mepc gan nhat),
#   s7/s9 (ghi thu tu ngat); kiem tra mcause, mstatus, mepc.
# - Sau vong lap:
#   1. ngat dang cho nhung bi che boi mstatus.MIE hoac mie: khong duoc nhan; mip phai bao dung MTIP, MSIP, MEIP.
#   2. bat mie cho ca ba ngat dang cho cung luc: thu tu nhan phai la ngoai, phan mem, timer.
#   3. WFI voi MIE = 0: dung cho toi khi MTIP bat roi chay tiep, khong vao trinh xu ly; ngat dang cho nhung bi
#      che boi mie (MSIP) khong duoc danh thuc WFI.
#   4. WFI voi MIE = 1: ngat duoc nhan tren lenh sau WFI, mepc = dia chi WFI + 4.
# Ket qua: TOHOST = 1 la PASS, (0x400 | ma loi) la FAIL. 0x300/0x304/0x308 = so ngat timer/ngoai/phan mem.

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
    li      s8, 0
    li      s9, 0                   # s9 > 0: trinh xu ly ghi ma ngat vao s7 (4 bit moi lan) va giam s9
    li      s7, 0
    lw      t1, 0(s0)               # mtimecmp = mtime + TICK (ghi phan cao truoc de khong co ngat gia)
    addi    t1, t1, TICK
    sw      zero, 12(s0)
    sw      t1, 8(s0)
    li      t0, 0x888               # MEIE | MTIE | MSIE
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
    li      t1, 2
    blt     s8, t1, fail_soft

    # 1. ngat bi che. MIE = 0, dat MTIP (mtimecmp = 0), MSIP va MEIP
    csrci   mstatus, 8
    sw      zero, 8(s0)             # MTIP
    li      t0, 1
    sw      t0, 16(s0)              # MSIP
    li      t1, 0x03000000
    sw      zero, 4(t1)             # testbench bat irq_ext
    mv      t2, s4
    mv      t3, s5
    mv      t4, s8
    li      t0, 50
spin1:
    addi    t0, t0, -1
    bnez    t0, spin1
    csrr    t1, mip
    li      t0, 0x888
    bne     t1, t0, fail_mip        # ca ba ngat dang cho
    # MIE = 1 nhung mie = 0: van khong nhan
    csrw    mie, zero
    csrsi   mstatus, 8
    li      t0, 50
spin2:
    addi    t0, t0, -1
    bnez    t0, spin2
    bne     s4, t2, fail_mask
    bne     s5, t3, fail_mask
    bne     s8, t4, fail_mask

    # 2. bat ca ba: thu tu nhan phai la ngoai (B), phan mem (3), timer (7)
    li      s7, 0
    li      s9, 3
    li      t0, 0x888
    csrw    mie, t0
    li      t0, 1000
spin3:
    beqz    s9, spin3_done
    addi    t0, t0, -1
    bnez    t0, spin3
    j       fail_prio
spin3_done:
    li      t0, 0xB37
    bne     s7, t0, fail_prio

    # 3. WFI voi MIE = 0: cho MTIP, khong vao trinh xu ly. MSIP dang cho nhung bi che boi mie nen khong danh thuc WFI
    csrci   mstatus, 8
    li      t0, 0x80
    csrw    mie, t0                 # chi MTIE
    li      t0, 1
    sw      t0, 16(s0)              # MSIP dang cho (bi che)
    lw      t1, 0(s0)
    addi    t1, t1, 300
    sw      t1, 8(s0)               # mtimecmp = mtime + 300
    mv      t2, s4
    wfi
    lw      t0, 0(s0)
    bltu    t0, t1, fail_wfi        # thuc day truoc khi mtime toi mtimecmp
    bne     s4, t2, fail_wfi        # MIE = 0 nen khong duoc vao trinh xu ly
    csrr    t0, mip
    andi    t0, t0, 0x80
    beqz    t0, fail_wfi

    sw      zero, 16(s0)            # xoa MSIP
    # 4. WFI voi MIE = 1: ngat nhan tren lenh sau WFI
    lw      t1, 0(s0)
    addi    t1, t1, 200
    sw      t1, 8(s0)               # xoa MTIP, ngat sau 200 chu ky
    li      s10, 0
    csrsi   mstatus, 8
wfi_pc:
    wfi
    addi    t3, t3, 0               # lenh bi ngat (mepc tro vao day)
    beq     s4, t2, fail_wfi        # phai co ngat timer
    la      t0, wfi_pc
    addi    t0, t0, 4
    bne     s10, t0, fail_wfi

    csrci   mstatus, 8              # khoa ngat truoc khi bao so dem cho testbench
    sw      s4, 0x300(zero)
    sw      s5, 0x304(zero)
    sw      s8, 0x308(zero)
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
fail_soft: li a0, 11; j fail
fail_wfi:  li a0, 12; j fail
fail:
    ori     a0, a0, 0x400
    sw      s4, 0x300(zero)
    sw      s5, 0x304(zero)
    sw      s8, 0x308(zero)
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
    mv      s10, a1
    andi    a2, a1, 3
    bnez    a2, fail_epc
    la      a2, handler
    bgeu    a1, a2, fail_epc
    csrr    a0, mcause
    beqz    s9, 5f                  # ghi thu tu ngat khi s9 > 0
    slli    s7, s7, 4
    andi    a1, a0, 0xF
    or      s7, s7, a1
    addi    s9, s9, -1
5:  li      a1, 0x80000007
    beq     a0, a1, h_timer
    li      a1, 0x8000000B
    beq     a0, a1, h_ext
    li      a1, 0x80000003
    beq     a0, a1, h_soft
    j       fail_cause
h_timer:
    andi    a2, s4, 3               # cu 4 ngat timer thi phat 1 ngat phan mem
    bnez    a2, 4f
    li      a2, 1
    sw      a2, 16(s0)
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
    li      a3, 0x03000000          # bao testbench ha irq_ext
    sw      zero, 0(a3)
    addi    s5, s5, 1
    mret
h_soft:
    sw      zero, 16(s0)            # xoa msip
    addi    s8, s8, 1
    mret
