/* Ung dung kiem FreeRTOS tren SoC: 4 task (UART uu tien 4, tieu thu 3, san xuat 2, giam sat 1), hang doi, semaphore nhi phan danh thuc boi ngat UART RX qua PLIC,
   mutex bao ve UART, tick tu CLINT; pha do tre ngat khi chi Idle chay. Testbench (kich ban 5) gui ky tu UART sau khi thay "Q2" va "Q4" (xem tb_soc.v); chuoi UART in ra duoc so tung bit voi rtos_demo.exp.
   Cuoi cung do chu ky chuyen ngu canh (taskYIELD giua 2 task cung uu tien, doc mtime) - cac dong CAL/SW1/SW2 co so do; trong rtos_demo.exp ky tu '#' khop mot so thap phan bat ky. */
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "soc.h"

#define NITEMS 5
#define NBENCH 16

static QueueHandle_t q;
static SemaphoreHandle_t rx_sem, print_mx, done_c, done_u, done_u2;
static TaskHandle_t h_uart, h_cons, h_prod, h_mon, h_help;
static volatile u8 ring[16];
static volatile u32 rhead, rtail, isr_n, bad;
static volatile u32 t1[NBENCH], t2[NBENCH], t3[NBENCH], t4[NBENCH];

void rtos_assert_failed( int line ) { portDISABLE_INTERRUPTS(); die( 0xA55E0000u | ( u32 ) line ); }

/* ham danh dau cho testbench: dia chi cua no duoc dung de do tre ngat -> task (xem tb_soc.v, +wake=) */
__attribute__( ( noinline, aligned( 4 ) ) ) void mark_wake( void ) { __asm__ volatile ( "nop" ); }

/* SoC AXI4 (-DAXI_SOC): cache lenh / du lieu nho va cau ngoai vi lam moi lenh cham hon, task nhan ky tu va in cham them vai tick */
#ifdef AXI_SOC
#define TICK_MAXDT 20
#else
#define TICK_MAXDT 16
#endif
static void say( const char *s ) { xSemaphoreTake( print_mx, portMAX_DELAY ); puts_( s ); xSemaphoreGive( print_mx ); }
static void say_num( const char *a, u32 v, const char *b ) {
    xSemaphoreTake( print_mx, portMAX_DELAY ); puts_( a ); put_dec( v ); puts_( b ); xSemaphoreGive( print_mx );
}

/* ngat ngoai (PLIC): ham nay duoc portASM.S goi tu trap handler cua port, tren ngan xep ISR */
void freertos_risc_v_application_interrupt_handler( u32 cause ) {
    BaseType_t woken = pdFALSE;
    u32 id;
    if( cause != 0x8000000Bu ) die( 0xBAD10000u | ( cause & 0xFFFF ) );
    while( ( id = PLIC_CLAIM ) != 0 ) {
        if( id == IRQ_UART_RX ) {
            while( UART_STATUS & ST_RXVALID ) ring[rhead++ & 15] = ( u8 ) UART_RXDATA;
            isr_n++;
            xSemaphoreGiveFromISR( rx_sem, &woken );
        } else die( 0xBAD20000u | id );
        PLIC_CLAIM = id;
    }
    portYIELD_FROM_ISR( woken );
}

static void task_uart( void *p ) {
    u32 n = 0;
    ( void ) p;
    say( "S4\n" );
    for( ;; ) {
        xSemaphoreTake( rx_sem, portMAX_DELAY );
        mark_wake();
        while( rtail != rhead ) {
            char c = ( char ) ring[rtail++ & 15];
            char s[4] = { 'U', c, '\n', 0 };
            say( s );
            if( ++n == 3 ) xSemaphoreGive( done_u );
            if( n == 7 ) xSemaphoreGive( done_u2 );
        }
    }
}

static void task_cons( void *p ) {
    u32 v, i;
    ( void ) p;
    say( "S3\n" );
    for( i = 1; i <= NITEMS; i++ ) {
        xQueueReceive( q, &v, portMAX_DELAY );
        if( v != i ) bad++;
        say_num( "Q", v, "\n" );
    }
    xSemaphoreGive( done_c );
    vTaskDelay( portMAX_DELAY );
}

static void task_prod( void *p ) {
    u32 i;
    TickType_t last = xTaskGetTickCount();
    ( void ) p;
    say( "S2\n" );
    for( i = 1; i <= NITEMS; i++ ) {
        xTaskDelayUntil( &last, 3 );
        xQueueSend( q, &i, 0 );
    }
    vTaskDelay( portMAX_DELAY );
}

/* task phu cho phep do chuyen ngu canh: cung uu tien voi giam sat, hai ben nhuong nhau bang taskYIELD (ecall) */
static void task_help( void *p ) {
    u32 i;
    ( void ) p;
    for( i = 0; i < NBENCH; i++ ) { t2[i] = MTIME_LO; t3[i] = MTIME_LO; taskYIELD(); }
    vTaskDelay( portMAX_DELAY );
}

static u32 median( volatile u32 *d ) {                       /* d[0..NBENCH-1] -> trung vi (sap xep chen trong ban sao) */
    u32 a[NBENCH], i, j;
    for( i = 0; i < NBENCH; i++ ) { u32 x = d[i]; for( j = i; j > 0 && a[j - 1] > x; j-- ) a[j] = a[j - 1]; a[j] = x; }
    return a[NBENCH / 2];
}
static u32 minimum( volatile u32 *d ) { u32 m = d[0], i; for( i = 1; i < NBENCH; i++ ) if( d[i] < m ) m = d[i]; return m; }

