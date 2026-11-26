// Kiem tra mo rong A (LR.W, SC.W, 9 lenh AMO), tu viet. Chay qua cosim/run_cosim.py (so tung lenh voi Spike --isa=..._a...),
// chi tren loi co A. Gia tri dung cua tung lenh do Spike quyet dinh (rd, dia chi va du lieu store tung lenh phai trung).
// Phan 1: moi cap (a, b) trong bang 12 gia tri bien: moi lenh AMO tren o nho = a voi toan hang b, ket qua (rd va o nho sau) vao s2.
// Phan 2: cac tinh huong dat cho cua LR / SC: store cung tu / tu khac / sb / AMO cung dia chi / LR khac / SC lien tiep / SC khong
//         co LR / SC sang dia chi khac / ecall (trap) xen giua / lenh bat hop le xen giua / vong thu lai LR-SC / aq, rl.
// Phan 3: LR, SC, AMO lech dia chi (offset 1, 2, 3) phai trap: LR cause 4, SC va AMO cause 6, mtval = dia chi; bo xu ly tinh tong.
// Phan 4: hazard: dung rd cua AMO / LR / SC ngay lap tuc, load / store sat truoc / sau AMO cung tu, rd = x0.
// Phan 5: 800 thao tac ngau nhien (LCG) tren 16 tu: amoadd, amoxor, amomin, amomaxu, amoswap, LR + SC, sw, lw.
// TOHOST = 1 khi chay xong (Spike va RTL cung ket thuc).
#ifndef TOHOST_ADDR
#define TOHOST_ADDR 0x80100000
#endif
    .option norvc
    .section .text.init
    .globl _start

// ket qua t0 (rd) va o nho (s0) dua vao s2
#define MIX    xor  s2, s2, t0; lw t1, 0(s0); add s2, s2, t1; slli s2, s2, 1

_start:
    la   t0, handler
    csrw mtvec, t0
    la   s0, buf
    li   s2, 0
    li   s3, 0                      // tong mcause cua cac trap
    li   s4, 0                      // xor mtval

    // ---------------- Phan 1 ----------------
    la   s5, tab
    li   s6, 0                      // i
p1_i:
    slli t2, s6, 2
    add  t2, t2, s5
    lw   a1, 0(t2)                  // a
    li   s7, 0                      // j
p1_j:
    slli t2, s7, 2
    add  t2, t2, s5
    lw   a2, 0(t2)                  // b
    sw   a1, 0(s0); amoswap.w t0, a2, (s0); MIX
    sw   a1, 0(s0); amoadd.w  t0, a2, (s0); MIX
    sw   a1, 0(s0); amoxor.w  t0, a2, (s0); MIX
    sw   a1, 0(s0); amoand.w  t0, a2, (s0); MIX
    sw   a1, 0(s0); amoor.w   t0, a2, (s0); MIX
    sw   a1, 0(s0); amomin.w  t0, a2, (s0); MIX
    sw   a1, 0(s0); amomax.w  t0, a2, (s0); MIX
    sw   a1, 0(s0); amominu.w t0, a2, (s0); MIX
    sw   a1, 0(s0); amomaxu.w t0, a2, (s0); MIX
    addi s7, s7, 1
    li   t2, 12
    bne  s7, t2, p1_j
    addi s6, s6, 1
    li   t2, 12
    bne  s6, t2, p1_i

    // ---------------- Phan 2 ----------------
    li   a1, 0x11111111
    li   a2, 0x22222222
    addi s8, s0, 4                  // tu khac
    sw   a1, 0(s0)
    sw   a1, 0(s8)
    // 1) store cung tu
    lr.w t0, (s0);  sw a2, 0(s0);  sc.w t3, a1, (s0);  xor s2, s2, t3; MIX
    // 2) store tu khac
    lr.w t0, (s0);  sw a2, 0(s8);  sc.w t3, a1, (s0);  xor s2, s2, t3; MIX
    // 3) SC sang dia chi khac
    lr.w t0, (s0);  sc.w t3, a2, (s8); add s2, s2, t3;  MIX
    // 4) SC lien tiep (lan 2 that bai)
    lr.w t0, (s0);  sc.w t3, a1, (s0); sc.w t4, a2, (s0); slli t4, t4, 3; xor s2, s2, t3; xor s2, s2, t4; MIX
    // 5) hai LR, SC theo LR dau
    lr.w t0, (s0);  lr.w t1, (s8);  sc.w t3, a1, (s0); add s2, s2, t3; sc.w t4, a1, (s8); add s2, s2, t4; MIX
    // 6) SC khi chua tung LR sau SC truoc
    sc.w t3, a2, (s0); add s2, s2, t3; MIX
    // 7) sb vao tu
    lr.w t0, (s0);  sb a2, 1(s0);  sc.w t3, a1, (s0); add s2, s2, t3; MIX
    // 8) AMO cung dia chi
    lr.w t0, (s0);  amoadd.w t4, a2, (s0); sc.w t3, a1, (s0); add s2, s2, t3; add s2, s2, t4; MIX
    // 9) ecall xen giua (trap xoa dat cho)
    lr.w t0, (s0);  ecall; sc.w t3, a1, (s0); add s2, s2, t3; MIX
    // 10) lenh bat hop le xen giua
    lr.w t0, (s0);  .word 0xFFFFFFFF; sc.w t3, a1, (s0); add s2, s2, t3; MIX
    // 11) fence xen giua
    lr.w t0, (s0);  fence; sc.w t3, a1, (s0); add s2, s2, t3; MIX
    // 12) vong tang nguyen tu bang LR / SC (50 lan) + thu lai
    li   t5, 50
