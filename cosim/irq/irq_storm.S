// Chuong trinh cosim co ngat (chay voi cosim/tb_cosim.v -DIRQ va cosim/irq/spike_irq.cc).
// Vong lap chinh chay 2 lan cung mot phep tinh checksum: lan 1 khong co ngat, lan 2 co ngat timer (15-142 chu ky),
// ngat phan mem va ngat ngoai (testbench phat ngau nhien + chuong trinh tu phat), xen vao moi loai lenh: nhan / chia,
// load / store moi do rong, nhanh, goi ham, ECALL (exception lan voi ngat), doan khoa ngat (mstatus.MIE = 0), che
// rieng ngat phan mem (mie), WFI. Checksum 2 lan phai bang nhau; so ngat moi loai phai dat nguong.
// -DMA: them load / store lech dia chi (chay tren loi MISALIGNED = 1).
// TOHOST = 1: dat; 3: trap la; 0x10 | ma: loi tu kiem.
#include "irq_defs.h"
#define NITER 300

    .section .text.init
    .globl _start
_start:
    li      sp, 0x8003F000
    li      s0, TMR
    la      s10, data
    li      s11, 0                  # lan chay: 0 = khong ngat, 1 = co ngat
    la      t0, handler             # ECALL o lan 1 cung can handler
    csrw    mtvec, t0
    la      t0, hsave
    csrw    mscratch, t0
pass:
    mv      t0, s10                 # xoa vung du lieu: 2 lan chay bat dau tu cung trang thai bo nho
    addi    t1, s10, 256
1:  sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 1b
    li      s1, 0
    li      s2, 0x1234567
    li      s3, NITER
    beqz    s11, loop
    call    irq_setup
loop:
    mul     t0, s1, s2
    add     s2, s2, t0
    mulh    t1, s2, s1
    xor     s2, s2, t1
    andi    t2, s1, 15
    slli    t2, t2, 2
    add     t2, t2, s10
    sw      s2, 0(t2)
    lh      t3, 2(t2)
    add     s2, s2, t3
    lbu     t4, 1(t2)
    sb      t4, 64(t2)
    lw      t5, 64(t2)
    xor     s2, s2, t5
#ifdef MA
    lw      t3, 65(t2)              # load / store lech dia chi (chi loi MISALIGNED = 1, tach 2 pha o MEM)
    add     s2, s2, t3
    sh      s2, 129(s10)
    lhu     t3, 127(s10)
    xor     s2, s2, t3
#endif
    addi    t6, s1, 3
    divu    t0, s2, t6
    remu    t1, s2, t6
    add     s2, s2, t0
    sub     s2, s2, t1
    call    rot5
    andi    t0, s1, 7
    bnez    t0, 2f
    ecall                           # handler: mepc += 4
    csrr    t0, mstatus             # MIE sau MRET phai bang MIE truoc trap (MPIE), so voi Spike
2:  beqz    s11, 3f                 # cac thao tac chi co o lan 2 (khong doi checksum)
    andi    t0, s1, 31
    li      t1, 5
    bne     t0, t1, 4f
    li      t2, 1                   # tu phat ngat phan mem va ngat ngoai
    sw      t2, 16(s0)
    li      t2, EXT
    sw      zero, 4(t2)
4:  andi    t0, s1, 63
    li      t1, 33
    bne     t0, t1, 5f
    wfi                             # cho toi khi co ngat (timer luon duoc dat lai)
5:  andi    t0, s1, 63              # WFI khi ngat phan mem dang cho nhung bi che: phai cho ngat timer / ngoai
    li      t1, 17
    bne     t0, t1, 9f
    csrci   mie, 8
    li      t2, 1
    sw      t2, 16(s0)
    addi    t3, s1, 1               # cho msip co tac dung truoc WFI
    mul     t3, t3, t3
    addi    t3, t3, 1
    addi    t3, t3, 1
    wfi
    csrsi   mie, 8                  # ngat phan mem duoc nhan ngay sau day
9:  andi    t0, s1, 15
    li      t1, 12
    bne     t0, t1, 8f
    csrci   mie, 8                  # che rieng ngat phan mem trong vai lenh
    li      t2, 1
    sw      t2, 16(s0)
    addi    t3, s1, 1
    mul     t3, t3, t3
    csrsi   mie, 8
8:
    andi    t0, s1, 15              # che MTIE khi ngat timer chac chan dang cho (mtimecmp = 0), roi bat lai
    li      t1, 3
    bne     t0, t1, 7f
    li      t2, 0x80
    csrc    mie, t2
    sw      zero, 8(s0)
    addi    t3, s1, 7
    mul     t3, t3, t3
    xor     t3, t3, s1
    addi    t3, t3, 1
    addi    t3, t3, 1
    addi    t3, t3, 1
    addi    t3, t3, 1
    addi    t3, t3, 1
    addi    t3, t3, 1
    csrs    mie, t2                 # ngat timer duoc nhan ngay sau day, handler dat lai mtimecmp
7:  andi    t0, s1, 15              # che MEIE khi tu phat ngat ngoai, roi bat lai
    li      t1, 6
    bne     t0, t1, 3f
    li      t2, 0x800
    csrc    mie, t2
    li      t3, EXT
    sw      zero, 4(t3)
    addi    t3, s1, 5
    mul     t3, t3, t3
    xor     t3, t3, s1
    addi    t3, t3, 1
    addi    t3, t3, 1
    addi    t3, t3, 1
    addi    t3, t3, 1
    addi    t3, t3, 1
    addi    t3, t3, 1
    csrs    mie, t2
3:  andi    t0, s1, 15              # doan khoa ngat (ca hai lan, chi doi trang thai mstatus.MIE)
    li      t1, 9
    bne     t0, t1, 6f
    csrci   mstatus, 8
    mul     t3, s2, s2
    add     s2, s2, t3
    sw      s2, 128(s10)
    lw      t3, 128(s10)
    xor     s2, s2, t3
    beqz    s11, 6f
    csrsi   mstatus, 8
6:  addi    s1, s1, 1
    blt     s1, s3, loop

    bnez    s11, check
    mv      s9, s2                  # checksum lan 1
    li      s11, 1
    j       pass
check:
    csrci   mstatus, 8
    li      a0, 0x11
    bne     s2, s9, fail
    la      t0, hsave
    li      a0, 0x12
    lw      t1, CNT_T(t0)
    li      t2, 20
    blt     t1, t2, fail
    li      a0, 0x13
    lw      t1, CNT_S(t0)
    li      t2, 5
    blt     t1, t2, fail
    li      a0, 0x14
    lw      t1, CNT_E(t0)
    li      t2, 5
    blt     t1, t2, fail
    li      a0, 0x15
    lw      t1, CNT_EC(t0)
    li      t2, 2 * ((NITER + 7) / 8)
    bne     t1, t2, fail
    li      a0, 1
fail:
    li      t0, TOHOST_ADDR
    sw      a0, 0(t0)
1:  j       1b

    .text
rot5:                               # s2 = quay trai 5 bit
    slli    t0, s2, 5
    srli    t1, s2, 27
    or      s2, t0, t1
    ret

#include "irq_handler.S"

    .data
    .balign 4
data:
    .space  256
