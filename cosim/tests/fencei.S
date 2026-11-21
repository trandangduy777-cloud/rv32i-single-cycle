// Kiem tra Zifencei (FENCE.I) bang ma tu sua, tu viet. Chay qua cosim/run_cosim.py, so tung lenh voi Spike.
// 1) Sua lenh ngay sau FENCE.I: lenh "next" da duoc nap vao pipeline truoc khi store toi bo nho, FENCE.I phai
//    huy no va nap lai ban moi.
// 2) Sua mot ham nho roi goi: ham da nam trong cache lenh tu lan goi truoc, FENCE.I phai xoa cache.
// Moi vong dung immediate khac nhau. Ket qua tu kiem: a1 va a2 phai bang tong tinh truoc; TOHOST = 1 la PASS.
#ifndef TOHOST_ADDR
#define TOHOST_ADDR 0x80100000
#endif
#define N 24
    .option norvc
    .section .text.init
    .globl _start
_start:
    li   a1, 0                 // tong cua phan 1
    li   a2, 0                 // tong cua phan 2
    li   s0, 1                 // k = 1..N
    li   s1, N + 1
    la   s2, next
    la   s3, func
    li   s4, 0x00058593        // addi a1, a1, 0
    li   s5, 0x00a60613        // addi a2, a2, 10  (khuon: imm se duoc thay)
loop:
    // ---- phan 1: next = addi a1, a1, k ----
    slli t0, s0, 20
    or   t0, t0, s4
    sw   t0, 0(s2)
    fence.i
next:
    addi a1, a1, 0             // bi thay o moi vong
    // ---- phan 2: func: addi a2, a2, 2k ; ret ----
    slli t0, s0, 21
    li   t1, 0x000fffff
    and  t1, s5, t1            // bo imm cu
    or   t0, t0, t1
    sw   t0, 0(s3)
    fence.i
    jal  ra, func
    addi s0, s0, 1
    bne  s0, s1, loop

    // tu kiem: a1 = 1 + 2 + ... + N, a2 = 2 * (1 + ... + N)
    li   t0, N * (N + 1) / 2
    bne  a1, t0, fail
    slli t0, t0, 1
    bne  a2, t0, fail
    li   t1, 1
    j    done
fail:
    li   t1, 3
done:
    li   t0, TOHOST_ADDR
    sw   t1, 0(t0)
1:  j    1b

    .balign 64                 // ham nam o dong cache rieng
func:
    addi a2, a2, 0             // bi thay o moi vong
    ret
