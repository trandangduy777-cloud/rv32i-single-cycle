// A + PMP: AMO can ca quyen doc va ghi (loi vao vung chi-doc la store/AMO access fault, cause 7), LR can quyen doc, SC can quyen ghi.
// 2 vung khoa (L = 1, ap dung ca che do M): buf (64 byte, chi doc) va buf2 (64 byte, doc + ghi). So tung lenh voi Spike.
// Lech dia chi van la cause 4 / 6 truoc cause 5 / 7. SC luon duoc thu sau LR cung dia chi (Spike chi kiem quyen ghi khi co dat cho).
#ifndef TOHOST_ADDR
#define TOHOST_ADDR 0x80100000
#endif
    .option norvc
    .section .text.init
    .globl _start
#define MIX    xor  s2, s2, t0; lw t1, 0(s1); add s2, s2, t1; slli s2, s2, 1
_start:
    la   t0, handler
    csrw mtvec, t0
    la   s0, buf                    // chi doc
    la   s1, buf2                   // doc + ghi
    li   s2, 0
    li   s3, 0                      // tong mcause
    li   s4, 0                      // xor mtval
    srli t0, s0, 2
    ori  t0, t0, 7                  // NAPOT 64 byte
    csrw pmpaddr0, t0
    srli t0, s1, 2
    ori  t0, t0, 7
    csrw pmpaddr1, t0
    li   t0, 0x9B99                 // entry 0: L|NAPOT|R ; entry 1: L|NAPOT|W|R
    csrw pmpcfg0, t0
    li   a1, 0x55
    li   a2, 0x1234

    // vung chi doc
    lw   t0, 0(s0)                  // ok
    xor  s2, s2, t0
    sw   a1, 0(s0)                  // cause 7
    amoadd.w t0, a1, (s0)           // cause 7 (thieu quyen ghi)
    amoswap.w t0, a1, (s0)          // cause 7
    amomaxu.w x0, a1, (s0)          // cause 7, rd = x0
    lr.w t0, (s0)                   // ok (chi can doc)
    xor  s2, s2, t0
    sc.w t3, a1, (s0)               // cause 7 (co dat cho, thieu quyen ghi)
    addi t4, s0, 1
    lr.w t0, (t4)                   // cause 4 (lech truoc access fault)
    sc.w t3, a1, (t4)               // cause 6
    addi t4, s0, 2
    amoadd.w t0, a1, (t4)           // cause 6
    sw   a1, 0(s1)                  // vung doc + ghi: ok

    // vung doc + ghi: moi lenh A chay binh thuong
    sw   a2, 0(s1)
    amoadd.w t0, a1, (s1);   MIX
    amoxor.w t0, a2, (s1);   MIX
    amomin.w t0, a1, (s1);   MIX
    amomaxu.w t0, a2, (s1);  MIX
    amoswap.w t0, a1, (s1);  MIX
    lr.w t0, (s1);           MIX
    sc.w t3, a2, (s1);       add s2, s2, t3; MIX
    sc.w t3, a2, (s1);       add s2, s2, t3; MIX
    lr.w t0, (s1)
    sc.w t3, a2, (s1);       add s2, s2, t3; MIX

    // ket qua
    add  s2, s2, s3
    xor  s2, s2, s4
    li   t1, TOHOST_ADDR
    li   t0, 1
    sw   t0, 0(t1)
1:  j    1b

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
buf:  .space 64
buf2: .space 64
