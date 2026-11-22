// Kiem tra load/store lech dia chi bang phan cung (Zicclsm / MISALIGNED = 1), tu viet. Chay qua cosim/run_cosim.py
// (so tung lenh voi Spike --isa=..._zicclsm), chi tren loi co lech bang phan cung.
// Vung dem 96 byte, can chinh 64 byte; voi moi vi tri byte off = 0..63 (vat qua ranh gioi tu, dong cache 8 / 16 byte):
//   1) lw, lh, lhu, lb, lbu tai off phai bang gia tri ghep tu cac lbu (gia tri tham chieu doc tung byte).
//   2) sw / sh / sb mot gia tri moi tai off, roi ngay lap tuc lw / lhu lai tai off (load ngay sau store, store co the
//      con trong bo dem ghi va vat qua 2 tu), va kiem tung byte bang lbu: dung cac byte vua ghi, byte lan can giu nguyen.
// Dem so lan sai vao s11; TOHOST = 1 neu khong sai lan nao, nguoc lai 3.
#ifndef TOHOST_ADDR
#define TOHOST_ADDR 0x80100000
#endif
    .option norvc
    .section .text.init
    .globl _start

// t6 = gia tri 32 bit ghep tu 4 byte (lbu) tai dia chi a0 (khong dung load lech)
#define REF_W(base)                \
    lbu  t6, 3(base);              \
    slli t6, t6, 8;                \
    lbu  t5, 2(base);              \
    or   t6, t6, t5;               \
    slli t6, t6, 8;                \
    lbu  t5, 1(base);              \
    or   t6, t6, t5;               \
    slli t6, t6, 8;                \
    lbu  t5, 0(base);              \
    or   t6, t6, t5

#define CHECK(a, b)                \
    beq  a, b, 1f;                 \
    addi s11, s11, 1;              \
1:

_start:
    li   s11, 0
    la   s0, buf
    // khoi tao 96 byte: byte i = 0x5A ^ (i * 37)
    li   t0, 0
init:
    li   t1, 37
    li   t2, 0
    mv   t3, t0
mul37:                              // t2 = i * 37 (khong dung M)
    beqz t3, 2f
    add  t2, t2, t1
    addi t3, t3, -1
    j    mul37
2:  xori t2, t2, 0x5A
    add  t3, s0, t0
    sb   t2, 0(t3)
    addi t0, t0, 1
    li   t1, 96
    bne  t0, t1, init

    li   s1, 0                      // off
    li   s2, 0x13579BDF             // gia tri ghi, doi moi vong
loop:
    add  a0, s0, s1
    // ---- 1) load lech so voi tham chieu ghep byte ----
    REF_W(a0)
    lw   t0, 0(a0)
    CHECK(t0, t6)
    slli t1, t6, 16                 // lh: 16 bit thap, mo rong dau
    srai t1, t1, 16
    lh   t0, 0(a0)
    CHECK(t0, t1)
    slli t1, t6, 16                 // lhu
    srli t1, t1, 16
    lhu  t0, 0(a0)
    CHECK(t0, t1)
    slli t1, t6, 24                 // lb
    srai t1, t1, 24
    lb   t0, 0(a0)
    CHECK(t0, t1)
    andi t1, t6, 0xFF               // lbu
    lbu  t0, 0(a0)
    CHECK(t0, t1)

    // ---- 2) store lech, doc lai ngay, kiem tung byte va byte lan can ----
    lbu  s3, -1(a0)                 // byte truoc va sau vung 4 byte (khong duoc doi)
    lbu  s4, 4(a0)
    andi t2, s1, 3                  // chon do rong theo off: 0 -> sb, 1 -> sh, 2,3 -> sw (moi off deu gap ca 3 qua cac vong)
    srli t3, s1, 2
    add  t2, t2, t3
    andi t2, t2, 3
    beqz t2, do_sb
    li   t3, 1
    beq  t2, t3, do_sh
do_sw:
    sw   s2, 0(a0)
    lw   t0, 0(a0)                  // load ngay sau store cung dia chi
    CHECK(t0, s2)
    REF_W(a0)
    CHECK(t6, s2)
    j    neigh
do_sh:
    sh   s2, 0(a0)
    lhu  t0, 0(a0)
    slli t1, s2, 16
    srli t1, t1, 16
    CHECK(t0, t1)
    lbu  t0, 0(a0)
    andi t3, s2, 0xFF
    CHECK(t0, t3)
    lbu  t0, 1(a0)
    srli t3, s2, 8
    andi t3, t3, 0xFF
    CHECK(t0, t3)
    j    neigh
do_sb:
    sb   s2, 0(a0)
    lbu  t0, 0(a0)
    andi t3, s2, 0xFF
    CHECK(t0, t3)
neigh:
    lbu  t0, -1(a0)
    CHECK(t0, s3)
    lbu  t0, 4(a0)
    CHECK(t0, s4)

    // gia tri moi cho vong sau: xoay trai 5 bit va cong hang so
    slli t0, s2, 5
    srli t1, s2, 27
    or   s2, t0, t1
    li   t0, 0x01234567
    add  s2, s2, t0
    addi s1, s1, 1
    li   t0, 64
    bne  s1, t0, loop

    li   t1, 1
    beqz s11, done
    li   t1, 3
done:
    li   t0, TOHOST_ADDR
    sw   t1, 0(t0)
1:  j    1b

    .data
    .balign 64
    .space 8                        // de -1(a0) khi off = 0 nam trong vung dem
buf:
    .space 104
