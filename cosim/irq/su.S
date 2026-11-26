// Kiem che do Supervisor / User (rv32im_pipeline.v, SU = 1) so tung lenh voi Spike (che do MSU, khong MMU):
// - WARL: misa co S / U, MPP sau reset = U, MPP = 2 ghi thanh U, FS = 3 bat SD, medeleg / mideleg / satp / sstatus
// - ECALL tu U / S / M (ma 8 / 9 / 11), uy quyen exception qua medeleg (ve S) hoac khong (ve M)
// - CSR va lenh dac quyen: CSR M doc o S / U, CSR S doc o U, MRET o S, SRET o U va o S khi TSR, WFI o U va o S khi TW
// - mcounteren / scounteren chan doc cycle / instret / hpmcounter o S / U
// - ngat S (SSIP / STIP / SEIP do phan mem dat): uy quyen qua mideleg, SIE, uu tien SEI > SSI, stvec vectored,
//   ngat ve M van duoc nhan o U khi MIE = 0, ngat timer M trong luc chay o U
// - PMP voi S / U: muc khong khoa rang buoc S / U, khong khop muc nao la loi, MPRV + MPP = U cho load o che do M
// Trinh xu ly M va S ghi (che do, mcause / scause, tval, epc) vao plog; ECALL voi a7 = 0x99 la dich vu "ve che do M
// tai dia chi a0". TOHOST = 1: dat; 0x10 | ma: loi tu kiem.
#include "irq_defs.h"

#define SVC     0x99
#define MPP_M   0x1800
#define MPP_S   0x0800

// ghi nhan trap: s8 tro vao plog, moi ban ghi 16 byte (che do, cause, tval, epc); s9 = ban ghi da kiem toi.
// TRAP kiem ban ghi ke tiep, NOTRAP kiem khong con ban ghi nao chua kiem
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
// epc cua ban ghi cuoi = nhan
.macro EPC lbl, code
    li      a0, \code
    lw      t0, -4(s9)
    la      t1, \lbl
    bne     t0, t1, fail
.endm
// chuyen che do tu M: MPP = mode, mepc = lbl, mret
.macro GO mpp, lbl
    li      t0, MPP_M
    csrc    mstatus, t0
    li      t0, \mpp
    csrs    mstatus, t0
    la      t0, \lbl
    csrw    mepc, t0
    mret
.endm
// tu U / S ve M tai lbl
.macro BACK lbl
    li      a7, SVC
    la      a0, \lbl
    ecall
.endm

    .section .text.init
    .globl _start
_start:
    .option norvc                       // lenh bi trap dai 4 byte (handler: epc += 4)
    li      sp, 0x8003F000
    la      t0, mtrap
    csrw    mtvec, t0
    la      t0, svtab
    ori     t0, t0, 1                   // stvec vectored
    csrw    stvec, t0
    la      s8, plog
    mv      s9, s8
    li      a7, 0
    // PMP: muc 7 (uu tien thap nhat) NAPOT toan bo khong gian RWX, khong khoa -> S / U chay duoc
    li      t0, -1
    csrw    pmpaddr7, t0
    li      t0, 0x1F << 24
    csrw    pmpcfg1, t0

    // 1. WARL
    csrr    t0, misa
    li      t1, (1 << 18) | (1 << 20)
    and     t2, t0, t1
    li      a0, 0x11
    bne     t2, t1, fail
    csrr    t0, mstatus                 // MPP sau reset = U
    li      t1, MPP_M
    and     t0, t0, t1
    li      a0, 0x12
    bnez    t0, fail
    li      t0, 0x1000                  // MPP = 2 -> U
    csrs    mstatus, t0
    csrr    t0, mstatus
    li      t1, MPP_M
    and     t0, t0, t1
    li      a0, 0x13
    bnez    t0, fail
    li      t0, 0x6000                  // FS = 3 -> SD
    csrs    mstatus, t0
    csrr    t0, mstatus
    li      a0, 0x14
    bgez    t0, fail
    li      t0, 0x6000
    csrc    mstatus, t0
    li      t0, -1
    csrw    medeleg, t0
    csrr    t1, medeleg
    csrr    t3, misa                    // co C (misa bit 2): bit 0 (lech dia chi lenh) khong uy quyen duoc
    andi    t3, t3, 4
    srli    t3, t3, 2
    li      t2, 0x803FF
    sub     t2, t2, t3
    li      t0, -1                      // co MMU (satp ghi duoc): them loi trang 12, 13, 15
    csrw    satp, t0
    csrr    s7, satp                    // s7 != 0: co MMU
    csrw    satp, zero
    beqz    s7, 1f
    li      t0, 0xB000
    or      t2, t2, t0
