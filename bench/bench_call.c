// Benchmark nhieu loi goi ham va nhay gian tiep (kiem bo du doan dich: BTB, RAS), tu viet. Khong dung libc, khong dung
// nhan/chia (chay duoc tren RV32I thuan). Ham danh dau noinline de trinh bien dich khong gop vao main.
// Moi bai ghi checksum vao RESULT[] de doi chieu giua cac cau hinh loi.
#ifndef RESULT_ADDR
#define RESULT_ADDR 0x800      // cosim/run_cosim.py doi sang vung nho cua Spike
#endif
#define RESULT ((volatile unsigned *)RESULT_ADDR)
#define NOINLINE __attribute__((noinline))

// 1) de quy: fibonacci nhi phan (goi / tra ve sau toi 16 tang, vuot RAS nho)
static NOINLINE unsigned fib(unsigned n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

// 2) duyet cay nhi phan dang mang (de quy 2 nhanh, do sau 7)
static unsigned tree[127];
static NOINLINE unsigned tsum(unsigned i) {
    if (i >= 127) return 0;
    return tree[i] + tsum(2 * i + 1) + (tsum(2 * i + 2) << 1);
}

// 3) goi qua con tro ham: 4 ham, thu tu goi doi theo du lieu (JALR gian tiep, dich thay doi)
static NOINLINE unsigned op_add(unsigned x) { return x + 0x9E37; }
static NOINLINE unsigned op_xor(unsigned x) { return x ^ (x >> 3); }
static NOINLINE unsigned op_rot(unsigned x) { return (x << 5) | (x >> 27); }
static NOINLINE unsigned op_sub(unsigned x) { return x - (x << 2); }
static unsigned (*const ops[4])(unsigned) = {op_add, op_xor, op_rot, op_sub};
static NOINLINE unsigned dispatch(void) {
    unsigned x = 1, s = 0;
    for (int i = 0; i < 400; i++) {
        x = ops[(i ^ (i >> 2)) & 3](x);           // mau lap chu ky 16: BTB (1 dich / lenh) doan sai thuong xuyen
        s += x;
    }
    for (int i = 0; i < 400; i++) { x = ops[1](x); s ^= x; }   // cung 1 dich: BTB doan dung
    return s;
}

// 4) may trang thai bang switch day dac (gcc sinh bang nhay: JALR gian tiep)
static NOINLINE unsigned fsm(void) {
    unsigned st = 0, acc = 7;
    for (int i = 0; i < 600; i++) {
        switch (st) {
            case 0: acc += 3;          st = 1; break;
            case 1: acc ^= acc >> 2;   st = (acc & 1) ? 2 : 4; break;
            case 2: acc += acc << 1;   st = 3; break;
            case 3: acc -= 11;         st = 5; break;
            case 4: acc = (acc << 3) ^ acc; st = 6; break;
            case 5: acc += 0x55;       st = 7; break;
            case 6: acc ^= 0xA5A5;     st = 0; break;
            default: acc += st;        st = (acc >> 4) & 7; break;
        }
    }
    return acc;
}

// 5) chuoi goi ham long nhau sau (a -> b -> c -> d), goi nhieu lan
static NOINLINE unsigned lv3(unsigned x) { return (x >> 1) ^ 0x1234; }
static NOINLINE unsigned lv2(unsigned x) { return lv3(x + 1) + lv3(x ^ 5); }
static NOINLINE unsigned lv1(unsigned x) { return lv2(x) ^ lv2(x << 1); }
static NOINLINE unsigned chain(void) {
    unsigned s = 0;
    for (unsigned i = 0; i < 150; i++) s += lv1(i);
    return s;
}

int main(void) {
    for (int i = 0; i < 127; i++) tree[i] = (unsigned)i ^ 0x5A;
    RESULT[0] = fib(16);
    RESULT[1] = tsum(0);
    RESULT[2] = dispatch();
    RESULT[3] = fsm();
    RESULT[4] = chain();
    return 0;
}
