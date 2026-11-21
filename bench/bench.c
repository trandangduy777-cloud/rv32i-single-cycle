// Bo benchmark nho, khong dung libc, khong dung nhan/chia (de chay duoc tren RV32I thuan).
// Moi bai ghi checksum vao RESULT[] de doi chieu giua cac cau hinh loi.
#ifndef RESULT_ADDR
#define RESULT_ADDR 0x800      // cosim/run_cosim.py doi sang vung nho cua Spike
#endif
#define RESULT ((volatile unsigned *)RESULT_ADDR)

static unsigned lcg(unsigned x) { return x ^ (x << 13) ^ (x >> 7) ^ (x << 17); }

static unsigned bubble(void) {                 // sap xep noi bot 48 phan tu
    unsigned a[48]; unsigned x = 12345;
    for (int i = 0; i < 48; i++) { x = lcg(x); a[i] = x & 0xFFFF; }
    for (int i = 0; i < 47; i++)
        for (int j = 0; j < 47 - i; j++)
            if (a[j] > a[j + 1]) { unsigned t = a[j]; a[j] = a[j + 1]; a[j + 1] = t; }
    unsigned s = 0;
    for (int i = 0; i < 48; i++) s = (s << 1) ^ a[i];
    return s;
}

static unsigned sieve(void) {                  // sang nguyen to den 600
    unsigned char f[600];
    for (int i = 0; i < 600; i++) f[i] = 1;
    unsigned cnt = 0;
    for (int i = 2; i < 600; i++)
        if (f[i]) { cnt++; for (int j = i + i; j < 600; j += i) f[j] = 0; }
    return cnt;
}

static unsigned crc(void) {                    // CRC32 theo bit tren 128 byte (nhanh phu thuoc du lieu)
    unsigned c = 0xFFFFFFFFu, x = 777;
    for (int i = 0; i < 128; i++) {
        x = lcg(x);
        c ^= x & 0xFF;
        for (int b = 0; b < 8; b++) c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : (c >> 1);
    }
    return ~c;
}

static unsigned matadd(void) {                 // cong ma tran 12x12 hai vong long nhau (nhanh sau, de doan)
    unsigned a[144], b[144], s = 0;
    for (int i = 0; i < 144; i++) { a[i] = i; b[i] = i ^ 5; }
    for (int r = 0; r < 12; r++)
        for (int c = 0; c < 12; c++) { unsigned k = c + 12 * r; a[k] += b[k]; s += a[k]; }
    return s;
}

static unsigned search(void) {                 // tim nhi phan lap lai tren mang da sap (nhanh khong de doan)
    unsigned a[64]; unsigned s = 0, x = 99;
    for (int i = 0; i < 64; i++) a[i] = (unsigned)i << 2;
    for (int k = 0; k < 64; k++) {
        x = lcg(x); unsigned key = x & 0xFF;
        int lo = 0, hi = 63;
        while (lo < hi) { int m = (lo + hi) >> 1; if (a[m] < key) lo = m + 1; else hi = m; }
        s += lo;
    }
    return s;
}

int main(void) {
    RESULT[0] = bubble();
    RESULT[1] = sieve();
    RESULT[2] = crc();
    RESULT[3] = matadd();
    RESULT[4] = search();
    return 0;
}