1:
    li      a0, 0x15
    bne     t1, t2, fail
    csrw    medeleg, zero
    li      t0, -1
    csrw    mideleg, t0
    csrr    t1, mideleg
    li      t2, 0x222
    li      a0, 0x16
    bne     t1, t2, fail
    csrw    mideleg, zero
    li      t0, -1
    csrw    satp, t0                    // khong co MMU: satp = 0; co MMU: ghi duoc het
    csrr    t1, satp
    csrw    satp, zero
    li      a0, 0x17
    beqz    s7, 2f
    bne     t1, t0, fail
    j       3f
2:  bnez    t1, fail
3:
    csrw    sstatus, t0
    csrr    t1, sstatus
    li      t2, 0x80006122
    beqz    s7, 4f
    li      t3, 0xC0000                 // co MMU: SUM, MXR
    or      t2, t2, t3
4:
    li      a0, 0x18
    bne     t1, t2, fail
    csrw    sstatus, zero
    csrw    mcounteren, t0
    csrr    t1, mcounteren
    li      a0, 0x19
    bne     t1, t0, fail
    csrw    mcounteren, zero

    // 2. U khong uy quyen: ECALL / lenh dac quyen ve M
    GO      0, u1
u1:
    add     s0, s0, s0
    ecall
    csrr    t0, mstatus
    csrr    t0, sstatus
    rdcycle t0
    wfi
    sret
    mret
    BACK    m1
m1:
    li      a0, 0x21
    li      s0, 0
u1_chk:
    TRAP    3, 8, 0x22
    EPC     u1 + 4, 0x23
    TRAP    3, 2, 0x24
    TRAP    3, 2, 0x25
    TRAP    3, 2, 0x26
    TRAP    3, 2, 0x27
    TRAP    3, 2, 0x28
    TRAP    3, 2, 0x29
    lw      t0, -8(s9)                  // mtval = ma lenh mret
    li      t1, 0x30200073
    li      a0, 0x2a
    bne     t0, t1, fail

    NOTRAP  0x2f
    // 3. bo dem: mcounteren / scounteren
    li      t0, -1
    csrw    mcounteren, t0
    GO      MPP_S, s3
s3:
    rdcycle t0                          // S: mcounteren du
    rdinstret t1
    csrr    t2, hpmcounter3
    BACK    m3a
m3a:
    NOTRAP  0x31
    li      t0, 5
    csrw    scounteren, t0
    GO      0, u3
u3:
    rdcycle t0                          // U: cycle (bit 0), instret (bit 2) duoc; hpmcounter3 khong
    rdinstret t1
    csrr    t2, hpmcounter3
    BACK    m3b
m3b:
    TRAP    3, 2, 0x32
    csrwi   mcounteren, 1               // xoa bit 2 cua mcounteren: instret o S / U bi chan du scounteren cho phep
    GO      0, u3c
u3c:
    rdinstret t1
    BACK    m3c
m3c:
    TRAP    3, 2, 0x33
    csrw    mcounteren, zero
    csrw    scounteren, zero

    NOTRAP  0x3f
    // 4. uy quyen exception ve S: ECALL tu U, lenh khong hop le; ECALL tu S van ve M
    li      t0, (1 << 8) | (1 << 2)
    csrw    medeleg, t0
    .word   0                           // lenh khong hop le o M: khong uy quyen (chi uy quyen tu U / S)
    TRAP    3, 2, 0x40
    GO      0, u4
