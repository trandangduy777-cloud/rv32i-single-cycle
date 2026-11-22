// Bai kiem tra xung dot cache (conflict miss), tu viet. Chay qua cosim/run_cosim.py (so tung lenh voi Spike) va
// cache/perf_cache.py (do chu ky).
// Hai mang A, B moi mang 32 tu (128 B) dat cach nhau dung 256 B = dung luong cache du lieu 16 dong x 4 tu, nen A[i] va
// B[i] luon roi vao cung chi so voi cache anh xa truc tiep (va cung tap voi 2 hoac 4 duong). Vong lap R lan (k = R..1):
// C[i] = A[i] + B[i] + k, acc += A[i] + B[i]. Anh xa truc tiep: A[i] va B[i] day nhau ra lien tuc, moi load deu truot.
// 2 duong: A va B cung nam trong cache (tong 256 B = dung luong), sau vong dau moi load deu trung. C chi bi ghi (cache
// khong cap phat khi ghi) nen khong chiem cho. Tu kiem: acc = R * tong(A + B), tong C = tong(A + B) + N (vong cuoi
// k = 1); TOHOST = 1 la PASS. Chi dung RV32I nen chay tren moi loi.
#ifndef TOHOST_ADDR
#define TOHOST_ADDR 0x80100000
#endif
#define N 32
#define R 8
    .option norvc
    .section .text.init
    .globl _start
_start:
    la   s0, arr_a
    li   t0, 256
    add  s1, s0, t0            // B = A + 256
    add  s2, s1, t0            // C = A + 512
    // khoi tao: A[i] = 3i + 1, B[i] = 5i + 7, C[i] = 0; tong(A + B) vao s4
    li   t1, 0
    li   s4, 0
init:
    slli t2, t1, 2
    add  t3, s0, t2
    slli t4, t1, 1
    add  t4, t4, t1
    addi t4, t4, 1
    sw   t4, 0(t3)
    add  s4, s4, t4
    add  t3, s1, t2
    slli t5, t1, 2
    add  t5, t5, t1
    addi t5, t5, 7
    sw   t5, 0(t3)
    add  s4, s4, t5
    add  t3, s2, t2
    sw   zero, 0(t3)
    addi t1, t1, 1
    li   t6, N
    bne  t1, t6, init
    // R vong: C[i] = A[i] + B[i] + k, acc (s5) += A[i] + B[i]
    li   s3, R
    li   s5, 0
outer:
    mv   a0, s0
    mv   a1, s1
    mv   a2, s2
    li   t1, N
inner:
    lw   t2, 0(a0)
    lw   t3, 0(a1)
    add  t2, t2, t3
    add  s5, s5, t2
    add  t4, t2, s3
    sw   t4, 0(a2)
    addi a0, a0, 4
    addi a1, a1, 4
    addi a2, a2, 4
    addi t1, t1, -1
    bnez t1, inner
    addi s3, s3, -1
    bnez s3, outer
    // tu kiem
    li   t1, 0
    li   t5, 0
sum:
    slli t2, t1, 2
    add  t3, s2, t2
    lw   t4, 0(t3)
    add  t5, t5, t4
    addi t1, t1, 1
    li   t6, N
    bne  t1, t6, sum
    addi t0, s4, N             // tong C phai bang tong(A + B) + N
    li   t1, 3
    bne  t5, t0, done
    li   t0, 0                 // acc phai bang R * tong(A + B)
    li   t2, R
mulr:
    add  t0, t0, s4
    addi t2, t2, -1
    bnez t2, mulr
    bne  s5, t0, done
    li   t1, 1
done:
    li   t0, TOHOST_ADDR
    sw   t1, 0(t0)
1:  j    1b

    .data
    .balign 256
arr_a:
    .space 768
