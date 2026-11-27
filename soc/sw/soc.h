/* Thanh ghi SoC (khop soc/soc_*.v) va ham tien ich. */
#ifndef SOC_H
#define SOC_H
typedef unsigned int u32;
/* Bien dich cho SoC AXI4 (-DAXI_SOC): cache + cau ngoai vi lam tre truy cap va ngat vao ISR phai nap dong cache, nen cac nguong thoi gian rong hon. */
#ifdef AXI_SOC
#define T_WAIT_MAX   400u
#define T_LAT_MAX    1500u
#define T_SPAN_SLACK 6000u
#else
#define T_WAIT_MAX   40u
#define T_LAT_MAX    60u
#define T_SPAN_SLACK 200u
#endif
#define sync_io() __asm__ volatile ("fence" ::: "memory")   /* cho moi store truoc do toi dich (bo dem ghi cua cache du lieu) */
typedef unsigned char u8;
#define REG(a)       (*(volatile u32 *)(a))
#define REG8(a)      (*(volatile u8 *)(a))
#define REG16(a)     (*(volatile unsigned short *)(a))

#define CLINT_BASE   0x02000000u
#ifdef CLINT_STD   /* SoC cau hinh Linux (CLINT_STD = 1): bo cuc CLINT chuan 64 KB cua OpenSBI / Linux */
#define MTIME_LO     REG(CLINT_BASE + 0xBFF8)
#define MTIME_HI     REG(CLINT_BASE + 0xBFFC)
#define MTIMECMP_LO  REG(CLINT_BASE + 0x4000)
#define MTIMECMP_HI  REG(CLINT_BASE + 0x4004)
#define MSIP         REG(CLINT_BASE + 0x0)
#else
#define MTIME_LO     REG(CLINT_BASE + 0x0)
#define MTIME_HI     REG(CLINT_BASE + 0x4)
#define MTIMECMP_LO  REG(CLINT_BASE + 0x8)
#define MTIMECMP_HI  REG(CLINT_BASE + 0xC)
#define MSIP         REG(CLINT_BASE + 0x10)
#endif

#define UART_BASE    0x20000000u
#define UART_TXDATA  REG(UART_BASE + 0x00)
#define UART_RXDATA  REG(UART_BASE + 0x04)
#define UART_STATUS  REG(UART_BASE + 0x08)
#define UART_DIV     REG(UART_BASE + 0x0C)
#define UART_IE      REG(UART_BASE + 0x10)
#define ST_TXREADY   (1u << 0)
#define ST_RXVALID   (1u << 1)
#define ST_RXOVR     (1u << 2)
#define ST_RXFERR    (1u << 3)
#define ST_TXDROP    (1u << 4)

#define GPIO_BASE    0x20001000u
#define GPIO_OUT     REG(GPIO_BASE + 0x00)
#define GPIO_IN      REG(GPIO_BASE + 0x04)
#define GPIO_DIR     REG(GPIO_BASE + 0x08)
#define GPIO_IE      REG(GPIO_BASE + 0x0C)
#define GPIO_PEND    REG(GPIO_BASE + 0x10)
#define GPIO_EDGE    REG(GPIO_BASE + 0x14)
#define GPIO_SET     REG(GPIO_BASE + 0x18)
#define GPIO_CLR     REG(GPIO_BASE + 0x1C)
#define GPIO_TGL     REG(GPIO_BASE + 0x20)

#define PLIC_BASE    0x0C000000u
#define PLIC_PRIO(i) REG(PLIC_BASE + 4u * (i))
#define PLIC_PEND    REG(PLIC_BASE + 0x1000u)
#define PLIC_EN      REG(PLIC_BASE + 0x2000u)
#define PLIC_THR     REG(PLIC_BASE + 0x200000u)
#define PLIC_CLAIM   REG(PLIC_BASE + 0x200004u)      /* doc = claim, ghi = complete */
#define DMA_BASE     0x20010000u                      /* chi co tren SoC AXI4 (soc/axi/axi_soc_top.v) */
#define DMA_REG(c, r) REG(DMA_BASE + 0x20u * (c) + (r))
#define DMA_CTRL 0x00u
#define DMA_STAT 0x04u
#define DMA_SRC  0x08u
#define DMA_DST  0x0Cu
#define DMA_LEN  0x10u
#define DMA_SS   0x14u
#define DMA_DS   0x18u
#define DMA_CYC  0x1Cu
#define IRQ_DMA0     8u
#define IRQ_DMA1     9u
#define RAM_ALIAS(p) ((volatile u32 *)((u32)(p) + 0x30000000u))   /* RAM 0x1000_0000 nhin lai qua 0x4000_0000: khong qua cache du lieu */
#define IRQ_UART_RX  1u                               /* ID nguon PLIC */
#define IRQ_UART_TX  2u
#define IRQ_GPIO     3u
#define IRQ_EXT0     4u                               /* 4..7 = ext_irq[0..3] cua soc_top */

#define SYS_BASE     0x20002000u
#define SYS_ID       REG(SYS_BASE + 0x00)
#define SYS_SCRATCH  REG(SYS_BASE + 0x04)
#define SYS_SCRATCH_ADDR (SYS_BASE + 0x04u)
#define SYS_EXIT     REG(SYS_BASE + 0x08)
#define SYS_BUSERR   REG(SYS_BASE + 0x0C)

#define MIE_MSIE (1u << 3)
#define MIE_MTIE (1u << 7)
#define MIE_MEIE (1u << 11)
#define MSTATUS_MIE (1u << 3)

#define csr_read(r)     ({ u32 v_; __asm__ volatile ("csrr %0, " #r : "=r"(v_)); v_; })
#define csr_write(r, v) __asm__ volatile ("csrw " #r ", %0" :: "r"((u32)(v)))
#define csr_set(r, v)   __asm__ volatile ("csrs " #r ", %0" :: "r"((u32)(v)))
#define csr_clear(r, v) __asm__ volatile ("csrc " #r ", %0" :: "r"((u32)(v)))

/* ket thuc voi ma loi, luu mepc va mtval vao SCRATCH / (testbench in ra de dinh vi) */
static inline void die(u32 code) { SYS_SCRATCH = csr_read(mepc); SYS_EXIT = code; for (;;) ; }
static inline void putc_(char c) { while (!(UART_STATUS & ST_TXREADY)) ; UART_TXDATA = (u8)c; }
static inline void puts_(const char *s) { while (*s) putc_(*s++); }
static inline void put_hex(u32 v) { for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]); }
static inline void put_dec(u32 v) {
    char b[11]; int n = 0;
    do { b[n++] = '0' + v % 10; v /= 10; } while (v);
    while (n) putc_(b[--n]);
}
/* Cho tren ngat khong bi mat WFI: kiem dieu kien khi MIE = 0, WFI thuc day khi co ngat dang cho (du MIE = 0), roi mo MIE mot luc de nhan ngat. */
#define WAIT_IRQ(cond) do { csr_clear(mstatus, MSTATUS_MIE); \
    while (!(cond)) { __asm__ volatile ("wfi"); csr_set(mstatus, MSTATUS_MIE); __asm__ volatile ("nop; nop; nop"); csr_clear(mstatus, MSTATUS_MIE); } \
    csr_set(mstatus, MSTATUS_MIE); } while (0)
/* cho it nhat n chu ky mtime (CLINT tang moi chu ky khi PRESCALE = 1) */
static inline void wait_mtime(u32 n) { u32 t0 = MTIME_LO; while ((MTIME_LO - t0) < n) ; }
#endif