u4:
    ecall                               // -> S (8)
    csrr    t0, sstatus                 // -> S (2)
    .word   0                           // lenh khong hop le -> S (2)
    BACK    m4a                         // dich vu: S chuyen tiep len M
m4a:
    TRAP    1, 8, 0x41
    EPC     u4, 0x42
    TRAP    1, 2, 0x43
    TRAP    1, 2, 0x44
    GO      MPP_S, s4
s4:
    csrr    t0, mstatus                 // S doc CSR M -> lenh khong hop le, uy quyen -> chinh S (2)
    mret                                // -> S (2)
    csrr    t0, sscratch                // S doc CSR S: duoc
    ecall                               // ECALL tu S (9) khong uy quyen -> M
    BACK    m4b
m4b:
    TRAP    1, 2, 0x45
    TRAP    1, 2, 0x46
    TRAP    3, 9, 0x47
    csrw    medeleg, zero

    NOTRAP  0x4f
    // 5. TSR / TW
    li      t0, (1 << 22) | (1 << 21)
    csrs    mstatus, t0
    GO      MPP_S, s5
s5:
    sret                                // TSR: lenh khong hop le
    wfi                                 // TW: lenh khong hop le
    BACK    m5
m5:
    TRAP    3, 2, 0x51
    TRAP    3, 2, 0x52
    li      t0, (1 << 22) | (1 << 21)
    csrc    mstatus, t0

    NOTRAP  0x5f
    // 6. SRET: tu S ve U (SPP = 0), SPIE -> SIE
    li      t0, 0x20                    // SPIE = 1, SPP = 0
    csrs    sstatus, t0
    GO      MPP_S, s6
s6:
    la      t0, u6
    csrw    sepc, t0
    sret
u6:
    csrr    t0, sstatus                 // U: khong hop le (ve M)
    BACK    m6
m6:
    TRAP    3, 2, 0x61
    EPC     u6, 0x62
    csrr    t0, sstatus                 // SIE = SPIE cu = 1, SPIE = 1, SPP = 0
    andi    t0, t0, 0x122
    li      t1, 0x22
    li      a0, 0x63
    bne     t0, t1, fail
    csrw    sstatus, zero

    NOTRAP  0x6f
    // 7. ngat S do phan mem: uy quyen, SIE, WFI khi ngat cho nhung chua duoc nhan
    li      t0, 0x222
    csrw    mideleg, t0
    li      t0, 0x2                     // mie.SSIE
    csrs    mie, t0
    csrs    mip, t0                     // mip.SSIP: o M khong nhan (uy quyen ve S, M cao hon S)
    nop
    NOTRAP  0x71
    GO      MPP_S, s7
s7:
    wfi                                 // SSIP cho + SSIE: WFI xong, nhung SIE = 0 nen khong nhan o S
    nop
    csrsi   sstatus, 2                  // SIE = 1 -> nhan ngay
s7a:
    nop
    BACK    m7
m7:
    TRAP    1, 0x80000001, 0x72
    EPC     s7a, 0x73
    // ngat S khi dang o U: luon nhan (U thap hon S) du SIE = 0
    csrw    sstatus, zero
    li      t0, 0x2
    csrs    mip, t0
    GO      0, u7
u7:
    nop
    BACK    m7b
m7b:
    TRAP    1, 0x80000001, 0x74
    EPC     u7, 0x75
    // uu tien SEI > SSI, stvec vectored (SEI nhay toi muc 9)
    li      t0, 0x202
    csrs    mie, t0
    csrs    mip, t0
    GO      0, u7c
u7c:
    nop
    nop
    BACK    m7c
m7c:
    TRAP    1, 0x80000009, 0x76         // S tat SEIE roi quay lai, SSI duoc nhan ke tiep
    TRAP    1, 0x80000001, 0x77
    li      t0, 0x200
    csrc    mip, t0
    // STIP khong uy quyen: ngat ve M, nhan o U du MIE = 0
    li      t0, 0x88                    // MIE = MPIE = 0 (MRET chep MPIE vao MIE): o U ngat M van phai duoc nhan
    csrc    mstatus, t0
    li      t0, 0x200
    csrw    mideleg, t0
    li      t0, 0x20
    csrs    mie, t0
    csrs    mip, t0
    NOTRAP  0x78                        // o M voi MIE = 0: khong nhan
    GO      0, u7d
