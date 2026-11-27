# Nhanh khong doan truoc duoc (xorshift32 quyet dinh +/xor) nen pipeline lien tuc co bong bay sau lan doan sai; debugger halt / resume
# ngau nhien: neu dpc sai o chu ky bong bay thi tong cuoi sai. EXPECT (acc cuoi) tinh tren may chu bang Python (-DEXPECT).
    .section .text.init
    .globl _start
_start:
    li   s2, 0x2545F491          # x
    li   s3, 0                   # acc
    li   s4, 30000               # so vong
loop:
    slli t0, s2, 13
    xor  s2, s2, t0
    srli t0, s2, 17
    xor  s2, s2, t0
    slli t0, s2, 5
    xor  s2, s2, t0
    andi t1, s2, 1
    beqz t1, even
    add  s3, s3, s2
    j    next
even:
    xor  s3, s3, s2
next:
    addi s4, s4, -1
    bnez s4, loop
    li   t0, EXPECT
    li   t3, 0x80100000
    li   t2, 1
    beq  s3, t0, done
    li   t2, 9
done:
    sw   t2, 0(t3)
1:  j    1b
