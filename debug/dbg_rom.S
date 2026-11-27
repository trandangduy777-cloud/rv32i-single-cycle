# ROM debug cua rv32_dm.v (hart M-mode). Dat tai 0xFFFF_F800. Dich bang debug/gen_rom.py thanh cac hang so trong rv32_dm.v.
# Giao thuc voi DM qua cac dia chi "hop thu" (hart ghi = bao hieu, hart doc cong FLAGS: 0 nghi, 1 chay chuong trinh tru
# tuong (lenh tru tuong + progbuf), 2 tiep tuc). s0 duoc cat vao dscratch0 khi vao D-mode va tra lai truoc khi chay.
    .equ HALTED,  -0x400            # 0xFFFFFC00: hart da dung trong ROM
    .equ GOING,   -0x3FC            # 0xFFFFFC04: hart bat dau chay chuong trinh tru tuong
    .equ RESUMING,-0x3F8            # 0xFFFFFC08: hart sap tiep tuc (DRET)
    .equ DONE,    -0x3F4            # 0xFFFFFC0C: chuong trinh tru tuong ket thuc (EBREAK trong D-mode)
    .equ EXC,     -0x3F0            # 0xFFFFFC10: chuong trinh tru tuong gap exception
    .equ FLAGS,   -0x3E0            # 0xFFFFFC20: doc
    .equ PROG,    -0x600            # 0xFFFFFA00: chuong trinh tru tuong + progbuf
    .section .text
    .globl _start
_start:
    j   entry                       # +0x00 vao D-mode tu che do thuong
    j   done                        # +0x04 EBREAK trong D-mode
    j   exc                         # +0x08 exception trong D-mode
entry:
    csrw dscratch0, s0
    sw   x0, HALTED(x0)
wait:
    lw   s0, FLAGS(x0)
    beqz s0, wait
    addi s0, s0, -1
    beqz s0, go
    j    resume
go:
    sw   x0, GOING(x0)
    csrr s0, dscratch0
    jalr x0, PROG(x0)
done:
    csrw dscratch0, s0
    sw   x0, DONE(x0)
    j    wait
exc:
    csrw dscratch0, s0
    sw   x0, EXC(x0)
    j    wait
resume:
    csrr s0, dscratch0
    sw   x0, RESUMING(x0)
    .word 0x7b200073                # dret