static void task_mon( void *p ) {
    u32 tick0, time0, tick1, time1, i, ok = 1, d[NBENCH], e[NBENCH], cal;
    ( void ) p;
    say( "S1\n" );
    tick0 = xTaskGetTickCount(); time0 = MTIME_LO;
    xSemaphoreTake( done_c, portMAX_DELAY );
    xSemaphoreTake( done_u, portMAX_DELAY );
    tick1 = xTaskGetTickCount(); time1 = MTIME_LO;
    say( "DONE\n" );
    /* tick: producer gui o tick 3, 6, ..., 15 (xTaskDelayUntil), nen tu luc giam sat doc tick (~tick 0) den khi xong la 14..16 tick; do dai tick (mtime / so tick) phai la 2000 chu ky, sai so toi da 1 tick */
    { u32 dt = tick1 - tick0, dm = time1 - time0;
      if ( dt >= 14 && dt <= TICK_MAXDT ) say( "TICKS OK\n" ); else say_num( "TICKS BAD ", dt, "\n" );
      say( ( dm + 2000 >= 2000 * dt && dm <= 2000 * dt + 2000 ) ? "TICKLEN OK\n" : "TICKLEN BAD\n" ); }
    say( ( bad == 0 ) ? "QUEUE OK\n" : "QUEUE BAD\n" );
    say( ( isr_n >= 2 && isr_n <= 3 && rhead == 3 ) ? "IRQ OK\n" : "IRQ BAD\n" );
    /* ngan xep: moi task con it nhat 24 tu (96 byte) du tru; in so tu con lai nho nhat (task uart, cons, prod, mon) */
    { u32 w[4];
      w[0] = uxTaskGetStackHighWaterMark( h_uart ); w[1] = uxTaskGetStackHighWaterMark( h_cons );
      w[2] = uxTaskGetStackHighWaterMark( h_prod ); w[3] = uxTaskGetStackHighWaterMark( h_mon );
      ok = w[0] > 24 && w[1] > 24 && w[2] > 24 && w[3] > 24;
      xSemaphoreTake( print_mx, portMAX_DELAY );
      puts_( "HWM " ); put_dec( w[0] ); putc_( ' ' ); put_dec( w[1] ); putc_( ' ' ); put_dec( w[2] ); putc_( ' ' ); put_dec( w[3] ); puts_( "\n" );
      xSemaphoreGive( print_mx ); }
    say( ok ? "STACK OK\n" : "STACK BAD\n" );
    /* pha do tre ngat: moi task deu dang ngu (chi Idle chay); testbench gui 4 ky tu cach nhau 3333 chu ky sau dong "LAT" va do tre o muc RTL */
    say( "LAT\n" );
    xSemaphoreTake( done_u2, portMAX_DELAY );
    /* do chuyen ngu canh */
    xTaskCreate( task_help, "help", configMINIMAL_STACK_SIZE, NULL, 1, &h_help );
    for( i = 0; i < NBENCH; i++ ) { t1[i] = MTIME_LO; taskYIELD(); t4[i] = MTIME_LO; }
    { u32 a, b; a = MTIME_LO; b = MTIME_LO; cal = b - a; }
    for( i = 0; i < NBENCH; i++ ) { d[i] = t2[i] - t1[i]; e[i] = t4[i] - t3[i]; }
    xSemaphoreTake( print_mx, portMAX_DELAY );
    puts_( "CAL " ); put_dec( cal ); puts_( "\n" );
    puts_( "SW1 " ); put_dec( minimum( d ) ); putc_( ' ' ); put_dec( median( d ) ); puts_( "\n" );
    puts_( "SW2 " ); put_dec( minimum( e ) ); putc_( ' ' ); put_dec( median( e ) ); puts_( "\n" );
    puts_( "ALLOK\n" );
    xSemaphoreGive( print_mx );
    SYS_EXIT = ( bad == 0 && ok ) ? 0 : 1;
    for( ;; ) ;
}

extern void freertos_risc_v_trap_handler( void );          /* portASM.S; nhan khong tu dat mtvec, ma khoi dong phai dat */

int main( void ) {
    csr_write( mtvec, ( u32 ) freertos_risc_v_trap_handler );
    q = xQueueCreate( 4, sizeof( u32 ) );
    rx_sem = xSemaphoreCreateBinary(); done_c = xSemaphoreCreateBinary(); done_u = xSemaphoreCreateBinary(); done_u2 = xSemaphoreCreateBinary();
    print_mx = xSemaphoreCreateMutex();
    configASSERT( q && rx_sem && done_c && done_u && done_u2 && print_mx );
    xTaskCreate( task_mon, "mon", 2 * configMINIMAL_STACK_SIZE, NULL, 1, &h_mon );
    xTaskCreate( task_prod, "prod", configMINIMAL_STACK_SIZE, NULL, 2, &h_prod );
    xTaskCreate( task_cons, "cons", configMINIMAL_STACK_SIZE, NULL, 3, &h_cons );
    xTaskCreate( task_uart, "uart", configMINIMAL_STACK_SIZE, NULL, 4, &h_uart );
    PLIC_PRIO( IRQ_UART_RX ) = 2; PLIC_EN = 1u << IRQ_UART_RX; PLIC_THR = 0;
    UART_IE = 1;
    puts_( "BOOT\n" );
    vTaskStartScheduler();
    die( 0xA55E0001u );                       /* khong du heap de tao Idle */
    return 1;
}
