// Benchmark nang lenh M (nhan/chia), bien dich voi -march=rv32im. Ghi checksum vao RESULT[] nhu bench.c.
#define RESULT ((volatile unsigned *)0x800)

static unsigned lcg(unsigned x) { return x ^ (x << 13) ^ (x >> 7) ^ (x << 17); }

static unsigned matmul(void) {                 // nhan ma tran 8x8 (MUL)
    int a[64], b[64]; unsigned x = 4242, s = 0;
    for (int i = 0; i < 64; i++) { x = lcg(x); a[i] = (int)(x & 0x3FF) - 512; x = lcg(x); b[i] = (int)(x & 0x3FF) - 512; }
    for (int r = 0; r < 8; r++)
        for (int c = 0; c < 8; c++) {
            int acc = 0;
            for (int k = 0; k < 8; k++) acc += a[r * 8 + k] * b[k * 8 + c];
            s = s * 31 + (unsigned)acc;
        }
    return s;
}

static unsigned modexp(void) {                 // luy thua mo-dun (MUL, REMU)
    unsigned s = 0;
    for (unsigned base = 3; base < 23; base++) {
        unsigned r = 1, b = base, e = 1000003u, m = 65521u;
        while (e) { if (e & 1) r = (r * b) % m; b = (b * b) % m; e >>= 1; }
        s ^= r + base;
    }
    return s;
}

static unsigned digits(void) {                 // tong chu so thap phan (DIVU, REMU)
    unsigned s = 0, x = 31337;
    for (int i = 0; i < 48; i++) {
        x = lcg(x);
        for (unsigned v = x; v; v /= 10) s += v % 10;
    }
    return s;
}

static unsigned gcdsum(void) {                 // UCLN bang phep chia lay du (REMU)
    unsigned s = 0, x = 2024;
    for (int i = 0; i < 40; i++) {
        x = lcg(x); unsigned a = x & 0xFFFFF; x = lcg(x); unsigned b = (x & 0xFFFFF) | 1;
        while (b) { unsigned t = a % b; a = b; b = t; }
        s += a;
    }
    return s;
}

static unsigned signedops(void) {              // chia va nhan co dau, MULH (DIV, REM, MULH)
    int x = 777; unsigned s = 0;
    for (int i = 0; i < 40; i++) {
        x = (int)lcg((unsigned)x);
        int d = (x >> 20) | 1;
        long long p = (long long)x * (long long)d;
        s += (unsigned)(x / d) ^ (unsigned)(x % d) ^ (unsigned)(p >> 32);
    }
    return s;
}

int main(void) {
    RESULT[0] = matmul();
    RESULT[1] = modexp();
    RESULT[2] = digits();
    RESULT[3] = gcdsum();
    RESULT[4] = signedops();
    return 0;
}
