// Kiem tra mepc voi lenh nen (IALIGN = 16), tu viet. Chay qua cosim/run_cosim.py (so tung lenh voi Spike), chi tren
// loi co mo rong C. Phat hien boi riscv-formal (csrw_mepc): mepc cua pipeline chi luu bit [31:2], nen trap tai pc co
// bit 1 = 1 (lenh nen o nua sau cua mot tu) luu sai mepc va MRET nhay ve dia chi sai.
//  1) c.ebreak o pc = 2 (mod 4)       : mepc phai co bit 1 = 1, handler tang them 2 roi MRET
//  2) ecall (32 bit) o pc = 2 (mod 4) : lenh 32 bit vat qua ranh gioi tu, handler tang them 4
//  3) c.ebreak o pc = 0 (mod 4)       : doi chung, bit 1 = 0
//  4) csrw mepc roi csrr lai nhieu gia tri co bit 1, bit 0 luon doc ra 0
// Tu kiem: s10 = so trap da vao handler (phai = 3), s11 = so lan sai (phai = 0). TOHOST = 1 neu dat, nguoc lai 3.
#ifndef TOHOST_ADDR
#define TOHOST_ADDR 0x80100000
#endif
    .option rvc
    .section .text.init
    .globl _start
_start:
    li   s10, 0
    li   s11, 0
    la   t0, handler
    csrw mtvec, t0
    li   s9, 0                 // so lenh lech bit 1 cua mepc
    .balign 4
    c.nop
t1_pc:
    c.ebreak                   // pc = 2 (mod 4)
    c.nop
    .balign 4
    c.nop
t2_pc:
    ecall                      // 32 bit, pc = 2 (mod 4)
    c.nop
    .balign 4
t3_pc:
    c.ebreak                   // pc = 0 (mod 4)
    c.nop
    // 4) vong ghi / doc lai mepc
    li   t2, 0x80000002
    li   t3, 0x80000100
w4: csrw mepc, t2
    csrr t4, mepc
    beq  t4, t2, 1f
    addi s11, s11, 1
1:  addi t2, t2, 2             // 0x...2, 0x...4, ... (bit 1 doi lien tuc, 127 gia tri)
    bne  t2, t3, w4
    li   t2, 0x80000007        // bit 0 phai doc ra 0
    csrw mepc, t2
    csrr t4, mepc
    li   t5, 0x80000006
    beq  t4, t5, 2f
    addi s11, s11, 1
2:  li   t0, 3
    beq  s10, t0, 3f
    addi s11, s11, 1
3:  bnez s11, fail
    li   t1, 1
    j    done
fail:
    li   t1, 3
done:
    li   t0, TOHOST_ADDR
    sw   t1, 0(t0)
4:  j    4b

    .balign 4
handler:
    addi s10, s10, 1
    csrr t0, mepc
    andi t1, t0, 2
    // trap 1 va 2 co bit 1 = 1; trap 3 (tu thu 3) thi bit 1 = 0
    li   t2, 3
    beq  s10, t2, 5f
    bnez t1, 6f
    addi s11, s11, 1           // dang le bit 1 = 1 nhung doc ra 0
    j    6f
5:  beqz t1, 6f
    addi s11, s11, 1           // dang le bit 1 = 0 nhung doc ra 1
6:  lhu  t2, 0(t0)             // lenh tai mepc: 16 hay 32 bit?
    andi t2, t2, 3
    addi t0, t0, 2
    li   t3, 3
    bne  t2, t3, 7f
    addi t0, t0, 2             // lenh 32 bit: +4
7:  csrw mepc, t0
    mret
