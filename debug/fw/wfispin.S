# WFI vo han (mie = 0): debugger phai dung duoc hart dang ngu trong WFI
    .section .text.init
    .globl _start
_start:
    csrw mie, zero
    .globl wfi_here
wfi_here:
    wfi
    j    wfi_here