retry:
    lr.w  t0, (s0)
    addi  t0, t0, 3
    sc.w  t3, t0, (s0)
    bnez  t3, retry
    addi  t5, t5, -1
    bnez  t5, retry
    MIX
    // 13) aq / rl
    lr.w.aq t0, (s0);  sc.w.rl t3, a2, (s0); add s2, s2, t3; MIX
    lr.w.aqrl t0, (s0); sc.w.aqrl t3, a1, (s0); add s2, s2, t3; MIX
    amoadd.w.aq t0, a2, (s0); MIX
    amoxor.w.rl t0, a1, (s0); MIX
    amoswap.w.aqrl t0, a2, (s0); MIX
    // 14) SC thanh cong roi store va SC khac: dat cho da het
    lr.w t0, (s0);  sc.w t3, a1, (s0); sw a2, 0(s0); sc.w t4, a1, (s0); add s2, s2, t3; add s2, s2, t4; MIX

    // ---------------- Phan 3: lech dia chi ----------------
    li   a1, 0x77
    addi s9, s0, 1
    lr.w   t0, (s9)
    sc.w   t3, a1, (s9)
    amoadd.w t0, a1, (s9)
    addi s9, s0, 2
    lr.w   t0, (s9)
    sc.w   t3, a1, (s9)
    amoswap.w t0, a1, (s9)
    addi s9, s0, 3
    lr.w   t0, (s9)
    sc.w   t3, a1, (s9)
    amomaxu.w t0, a1, (s9)
    // LR hop le roi LR lech: reservation khong doi; roi SC dung
    lr.w t0, (s0); addi s9, s0, 5; lr.w t0, (s9); sc.w t3, a1, (s0); add s2, s2, t3; MIX

    // ---------------- Phan 4: hazard ----------------
    li   a1, 3
    sw   a1, 0(s0)
    amoadd.w t0, a1, (s0)
    add  t1, t0, t0                 // dung rd ngay
    add  s2, s2, t1
    amoadd.w t0, t0, (s0)           // rd cung la rs2
    amoxor.w t1, t0, (s0)
    add  s2, s2, t1
    lw   t2, 0(s0)                  // load ngay sau AMO cung tu
    add  s2, s2, t2
    sw   a1, 0(s0)                  // store ngay truoc AMO
    amoadd.w t0, a1, (s0)
    sw   t0, 4(s0)                  // store ngay sau AMO (du lieu = rd)
    lw   t2, 4(s0)
    add  s2, s2, t2
    amoswap.w x0, a1, (s0)          // rd = x0: van ghi
    lw   t2, 0(s0)
    add  s2, s2, t2
    lr.w t0, (s0)
    beq  t0, a1, 1f                 // dung rd cua LR ngay lap tuc trong nhanh
    addi s2, s2, 100
1:  sc.w t3, a1, (s0)
    bnez t3, 2f                     // dung rd cua SC ngay
    addi s2, s2, 7
2:  amomax.w t0, a1, (s0)
    sw   t0, 8(s0)
    amomin.w t1, a1, (s0)
    sw   t1, 12(s0)
    lw   t2, 8(s0)
    lw   t4, 12(s0)
    add  s2, s2, t2
    add  s2, s2, t4

    // ---------------- Phan 5: ngau nhien ----------------
    li   s5, 12345                  // LCG
    li   s6, 800
p5:
    li   t2, 1664525
    // x = x * 1664525 + 1013904223 khong dung M: nhan bang cong dich
    mv   t3, s5
    li   t4, 0
    mv   t6, t2
mulp:
    andi t1, t6, 1
    beqz t1, 3f
    add  t4, t4, t3
3:  slli t3, t3, 1
    srli t6, t6, 1
    bnez t6, mulp
    li   t1, 1013904223
    add  s5, t4, t1
    srli t1, s5, 8
    andi t1, t1, 15
    slli t1, t1, 2
    add  s8, s0, t1                 // dia chi tu
    srli t2, s5, 20
    andi t2, t2, 7
    li   t3, 0
    beq  t2, t3, op0
    li   t3, 1
    beq  t2, t3, op1
    li   t3, 2
    beq  t2, t3, op2
    li   t3, 3
    beq  t2, t3, op3
    li   t3, 4
    beq  t2, t3, op4
    li   t3, 5
    beq  t2, t3, op5
    li   t3, 6
    beq  t2, t3, op6
    amoswap.w t0, s5, (s8)
    j    pend
op0: amoadd.w  t0, s5, (s8)
    j    pend
op1: amoxor.w  t0, s5, (s8)
    j    pend
op2: amomin.w  t0, s5, (s8)
    j    pend
op3: amomaxu.w t0, s5, (s8)
    j    pend
op4: lr.w t0, (s8)
    add  t0, t0, s5
    sc.w t3, t0, (s8)
    add  t0, t0, t3
    j    pend
op5: sw   s5, 0(s8)
    mv   t0, s5
    j    pend
op6: lw   t0, 0(s8)
pend:
    xor  s2, s2, t0
    addi s6, s6, -1
    bnez s6, p5

    // ket thuc
    li   t1, TOHOST_ADDR
    li   t0, 1
    sw   t0, 0(t1)
1:  j    1b

// bo xu ly trap: cong mcause vao s3, xor mtval vao s4, tang mepc 4 (moi lenh gay trap deu 4 byte), mret
    .align 4
handler:
    csrr t5, mcause
    add  s3, s3, t5
    csrr t6, mtval
    xor  s4, s4, t6
    csrr t5, mepc
    addi t5, t5, 4
    csrw mepc, t5
    mret

    .section .data
    .align 6
buf: .space 64
tab: .word 0, 1, -1, 0x80000000, 0x7FFFFFFF, 0x80000001, 0x7FFFFFFE, 5, -5, 0xFFFF, 0x12345678, 0xDEADBEEF
