// Kiem MMU Sv32 (rv32im_pipeline.v, SU = 1, MMU = 1) so tung lenh voi Spike (che do MSU, Sv32):
// - trang 4 KiB qua bang muc 0 va trang lon 4 MiB (anh xa dong nhat vung ma / du lieu cho S, U = 0)
// - quyen: R / W / X, U (U chi chay / doc trang U; S doc trang U can SUM, khong bao gio chay trang U), MXR, A = 0,
//   store voi D = 0; PTE loi cau truc (V = 0, W khong R, trang lon lech, PTE khong la o muc 0, PTE tro bang co U);
//   dia chi vat ly >= 2^32 -> loi truy cap; PMP cam doc bang trang -> loi truy cap khi duyet
// - uy quyen loi trang (medeleg 12 / 13 / 15) ve S; MPRV + MPP = U cho load cua M
// - sua PTE roi SFENCE.VMA; lenh 32 bit vat qua ranh gioi trang (2 trang vat ly khong lien nhau, chi khi co C),
//   loi trang o nua sau (mtval = pc + 2); TVM (satp, SFENCE.VMA o S), SFENCE.VMA o U
// - -DMA (loi MISALIGNED = 1, Spike zicclsm): load / store lech vat qua ranh gioi trang (2 trang vat ly khong lien nhau),
//   loi o trang sau (mtval = dau trang sau) / trang dau (mtval = dia chi), PMP cam / cho phep tung trang (co dich va
//   khong dich: hai muc PMP khac nhau tiep giap o ranh gioi 4 KiB). Store loi o trang sau: Spike da ghi phan trang dau,
//   lo khong ghi gi (spec cho phep ca hai); chuong trinh khong doc lai cac byte do.
// Ma U chay o dia chi ao nen dung dia chi tuyet doi (lui / addi) thay cho la (theo pc).
// Trinh xu ly M / S ghi (che do, cause, tval, epc) vao plog; ECALL voi a7 = 0x99: ve M tai a0. TOHOST = 1: dat.
#include "irq_defs.h"

#define SVC     0x99
#define MPP_M   0x1800
#define MPP_S   0x0800
#define PTE_V   0x01
#define PTE_R   0x02
#define PTE_W   0x04
#define PTE_X   0x08
#define PTE_U   0x10
#define PTE_A   0x40
#define PTE_D   0x80
// dia chi ao cua vung U (bang muc 0 l0pt, muc 1 so 0x100)
#define VA_UC   0x40000000              // ma U (trang A)
#define VA_UC2  0x40001000              // ma U (trang B, vat ly khong lien voi A)
#define VA_D0   0x40002000              // dpage0: U R W A D
#define VA_RO   0x40003000              // dpage1: U R A D (khong W: store loi do W, khong do D)
#define VA_ND   0x40004000              // dpage0: U R W A (D = 0)
#define VA_NA   0x40005000              // dpage1: U R W (A = 0)
#define VA_S    0x40006000              // dpage0: R W A D (khong U)
#define VA_X    0x40007000              // xpage: U X A (khong R)
#define VA_INV  0x40008000              // V = 0
#define VA_WNR  0x40009000              // W khong R
#define VA_HI   0x4000A000              // dia chi vat ly >= 2^32
#define VA_L0T  0x4000B000              // PTE khong la o muc 0
#define VA_SPM  0x40400000              // trang lon lech (PPN[9:0] != 0)
#define VA_UT   0x40800000              // PTE muc 1 tro bang nhung co U
#define VA_PB   0x40C00000              // qua bang muc 0 thu hai (l0pb), dung cho PMP cam bang trang
#define VA_MA0  0x4000C000              // -DMA: dpage1 U R W A D
#define VA_MA1  0x4000D000              //       dpage0 U R W A D (trang vat ly dung TRUOC trang cua VA_MA0)
#define VA_MA2  0x4000E000              //       V = 0
#define VA_MA3  0x4000F000              //       xpage U R W A D (store loi o trang sau: Spike ghi mot phan o day)
#define VA_MA4  0x40010000              //       dpage0 U R A D (khong W)