u7d:
    nop
    BACK    m7d
m7d:
    TRAP    3, 0x80000005, 0x79
    EPC     u7d, 0x7a
    csrw    mideleg, zero
    csrw    mie, zero

    NOTRAP  0x7f
    // 8. ngat timer M trong luc chay o U (MIE = 0)
    li      t0, 0x88
    csrc    mstatus, t0
    li      t0, TMR
    lw      t1, 0(t0)
    addi    t1, t1, 80
    sw      t1, 8(t0)
    sw      zero, 12(t0)
    li      t0, 0x80
    csrs    mie, t0
    GO      0, u8
u8:
    li      t0, 400
1:  addi    t0, t0, -1
    bnez    t0, 1b
    BACK    m8
m8:
    TRAP    3, 0x80000007, 0x81
    csrw    mie, zero

    NOTRAP  0x8f
    // 8b. o M: ngat S uy quyen dang cho khong duoc nhan du SIE = 1; sie / sip chi ghi duoc bit da uy quyen;
    // MRET ve U xoa MPRV
    li      t0, 0x222
    csrw    mideleg, t0
    li      t0, 0x2
    csrs    mie, t0
    csrs    mip, t0
    csrsi   sstatus, 2
    nop
    nop
    csrci   sstatus, 2
    csrc    mip, t0
    NOTRAP  0x82
    csrw    mie, zero
    csrw    mideleg, zero
    li      t0, -1
    csrw    sie, t0                     // khong uy quyen gi: sie khong ghi duoc
    csrw    sip, t0
    csrr    t1, mie
    csrr    t2, mip
    andi    t2, t2, 0x222               // bo bit ngat M (phu thuoc testbench)
    li      a0, 0x83
    bnez    t1, fail
    bnez    t2, fail
    li      t0, (1 << 17)
    csrs    mstatus, t0
    GO      0, u8b
u8b:
    BACK    m8b
m8b:
    csrr    t0, mstatus
    srli    t0, t0, 17
    andi    t0, t0, 1
    li      a0, 0x84
    bnez    t0, fail
    // 9. PMP cho S / U: muc khong khoa rang buoc S / U (khong rang buoc M); MPRV
    la      t0, pdata
    srli    t1, t0, 2
    csrw    pmpaddr0, t1                // muc 0: NA4 pdata, khong quyen
    addi    t1, t0, 64
    srli    t1, t1, 2
    ori     t1, t1, 7
    csrw    pmpaddr1, t1                // muc 1: NAPOT pdata + 64 (64 byte), chi R
    la      t1, xcode
    srli    t1, t1, 2
    ori     t1, t1, 7
    csrw    pmpaddr2, t1                // muc 2: NAPOT xcode, chi R (khong X)
    li      t1, (0x19 << 16) | (0x19 << 8) | 0x10
    csrw    pmpcfg0, t1
    la      s0, pdata
    lw      t0, 0(s0)                   // M: muc khong khoa khong rang buoc
    sw      t0, 64(s0)
    call    xcode
    NOTRAP  0x91
    GO      0, u9
u9:
    lw      t0, 0(s0)                   // U: load muc 0 -> 5
    lw      t0, 64(s0)                  // U: muc 1 R -> duoc
    sw      t0, 64(s0)                  // U: muc 1 khong W -> 7
    call    xcode                       // U: muc 2 khong X -> 1 (handler quay ve ra)
    BACK    m9
m9:
    TRAP    3, 5, 0x92
    TRAP    3, 7, 0x93
    TRAP    3, 1, 0x94
    la      t0, xcode
    lw      t1, -8(s9)
    li      a0, 0x95
    bne     t0, t1, fail
    csrw    pmpaddr7, zero              // bo muc 7: o S khong khop muc nao -> loi fetch; handler M ve M tai mprv
    csrw    pmpcfg1, zero
    GO      MPP_S, nomatch
    // MPRV + MPP = U: load cua M dung quyen U
