// Chay mai: kiem halt / resume / step trong luc chuong trinh dang chay.
volatile unsigned heartbeat = 0;
volatile int marker = 0;
void tick(void) { heartbeat++; }
int main(void) {
    for (;;) { tick(); if (heartbeat == 0x7fffffff) marker = 1; }
}
