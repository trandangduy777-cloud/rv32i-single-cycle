// Tai tinh toan (nhan, chia, load/store, nhanh kho doan, goi ham) cho kiem tra halt / resume trong suot: ket qua phai dung du bi
// dung va tiep tuc o bat ky dau. checksum() duoc tinh lai tren may chu (debug/fw/stress_expect.c) de lay gia tri mong doi.
#include <stdint.h>
#ifndef EXPECT
#define EXPECT 3975057799u
#endif
volatile uint32_t progress = 0;      // so vong da chay (debugger doc de thay chuong trinh dang chay)
static uint32_t arr[32];
static uint32_t rng(uint32_t *s) { *s = *s * 1664525u + 1013904223u; return *s; }
uint32_t checksum(void) {
    uint32_t s = 12345, h = 0;
    for (int round = 0; round < 60; round++) {
        for (int i = 0; i < 32; i++) arr[i] = rng(&s) >> 8;
        for (int i = 0; i < 31; i++)                                 // sap xep noi bot mot luot: nhanh phu thuoc du lieu
            if (arr[i] > arr[i + 1]) { uint32_t t = arr[i]; arr[i] = arr[i + 1]; arr[i + 1] = t; }
        for (int i = 0; i < 32; i++) {
            h = h * 31u + arr[i];
            h ^= (arr[i] * 2654435761u) >> 5;
            if (arr[i] % 7u == 3u) h += arr[i] / 13u;
        }
        progress = round + 1;
    }
    return h;
}
int main(void) {
    uint32_t h = checksum();
    return (h == EXPECT) ? 1 : 0;
}