.macro NOTRAP code
    li      a0, \code
    bne     s8, s9, fail
.endm
.macro TRAP mode, cause, code
    li      a0, \code
    addi    s9, s9, 16
    bltu    s8, s9, fail
    lw      t0, -16(s9)
    li      t1, \mode
    bne     t0, t1, fail
    lw      t0, -12(s9)
    li      t1, \cause
    bne     t0, t1, fail
.endm
.macro TVAL val, code                   // tval cua ban ghi vua kiem
    li      a0, \code
    lw      t0, -8(s9)
    li      t1, \val
    bne     t0, t1, fail
.endm
.macro GO mpp, lbl                      // tu M: MPP = mpp, mepc = lbl (dia chi ao), mret
    li      t0, MPP_M
    csrc    mstatus, t0
    li      t0, \mpp
    csrs    mstatus, t0
    li      t0, \lbl
    csrw    mepc, t0
    mret
.endm
.macro GOL mpp, lbl                     // nhu GO, nhan trong anh xa dong nhat
    li      t0, MPP_M
    csrc    mstatus, t0
    li      t0, \mpp
    csrs    mstatus, t0
    la      t0, \lbl
    csrw    mepc, t0
    mret
.endm
// dat PTE: bang tbl, chi so idx = (dia chi vat ly pa >> 2 << 10) | co
.macro SETPTE tbl, idx, pa, flags
    la      t0, \pa
    srli    t0, t0, 12
    slli    t0, t0, 10
    ori     t0, t0, \flags
    la      t1, \tbl
    sw      t0, 4 * \idx(t1)
.endm

    .section .text.init
    .globl _start
