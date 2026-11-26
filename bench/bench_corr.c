// Benchmark nhanh tuong quan cho bo du doan (bpred/, tage/): moi bai co nhanh ma huong phu thuoc lich su nhanh
// toan cuc o khoang cach khac nhau, nen bang dem theo pc doan kem va lich su dai doan tot hon. Khong dung nhan / chia.
#ifndef RESULT_ADDR
#define RESULT_ADDR 0x800
#endif
#define RESULT ((volatile unsigned *)RESULT_ADDR)

static unsigned lcg(unsigned x) { return x ^ (x << 13) ^ (x >> 7) ^ (x << 17); }

// mau tuan hoan chu ky 7 (3 nhay, 4 khong nhay): can lich su >= 7 bit cua chinh nhanh nay
static unsigned periodic(void) {
    unsigned s = 0, k = 0;
    for (int i = 0; i < 700; i++) {
        if (k < 3) s += i; else s ^= i;
        if (++k == 7) k = 0;
    }
    return s;
}

// nhanh lap lai dieu kien ngau nhien cua 2 nhanh truoc do (cach nhau vai nhanh khac): tuong quan toan cuc
static unsigned correl(void) {
    unsigned x = 99, s = 0;
    for (int i = 0; i < 600; i++) {
        x = lcg(x);
        unsigned a = x & 1, b = (x >> 5) & 1;
        if (a) s += 3;                     // ngau nhien
        if (b) s ^= 5;                     // ngau nhien
        if (s & 0x100) s += 1;             // khong lien quan
        if (a ^ b) s += 7;                 // = huong 2 nhanh dau: doan dung neu co lich su
        if (a) s -= 1;                     // = huong nhanh dau
    }
    return s;
}

// vong lap trong 12 lan: lan thoat chi doan dung neu nho > 12 lan "nhay" truoc do
static unsigned trip(void) {
    unsigned s = 0;
    for (int i = 0; i < 120; i++) {
        unsigned v = i;
        for (int j = 0; j < 12; j++) v = (v << 1) ^ (v >> 3) ^ j;
        s += v;
    }
    return s;
}

// may trang thai: huong phu thuoc 3 buoc truoc (chuoi ky tu co cau truc)
static unsigned fsm(void) {
    static const unsigned char pat[] = {1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 1, 0, 0, 0, 1, 0};
    unsigned s = 0, st = 0;
    for (int r = 0; r < 40; r++)
        for (int i = 0; i < 16; i++) {
            if (pat[i]) st = (st << 1) | 1; else st <<= 1;
            if ((st & 7) == 5) s += i; else s ^= r;
        }
    return s;
}

int main(void) {
    RESULT[0] = periodic();
    RESULT[1] = correl();
    RESULT[2] = trip();
    RESULT[3] = fsm();
    return 0;
}