mprv:
    li      t0, -1
    csrw    pmpaddr7, t0
    li      t0, 0x1F << 24
    csrw    pmpcfg1, t0
    TRAP    3, 1, 0x96
    EPC     nomatch, 0x9a
    li      t0, (1 << 17)               // MPRV = 1, MPP = U
    csrs    mstatus, t0
    li      t0, MPP_M
    csrc    mstatus, t0
    lw      t0, 0(s0)                   // load muc 0 voi quyen U -> 5
    li      t0, (1 << 17)
    csrc    mstatus, t0
    TRAP    3, 5, 0x97
    lw      t0, 0(s0)                   // MPRV = 0: duoc
    NOTRAP  0x98
    csrw    pmpcfg0, zero

    NOTRAP  0x9f
    li      a0, 1
fail:
    li      t0, TOHOST_ADDR
    sw      a0, 0(t0)
2:  j       2b

    .text
    .balign 4
// ---- trinh xu ly M ----
mtrap:
    csrr    t6, mcause
    bltz    t6, m_irq
    li      t5, SVC                     // dich vu: ECALL tu U / S voi a7 = SVC -> ve M tai a0
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
    bltz    t6, m_irq2
    li      t5, 1
    beq     t6, t5, m_fetch
    csrr    t5, mepc
    addi    t5, t5, 4
    csrw    mepc, t5
    mret
m_fetch:                                // loi fetch: ve ra (cung che do). Truong hop PMP khong khop o S (muc 9):
    la      t5, nomatch                 // ve M tai mprv thay vi ra
    csrr    t6, mepc
    bne     t5, t6, 1f
    la      t5, mprv
    csrw    mepc, t5
    li      t5, MPP_M
    csrs    mstatus, t5
    mret
1:  csrw    mepc, ra
    mret
m_irq:
    li      t5, 3
    sw      t5, 0(s8)
    sw      t6, 4(s8)
    sw      zero, 8(s8)
    csrr    t5, mepc
    sw      t5, 12(s8)
    addi    s8, s8, 16
m_irq2:
    andi    t6, t6, 0xf
    li      t5, 7
    bne     t6, t5, 1f
    li      t5, TMR                     // timer: dat mtimecmp rat xa
    li      t6, -1
    sw      t6, 12(t5)
    mret
1:  li      t5, 5
    bne     t6, t5, 2f
    li      t5, 0x20                    // STIP
    csrc    mip, t5
    mret
2:  li      t5, 9
    bne     t6, t5, 3f
    li      t5, 0x200
    csrc    mip, t5
    mret
3:  li      t5, 0x2                     // SSIP
    csrc    mip, t5
    mret

// ---- trinh xu ly S (stvec vectored: moi muc nhay toi s_trap) ----
    .balign 64
svtab:
    .rept 16
    j       s_trap
    .endr
s_trap:
    csrr    t6, scause
    bltz    t6, s_irq
    li      t5, SVC                     // dich vu: chuyen tiep len M bang ECALL tu S
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
    addi    t5, t5, 4
    csrw    sepc, t5
    sret
s_irq:
    li      t5, 1
    sw      t5, 0(s8)
    sw      t6, 4(s8)
    sw      zero, 8(s8)
    csrr    t5, sepc
    sw      t5, 12(s8)
    addi    s8, s8, 16
    andi    t6, t6, 0xf
    li      t5, 9
    bne     t6, t5, 1f
    li      t5, 0x200                   // SEI: S khong xoa duoc SEIP, tat SEIE
    csrc    sie, t5
    sret
1:  li      t5, 0x2
    csrc    sip, t5
    sret

    .balign 64
xcode:                                  // vung 64 byte cua muc 2 (khong X)
    ret
    .balign 64
nomatch:
    nop
    .balign 64

    .data
    .balign 256
pdata:
    .fill   64, 4, 0x5a5aa5a5
plog:
    .space  1024
