// Kiem tra Zba, Zbb, Zbs, Zbc, Zicond, tu viet. Chay qua cosim/run_cosim.py (so tung lenh voi Spike
// --isa=..._zba_zbb_zbc_zbs_zicond), chi tren loi bat cac phan mo rong nay. Spike la chuan: moi gia tri ghi vao thanh ghi
// dich cua tung lenh phai trung.
// Phan 1: moi cap (a, b) trong bang 28 gia tri bien (0, 1, -1, INT_MIN, bit don, byte xen ke, ...): moi lenh cua 5 phan
//         mo rong tren (a, b), ket qua XOR vao s2 ngay sau lenh (lenh phu thuoc nhau -> forwarding EX/MEM, MEM/WB).
//         Dang immediate dung shamt 0, 1, 13, 16, 31.
// Phan 2: 600 cap ngau nhien (LCG), toan hang thu hai dich phai ngau nhien de co du so bit 0 dau / cuoi khac nhau.
// Phan 3: ket qua lenh Zb duoc dung ngay lap tuc lam dia chi load, du lieu store va dieu kien nhanh (hazard load-use,
//         forward vao nhanh, forward vao store).
// TOHOST = 1 khi chay xong (dung de Spike va RTL cung ket thuc); gia tri dung cua tung lenh do Spike quyet dinh.
#ifndef TOHOST_ADDR
#define TOHOST_ADDR 0x80100000
#endif
    .option norvc
    .section .text.init
    .globl _start

// moi lenh dang thanh ghi-thanh ghi cua 5 phan mo rong, \ra \rb la thanh ghi toan hang
.macro RR ra, rb
    .irp op, sh1add, sh2add, sh3add, andn, orn, xnor, min, minu, max, maxu, rol, ror, bclr, bext, binv, bset, clmul, clmulh, clmulr, czero.eqz, czero.nez
        \op t0, \ra, \rb
        xor s2, s2, t0
    .endr
.endm

// lenh mot ngoi (chi dung rs1) va dang immediate
.macro UN ra
    .irp op, clz, ctz, cpop, sext.b, sext.h, zext.h, orc.b, rev8
        \op t0, \ra
        add s2, s2, t0
    .endr
    .irp sh, 0, 1, 13, 16, 31
        rori  t0, \ra, \sh
        xor   s2, s2, t0
        bclri t1, \ra, \sh
        xor   s2, s2, t1
        bexti t2, \ra, \sh
        add   s2, s2, t2
        binvi t3, \ra, \sh
        xor   s2, s2, t3
        bseti t4, \ra, \sh
        add   s2, s2, t4
    .endr
.endm

_start:
    li   s2, 0
    la   s0, vals
    li   s3, 0                      // i
outer:
    slli t5, s3, 2
    add  t5, t5, s0
    lw   s4, 0(t5)                  // a
    li   s5, 0                      // j
inner:
    slli t6, s5, 2
    add  t6, t6, s0
    lw   s6, 0(t6)                  // b
    RR   s4, s6
    UN   s4
    addi s5, s5, 1
    li   t6, 28
    bne  s5, t6, inner
    addi s3, s3, 1
    li   t6, 28
    bne  s3, t6, outer

    // phan 2: cap ngau nhien
    li   s3, 0
    li   s4, 12345                  // trang thai LCG
    li   s7, 1664525
    li   s8, 1013904223
rnd:
    mul  s4, s4, s7
    add  s4, s4, s8
    mv   t5, s4
    mul  s4, s4, s7
    add  s4, s4, s8
    mv   t6, s4
    srli a0, t5, 16                 // a: hai nua cao / thap khac nhau
    xor  a0, a0, t5
    andi t4, t6, 31
    srl  a1, t6, t4                 // b: dich ngau nhien -> nhieu bit 0 dau
    srl  a2, t5, t4                 // a thu hai: nhieu bit 0 dau
    RR   a0, a1
    UN   a2
    RR   a2, t6
    addi s3, s3, 1
    li   t6, 600
    bne  s3, t6, rnd

    // phan 3: ket qua Zb dung ngay (load-use, nhanh, store)
    la   s9, scratch
    li   s3, 0
    li   s4, 7
use:
    mul  s4, s4, s7
    add  s4, s4, s8
    andi a0, s4, 0xF
    sh2add a1, a0, s9               // dia chi = scratch + 4 * (s4 & 15), ket qua Zba dung ngay lam dia chi
    sw   s4, 0(a1)
    lw   a2, 0(a1)
    max  a3, a2, a0                 // load -> lenh Zb (load-use)
    min  a4, a3, s4
    sw   a4, 4(a1)                  // store du lieu la ket qua Zb vua tinh
    clz  a5, a4
    bne  a5, zero, 1f               // nhanh phu thuoc ngay vao ket qua Zb
    addi s2, s2, 1
1:  czero.eqz a6, a4, a5            // dieu kien la ket qua Zb vua tinh
    czero.nez a7, a4, a5
    xor  s2, s2, a6
    add  s2, s2, a7
    ror  a6, s4, a0
    rev8 a7, a6
    orc.b a6, a7
    xor  s2, s2, a6
    addi s3, s3, 1
    li   t6, 200
    bne  s3, t6, use

    // ket thuc: tohost = 1
    la   t0, result
    sw   s2, 0(t0)
    li   t1, 1
    li   t2, TOHOST_ADDR
    sw   t1, 0(t2)
1:  j    1b

    .section .data
    .align 4
vals:
    .word 0x00000000, 0x00000001, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0x80000001, 0x00000002, 0x0000001F
    .word 0x00000020, 0x000000FF, 0x0000FFFF, 0xFFFF0000, 0x00FF00FF, 0xFF00FF00, 0x01010101, 0x0F0F0F0F
    .word 0xAAAAAAAA, 0x55555555, 0x12345678, 0xDEADBEEF, 0x00008000, 0xFFFF8000, 0x00000080, 0xFFFFFF80
    .word 0x00010000, 0x40000000, 0xC0000000, 0x00000100
    .align 4
scratch:
    .space 128
result:
    .word 0