_start:
    .option norvc
    li      sp, 0x8003F000
    la      t0, mtrap
    csrw    mtvec, t0
    la      t0, s_trap
    csrw    stvec, t0
    la      s8, plog
    mv      s9, s8
    li      a7, 0
    li      t0, -1                      // PMP muc 7: toan bo RWX
    csrw    pmpaddr7, t0
    li      t0, 0x1F << 24
    csrw    pmpcfg1, t0

    // ---- bang trang ----
    la      t1, l1pt                    // muc 1 so 0x200: trang lon dong nhat 0x8000_0000 (RWX A D, khong U)
    li      t0, (0x80000 << 10) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    li      t2, 4 * 0x200
    add     t2, t2, t1
    sw      t0, 0(t2)
    la      t0, l0pt                    // muc 1 so 0x100 -> l0pt
    srli    t0, t0, 12
    slli    t0, t0, 10
    ori     t0, t0, PTE_V
    sw      t0, 4 * 0x100(t1)
    ori     t2, t0, PTE_U               // muc 1 so 0x102: tro bang nhung co U -> loi trang
    sw      t2, 4 * 0x102(t1)
    la      t0, l0pb                    // muc 1 so 0x103 -> l0pb
    srli    t0, t0, 12
    slli    t0, t0, 10
    ori     t0, t0, PTE_V
    sw      t0, 4 * 0x103(t1)
    li      t0, (0x80001 << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D   // muc 1 so 0x101: trang lon lech
    sw      t0, 4 * 0x101(t1)
    SETPTE  l0pt, 0, ucodeA, PTE_V | PTE_R | PTE_X | PTE_U | PTE_A
    SETPTE  l0pt, 1, ucodeB, PTE_V | PTE_R | PTE_X | PTE_U | PTE_A
    SETPTE  l0pt, 2, dpage0, PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    SETPTE  l0pt, 3, dpage1, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D
    SETPTE  l0pt, 4, dpage0, PTE_V | PTE_R | PTE_W | PTE_U | PTE_A
    SETPTE  l0pt, 5, dpage1, PTE_V | PTE_R | PTE_W | PTE_U
    SETPTE  l0pt, 6, dpage0, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    SETPTE  l0pt, 7, xpage,  PTE_V | PTE_X | PTE_U | PTE_A
    SETPTE  l0pt, 8, dpage0, PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    SETPTE  l0pt, 9, dpage0, PTE_V | PTE_W | PTE_U | PTE_A | PTE_D
    la      t1, l0pt                    // so 10: PPN bit 20 = 1 (dia chi vat ly bit 32)
    li      t0, (0x100000 << 10) | PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    sw      t0, 4 * 10(t1)
    SETPTE  l0pt, 11, dpage0, PTE_V     // so 11: PTE khong la o muc 0
    SETPTE  l0pb, 0, dpage1, PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
#ifdef MA
    SETPTE  l0pt, 12, dpage1, PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    SETPTE  l0pt, 13, dpage0, PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    SETPTE  l0pt, 15, xpage,  PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    SETPTE  l0pt, 16, dpage0, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D
#endif
    la      t0, l1pt
    srli    t0, t0, 12
    li      t1, 0x80000000 | (5 << 22) // Sv32, ASID 5
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma

    // 1. U: quyen va PTE loi (khong uy quyen: ve M)
    GO      0, VA_UC
m1:
    TRAP    3, 15, 0x11                 // sw RO
    TVAL    VA_RO, 0x12
    TRAP    3, 15, 0x13                 // sw D = 0
    TRAP    3, 13, 0x14                 // A = 0
    TRAP    3, 13, 0x15                 // trang khong U
    TRAP    3, 13, 0x16                 // chi X, MXR = 0
    TRAP    3, 13, 0x17                 // V = 0
    TRAP    3, 13, 0x18                 // W khong R (load)
    TRAP    3, 15, 0x28                 // W khong R (store: W = 1, D = 1 van loi)
    TRAP    3, 5, 0x19                  // dia chi vat ly >= 2^32: loi truy cap
    TVAL    VA_HI, 0x1a
    TRAP    3, 13, 0x1b                 // PTE khong la o muc 0
    TRAP    3, 13, 0x1c                 // trang lon lech
    TRAP    3, 13, 0x1d                 // PTE muc 1 tro bang co U
    TRAP    3, 12, 0x1e                 // chay trang du lieu (khong X)
    TVAL    VA_D0, 0x1f
    NOTRAP  0x20
    li      a0, 0x21                    // U doc / ghi dpage0 qua VA_D0: kiem gia tri qua dia chi vat ly
    la      t0, dpage0
    lw      t1, 4(t0)
    li      t2, 0x13579bdf
    bne     t1, t2, fail

    // 2. S: SUM, khong chay trang U, MXR
    GOL     MPP_S, s2
s2:
    li      s0, VA_D0
    lw      t0, 0(s0)                   // SUM = 0 -> 13
    li      t0, 1 << 18
    csrs    sstatus, t0
    lw      t0, 0(s0)                   // SUM = 1: duoc
    li      s0, VA_X
    lw      t0, 0(s0)                   // chi X -> 13
    li      t0, 1 << 19
    csrs    sstatus, t0
    lw      t0, 0(s0)                   // MXR: duoc
    li      t0, (1 << 18) | (1 << 19)
    csrc    sstatus, t0
    li      t0, VA_UC + 0x100
    jalr    t0                          // S chay trang U -> 12 (handler ve ra)
    li      a7, SVC
    la      a0, m2
    ecall
m2:
    TRAP    3, 13, 0x22
    TRAP    3, 13, 0x23
    TRAP    3, 12, 0x24
    TVAL    VA_UC + 0x100, 0x25
    NOTRAP  0x26

    // 3. uy quyen loi trang ve S
    li      t0, (1 << 12) | (1 << 13) | (1 << 15)
    csrw    medeleg, t0
    GO      0, VA_UC + 0x200
m3:
    TRAP    1, 13, 0x31
    TVAL    VA_NA, 0x32
    TRAP    1, 15, 0x33
    TRAP    1, 12, 0x34
    NOTRAP  0x35
    csrw    medeleg, zero

    // 4. sua PTE (VA_RO thanh ghi duoc) + SFENCE.VMA
    SETPTE  l0pt, 3, dpage1, PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    sfence.vma
    GO      0, VA_UC + 0x300
m4:
    NOTRAP  0x41
    SETPTE  l0pt, 3, dpage1, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D
    sfence.vma

    // 5. MPRV + MPP = U: load cua M dich voi quyen U
    li      t0, (1 << 17)
    csrs    mstatus, t0
    li      t0, MPP_M
    csrc    mstatus, t0
    li      s0, VA_D0
    lw      t2, 0(s0)                   // duoc (trang U)
    la      s0, plog
    lw      t0, 0(s0)                   // vung dong nhat khong U -> 13
    li      t0, (1 << 17)
    csrc    mstatus, t0
    TRAP    3, 13, 0x51
    NOTRAP  0x52

    // 6. PMP cam doc bang muc 0 thu hai (quyen S khi duyet) -> loi truy cap
    la      t0, l0pb
    srli    t0, t0, 2
    ori     t0, t0, 0x1FF               // NAPOT 4 KiB
    csrw    pmpaddr0, t0
    li      t0, 0x18                    // muc 0: NAPOT, khong quyen, khong khoa
    csrw    pmpcfg0, t0
    sfence.vma
    GO      0, VA_UC + 0x400
m6:
    TRAP    3, 5, 0x61
    TVAL    VA_PB, 0x62
    NOTRAP  0x63
    csrw    pmpcfg0, zero
    sfence.vma

#ifdef __riscv_compressed
    // 7. lenh 32 bit vat qua ranh gioi trang (VA_UC + 0xFFE): nua sau o trang vat ly khac
    li      a1, 0
    GO      0, VA_UC + 0xFFE
m7:
    li      t0, 85
    li      a0, 0x71
    bne     a1, t0, fail
    NOTRAP  0x72
    SETPTE  l0pt, 1, ucodeB, PTE_R | PTE_X | PTE_U | PTE_A      // trang B mat V
    sfence.vma
    GO      0, VA_UC + 0x500
m7b:
    TRAP    3, 12, 0x73
    TVAL    VA_UC2, 0x74                // mtval = pc + 2
    li      a0, 0x75
    lw      t0, -4(s9)
    li      t1, VA_UC + 0xFFE           // mepc = pc
    bne     t0, t1, fail
    NOTRAP  0x76
    SETPTE  l0pt, 1, ucodeB, PTE_V | PTE_R | PTE_X | PTE_U | PTE_A
    sfence.vma
#endif
    // 8. TVM: S doc satp / chay SFENCE.VMA -> lenh bat hop le; U chay SFENCE.VMA -> bat hop le
    li      t0, (1 << 20)
    csrs    mstatus, t0
    GOL     MPP_S, s8
s8:
    csrr    t0, satp
    sfence.vma
    li      a7, SVC
    la      a0, m8
    ecall
m8:
    TRAP    3, 2, 0x81
    TRAP    3, 2, 0x82
    NOTRAP  0x83
    li      t0, (1 << 20)
    csrc    mstatus, t0
    GO      0, VA_UC + 0x600
m8b:
    TRAP    3, 2, 0x84
    NOTRAP  0x85
#ifdef MA
    // 9. load / store lech vat qua ranh gioi trang: U tu kiem gia tri (a1 = ma loi dau tien), M kiem ban ghi trap
    li      a1, 0
    GO      0, VA_UC + 0x700
m9:
    li      a0, 0x90
    bnez    a1, fail
    TRAP    3, 13, 0x91                 // lw: trang sau V = 0
    TVAL    VA_MA2, 0x92                // mtval = dau trang sau
    TRAP    3, 15, 0x93                 // sh: trang sau V = 0
    TVAL    VA_MA2, 0x94
    TRAP    3, 13, 0x95                 // lh: trang dau V = 0
    TVAL    VA_MA2 + 0xFFF, 0x96        // mtval = dia chi
    TRAP    3, 15, 0x97                 // sw: trang sau khong W
    TVAL    VA_MA4, 0x98
    NOTRAP  0x99
    // PMP muc 0 (NAPOT 4 KiB) tren dpage0: khong quyen -> phan o dpage0 bi cam; RW -> hai muc khac nhau deu cho phep
    la      t0, dpage0
    srli    t0, t0, 2
    ori     t0, t0, 0x1FF
    csrw    pmpaddr0, t0
    li      t0, 0x18
    csrw    pmpcfg0, t0
    GO      0, VA_UC + 0x800
m9b:
    TRAP    3, 5, 0x9a                  // lw VA_MA0 + 0xFFE: trang sau (dpage0) bi cam
    TVAL    VA_MA1, 0x9b
    TRAP    3, 7, 0x9c                  // sh VA_MA1 + 0xFFF: trang dau (dpage0) bi cam truoc loi trang sau
    TVAL    VA_MA1 + 0xFFF, 0x9d
    NOTRAP  0x9e
    li      t0, 0x1B
    csrw    pmpcfg0, t0
    li      a1, 0
    GO      0, VA_UC + 0x900
m9c:
    li      a0, 0x9f
    bnez    a1, fail
    NOTRAP  0xa0
#endif
    csrw    satp, zero
#ifdef MA
    // 10. khong dich (satp = 0), U: lw vat qua ranh gioi dpage0 | dpage1, dpage0 thuoc muc 0, dpage1 thuoc muc 7.
    // Ghi lai tu cuoi cua dpage0 / dpage1 truoc (store loi o muc 9 co the da ghi mot phan o Spike, khong o lo)
    li      t1, 0x33333333
    li      t2, 0xFFC
    la      t0, dpage0
    add     t0, t0, t2
    sw      t1, 0(t0)
    la      t0, dpage1
    add     t0, t0, t2
    sw      t1, 0(t0)
    li      a1, 0
    la      a2, m10
    GOL     0, u10
m10:
    li      a0, 0xa1
    bnez    a1, fail
    NOTRAP  0xa2
    la      t0, dpage1                  // muc 0 tren dpage1, khong quyen: phan o dpage1 bi cam, mtval = dpage1
    srli    t0, t0, 2
    ori     t0, t0, 0x1FF
    csrw    pmpaddr0, t0
    li      t0, 0x18
    csrw    pmpcfg0, t0
    la      a2, m10b
    GOL     0, u10
m10b:
    TRAP    3, 5, 0xa3
    la      t1, dpage1
    li      a0, 0xa4
    lw      t0, -8(s9)
    bne     t0, t1, fail
    NOTRAP  0xa5
    csrw    pmpcfg0, zero
#endif
    li      a0, 1
fail:
    li      t0, TOHOST_ADDR
    sw      a0, 0(t0)
9:  j       9b

    .text
    .balign 4
mtrap:
    csrr    t6, mcause
    li      t5, SVC
    bne     a7, t5, m_rec
    addi    t5, t6, -8
    li      t6, 1
    bgtu    t5, t6, m_rec
    li      a7, 0
    li      t5, MPP_M
    csrs    mstatus, t5
    csrw    mepc, a0
    mret
m_rec:
    li      t5, 3
    sw      t5, 0(s8)
    csrr    t6, mcause
    sw      t6, 4(s8)
    csrr    t5, mtval
    sw      t5, 8(s8)
    csrr    t5, mepc
    sw      t5, 12(s8)
    addi    s8, s8, 16
    li      t5, 1
    beq     t6, t5, 1f
    li      t5, 12
    beq     t6, t5, 1f
    csrr    t5, mepc
    addi    t5, t5, 4
    csrw    mepc, t5
    mret
1:  csrw    mepc, ra                    // loi fetch: ve ra
    mret

    .balign 4
s_trap:
    csrr    t6, scause
    li      t5, SVC
    bne     a7, t5, s_rec
    ecall
s_rec:
    li      t5, 1
    sw      t5, 0(s8)
    sw      t6, 4(s8)
    csrr    t5, stval
    sw      t5, 8(s8)
    csrr    t5, sepc
    sw      t5, 12(s8)
    addi    s8, s8, 16
    li      t5, 12
    beq     t6, t5, 1f
    csrr    t5, sepc
    addi    t5, t5, 4
    csrw    sepc, t5
    sret
1:  csrw    sepc, ra
    sret

#ifdef MA
    .balign 4
u10:                                    // U, khong dich: lw vat qua ranh gioi dpage0 | dpage1; ve M tai a2
    la      s0, dpage0 + 0xFFE
    li      t1, 0
    lw      t1, 0(s0)                   // dpage0[0xFFE..0xFFF] + dpage1[0..1]
    li      t2, 0x3333
    slli    t3, t1, 16
    srli    t3, t3, 16
    beq     t3, t2, 1f
    li      a1, 0xa6
1:  li      a7, SVC
    mv      a0, a2
    ecall
#endif

    .data
    .balign 4096
l1pt:   .space 4096
l0pt:   .space 4096
l0pb:   .space 4096
// ---- ma U, trang A (VA_UC) ----
ucodeA:
    .option push
    .option norvc
    // 1. quyen / PTE loi
    li      s0, VA_D0
    lw      t0, 0(s0)
    li      t0, 0x13579bdf
    sw      t0, 4(s0)
    li      s0, VA_RO
    lw      t0, 0(s0)
    sw      t0, 0(s0)                   // 15
    li      s0, VA_ND
    lw      t0, 0(s0)
    sw      t0, 0(s0)                   // 15
    li      s0, VA_NA
    lw      t0, 0(s0)                   // 13
    li      s0, VA_S
    lw      t0, 0(s0)                   // 13
    li      s0, VA_X
    lw      t0, 0(s0)                   // 13
    li      s0, VA_INV
    lw      t0, 0(s0)                   // 13
    li      s0, VA_WNR
    lw      t0, 0(s0)                   // 13
    sw      t0, 0(s0)                   // 15
    li      s0, VA_HI
    lw      t0, 0(s0)                   // 5
    li      s0, VA_L0T
    lw      t0, 0(s0)                   // 13
    li      s0, VA_SPM
    lw      t0, 0(s0)                   // 13
    li      s0, VA_UT
    lw      t0, 0(s0)                   // 13
    li      t0, VA_D0
    jalr    t0                          // 12
    li      a7, SVC
    lui     a0, %hi(m1)
    addi    a0, a0, %lo(m1)                      // a0 = dia chi vat ly (dong nhat) cua m1 o M
    ecall
    .balign 0x100
    ret                                 // VA_UC + 0x100: S nhay toi day (loi fetch truoc khi chay)
    .balign 0x200
    // 3. uy quyen ve S (VA_UC + 0x200)
    li      s0, VA_NA
    lw      t0, 0(s0)                   // 13 -> S
    li      s0, VA_RO
    sw      t0, 0(s0)                   // 15 -> S
    li      t0, VA_D0
    jalr    t0                          // 12 -> S
    li      a7, SVC
    lui     a0, %hi(m3)
    addi    a0, a0, %lo(m3)
    ecall
    .balign 0x100
    // 4. VA_UC + 0x300: ghi VA_RO sau khi sua PTE
    li      s0, VA_RO
    sw      t0, 0(s0)
    li      a7, SVC
    lui     a0, %hi(m4)
    addi    a0, a0, %lo(m4)
    ecall
    .balign 0x100
    // 6. VA_UC + 0x400: doc qua bang bi PMP cam
    li      s0, VA_PB
    lw      t0, 0(s0)                   // 5
    li      a7, SVC
    lui     a0, %hi(m6)
    addi    a0, a0, %lo(m6)
    ecall
    .balign 0x100
#ifdef __riscv_compressed
    // 7b. VA_UC + 0x500: nhay toi lenh vat trang khi trang B mat V -> 12 (handler ve ra)
    li      t0, VA_UC + 0xFFE
    jalr    t0
    li      a7, SVC
    lui     a0, %hi(m7b)
    addi    a0, a0, %lo(m7b)
    ecall
    .balign 0x100
#endif
    .skip   ucodeA + 0x600 - .
    sfence.vma                          // 8. U: lenh bat hop le
    li      a7, SVC
    lui     a0, %hi(m8b)
    addi    a0, a0, %lo(m8b)
    ecall
#ifdef MA
    .skip   ucodeA + 0x700 - .
    // 9. VA_UC + 0x700: lech vat trang (VA_MA0 -> dpage1, VA_MA1 -> dpage0: trang vat ly sau nam TRUOC trang dau)
    li      s0, VA_MA0 + 0xFFE
    lw      t1, 0(s0)                   // dpage1[0xFFE..0xFFF] + dpage0[0..1]
    li      t2, 0x11112222
    beq     t1, t2, 1f
    li      a1, 0x81
1:  li      t0, 0xA1B2C3D4
    sw      t0, -1(s0)                  // 3 byte o trang dau, 1 byte o trang sau
    lw      t1, -1(s0)
    beq     t1, t0, 1f
    li      a1, 0x82
1:  lbu     t1, 2(s0)                   // VA_MA1 + 0 = byte cao
    li      t2, 0xA1
    beq     t1, t2, 1f
    li      a1, 0x83
1:  lh      t1, 1(s0)                   // half vat trang: 0xA1B2 mo rong dau
    li      t2, 0xFFFFA1B2
    beq     t1, t2, 1f
    li      a1, 0x84
1:  sh      t0, 1(s0)                   // 0xD4 o cuoi trang dau, 0xC3 o dau trang sau
    lhu     t1, 1(s0)
    li      t2, 0xC3D4
    beq     t1, t2, 1f
    li      a1, 0x85
1:  lw      t1, -2(s0)                  // VA_MA0 + 0xFFC: tu cuoi trang dau, khong vat trang
    li      t2, 0xD4C3D422
    beq     t1, t2, 1f
    li      a1, 0x86
1:  li      s0, VA_MA1 + 0xFFE
    lw      t1, 0(s0)                   // 13, mtval = VA_MA2
    sh      t0, 1(s0)                   // 15, mtval = VA_MA2
    li      s0, VA_MA2 + 0xFFF
    lh      t1, 0(s0)                   // 13, mtval = VA_MA2 + 0xFFF
    li      s0, VA_MA3 + 0xFFD
    lw      t1, 0(s0)                   // doc duoc (trang sau chi R)
    sw      t0, 0(s0)                   // 15, mtval = VA_MA4
    li      a7, SVC
    lui     a0, %hi(m9)
    addi    a0, a0, %lo(m9)
    ecall
    .skip   ucodeA + 0x800 - .
    // VA_UC + 0x800: PMP muc 0 cam dpage0
    li      s0, VA_MA0 + 0xFFE
    lw      t1, 0(s0)                   // 5, mtval = VA_MA1
    li      s0, VA_MA1 + 0xFFF
    sh      t0, 0(s0)                   // 7, mtval = VA_MA1 + 0xFFF (trang sau V = 0 khong duoc xet)
    li      a7, SVC
    lui     a0, %hi(m9b)
    addi    a0, a0, %lo(m9b)
    ecall
    .skip   ucodeA + 0x900 - .
    // VA_UC + 0x900: PMP muc 0 cho RW tren dpage0, dpage1 thuoc muc 7: truy cap vat trang qua hai muc deu duoc
    li      s0, VA_MA0 + 0xFFE
    lw      t1, 0(s0)
    li      t2, 0x11C3D4C3
    beq     t1, t2, 1f
    li      a1, 0x87
1:  li      t0, 0x5566
    sh      t0, 1(s0)
    lhu     t1, 1(s0)
    beq     t1, t0, 1f
    li      a1, 0x88
1:  li      a7, SVC
    lui     a0, %hi(m9c)
    addi    a0, a0, %lo(m9c)
    ecall
#endif
    .skip   ucodeA + 0xFFE - .
    .half   0x8593                      // nua thap cua addi a1, a1, 85 (0x05558593)
// ---- trang dem giua A va B (khong anh xa) ----
    .balign 4096
gap:    .space 4096
// ---- ma U, trang B (VA_UC2) ----
ucodeB:
    .half   0x0555                      // nua cao cua addi a1, a1, 85
    li      a7, SVC
#ifdef __riscv_compressed
    lui     a0, %hi(m7)
    addi    a0, a0, %lo(m7)
#else
    lui     a0, %hi(fail)
    addi    a0, a0, %lo(fail)
#endif
    ecall
    .option pop
    .balign 4096
dpage0: .fill 1024, 4, 0x11111111
dpage1: .fill 1024, 4, 0x22222222
xpage:  .fill 1024, 4, 0x00000013
plog:   .space 1024
