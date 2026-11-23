#include "soc.h"
static u32 fib(u32 n) { u32 a = 0, b = 1; while (n--) { u32 t = a + b; a = b; b = t; } return a; }
int main(void) {
    puts_("Hello, RV32IMC SoC!\n");
    puts_("fib(10)="); put_dec(fib(10));
    puts_(" 6*7="); put_dec(6 * 7);
    puts_(" 1000000/7="); put_dec(1000000u / 7u);
    puts_(" id="); put_hex(SYS_ID); putc_('\n');
    return 0;
}
