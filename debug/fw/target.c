// Chuong trinh de gdb dieu khien: bien toan cuc, ham, vong lap.
volatile int counter = 0;
volatile int result = 0;
int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
int main(void) {
    for (int i = 0; i < 5; i++) counter += i;      // counter = 10
    result = fib(10);                                // 55
    for (;;) { if (counter == 10 && result == 55) return 1; counter = 10; }
}
