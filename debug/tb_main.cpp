// Mo phong Verilator cua rv32_dbg_top voi server remote_bitbang (OpenOCD: adapter driver remote_bitbang).
//   Vdbg [--port N] [--cycles-per-bit K] [--timeout S] [--exit-on-done] +prog=file.hex
// Giao thuc remote_bitbang: '0'-'7' = ghi (tck<<2 | tms<<1 | tdi), 'R' = doc TDO ('0' / '1'), 'r' 's' 't' 'u' = reset
// (bit 1 = TRST, bit 0 = SRST dang kich hoat), 'B' / 'b' = den nhay, 'Q' = thoat. Giua hai lenh, loi chay K chu ky clk moi bit;
// khi OpenOCD khong gui gi, loi van chay tu do (chuong trinh dang debug chay that).
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include "Vrv32_dbg_top.h"
#include "verilated.h"

static Vrv32_dbg_top *top;
static unsigned long long cyc = 0;
static int g_done_reported = 0;

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cyc++;
    if (!top->done) g_done_reported = 0;
    if (top->done && !g_done_reported) {
        g_done_reported = 1;
        printf("TOHOST 0x%x (chu ky %llu)\n", (unsigned)top->exit_code, cyc); fflush(stdout);
        fflush(stdout);
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int port = 9824, kbit = 8, timeout = 0, exit_on_done = 0, halt_at_start = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--cycles-per-bit") && i + 1 < argc) kbit = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--exit-on-done")) exit_on_done = 1;
        else if (!strcmp(argv[i], "--halt-at-start")) halt_at_start = 1;
    }
    top = new Vrv32_dbg_top;
    top->boot_halt = 0; top->rst_n = 0; top->tck = 0; top->tms = 1; top->tdi = 0; top->trst_n = 0; top->irq_ext = 0; top->boot_halt = 0;
    top->boot_halt = halt_at_start;
    for (int i = 0; i < 8; i++) tick();
    top->rst_n = 1; top->trst_n = 1;
    for (int i = 0; i < 4; i++) tick();

    int ls = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{}; a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons(port);
    if (bind(ls, (sockaddr *)&a, sizeof a) || listen(ls, 1)) { perror("bind/listen"); return 2; }
    printf("remote_bitbang: dang nghe cong %d\n", port); fflush(stdout);
    int cs = -1;
    time_t t0 = time(nullptr);
    fcntl(ls, F_SETFL, O_NONBLOCK);
    for (;;) {
        if (timeout && time(nullptr) - t0 > timeout) { printf("het thoi gian\n"); return 3; }
        if (exit_on_done && top->done) { for (int i = 0; i < 50; i++) tick(); return top->exit_code == 1 ? 0 : 1; }
        if (cs < 0) {
            cs = accept(ls, nullptr, nullptr);
            if (cs >= 0) { setsockopt(cs, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one); fcntl(cs, F_SETFL, O_NONBLOCK); }
            else { for (int i = 0; i < 200; i++) tick(); usleep(200); continue; }
        }
        unsigned char c;
        ssize_t n = recv(cs, &c, 1, 0);
        if (n == 0) { close(cs); cs = -1; continue; }                       // OpenOCD ngat: ve cho ket noi moi
        if (n < 0) { for (int i = 0; i < 100; i++) tick(); continue; }       // khong co lenh: chay tu do
        if (c >= '0' && c <= '7') {
            int v = c - '0';
            top->tck = (v >> 2) & 1; top->tms = (v >> 1) & 1; top->tdi = v & 1;
            top->eval();
            for (int i = 0; i < kbit; i++) tick();
        } else if (c == 'R') {
            char r = top->tdo ? '1' : '0';
            while (send(cs, &r, 1, 0) < 0) {}
        } else if (c >= 'r' && c <= 'u') {
            int v = c - 'r';
            top->trst_n = (v & 2) ? 0 : 1;
            top->eval();
            for (int i = 0; i < kbit; i++) tick();
        } else if (c == 'Q') { close(cs); break; }
    }
    return 0;
}
