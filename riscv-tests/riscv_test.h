// Moi truong toi thieu de chay bo test ISA chinh thuc (riscv-tests, thu muc isa/rv32ui va rv32um) tren loi tu viet.
// Khac moi truong "p" goc: khong khoi tao CSR/PMP/satp, ket qua ghi thang vao dia chi TOHOST.
// Quy uoc cua riscv-tests: ghi 1 = PASS, ghi (so_test << 1) | 1 = FAIL.
#ifndef _ENV_MINIMAL_H
#define _ENV_MINIMAL_H

#define TOHOST_ADDR 0x00100000

#define RVTEST_RV32U
#define RVTEST_RV32M
#define TESTNUM gp

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .globl _start;                                                  \
_start:                                                                 \
        li TESTNUM, 0;

#define RVTEST_CODE_END                                                 \
        unimp

#define RVTEST_PASS                                                     \
        fence;                                                          \
        li t0, TOHOST_ADDR;                                             \
        li t1, 1;                                                       \
        sw t1, 0(t0);                                                   \
9990:   j 9990b;

// Nhan so lon (9991, 9992) de khong trung nhan 1:/2:/3: ma test dung (vd. fence_i.S dung "2f", "3f" tro toi ma trong
// .data; nhan "2:" o day tung lam "2f" tro nham vao RVTEST_FAIL)
#define RVTEST_FAIL                                                     \
        fence;                                                          \
9991:   beqz TESTNUM, 9991b;                                            \
        sll TESTNUM, TESTNUM, 1;                                        \
        or TESTNUM, TESTNUM, 1;                                         \
        li t0, TOHOST_ADDR;                                             \
        sw TESTNUM, 0(t0);                                              \
9992:   j 9992b;

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN                                               \
        EXTRA_DATA                                                      \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END                                                 \
        .align 4; .global end_signature; end_signature:

#endif
