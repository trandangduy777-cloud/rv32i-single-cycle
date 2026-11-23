#include "soc.h"
/* Xu ly trap mac dinh (yeu): moi trap khong duoc test dang ky deu ket thuc chuong trinh voi ma 0xDEAD0000 | mcause (ngat: 0xDEAE0000 | cause). */
__attribute__((weak)) void trap_c(void) {
    u32 c = csr_read(mcause);
    die((c & 0x80000000u) ? (0xDEAE0000u | (c & 0xFFFF)) : (0xDEAD0000u | (c & 0xFFFF)));
}
