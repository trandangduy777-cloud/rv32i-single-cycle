/* Cau hinh FreeRTOS V11.1.0 cho SoC (soc/): cong GCC/RISC-V voi CLINT (mtime/mtimecmp tai 0x0200_0000), 1 tick = 2000 chu ky
   (configCPU_CLOCK_HZ / configTICK_RATE_HZ), heap_4 8 KB trong RAM 16 KB, khong timer task, khong cap phat tinh. */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#ifdef CLINT_STD
#define configMTIME_BASE_ADDRESS        ( 0x0200BFF8UL )
#define configMTIMECMP_BASE_ADDRESS     ( 0x02004000UL )
#else
#define configMTIME_BASE_ADDRESS        ( 0x02000000UL )
#define configMTIMECMP_BASE_ADDRESS     ( 0x02000008UL )
#endif
#define configCPU_CLOCK_HZ              ( 2000000UL )
#define configTICK_RATE_HZ              ( ( TickType_t ) 1000 )
#define configISR_STACK_SIZE_WORDS      ( 128 )

#define configUSE_PREEMPTION            1
#define configUSE_TIME_SLICING          0
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 1
#define configUSE_16_BIT_TICKS          0
#define configMAX_PRIORITIES            ( 5 )
#define configMINIMAL_STACK_SIZE        ( ( unsigned short ) 128 )
#define configMAX_TASK_NAME_LEN         ( 6 )
#define configTOTAL_HEAP_SIZE           ( ( size_t ) 8192 )
#define configSUPPORT_DYNAMIC_ALLOCATION 1
#define configSUPPORT_STATIC_ALLOCATION 0
#define configUSE_MUTEXES               1
#define configUSE_RECURSIVE_MUTEXES     0
#define configUSE_COUNTING_SEMAPHORES   0
#define configUSE_TASK_NOTIFICATIONS    0
#define configUSE_TIMERS                0
#define configUSE_IDLE_HOOK             0
#define configUSE_TICK_HOOK             0
#define configUSE_TRACE_FACILITY        0
#define configUSE_MALLOC_FAILED_HOOK    0
#define configCHECK_FOR_STACK_OVERFLOW  0
#define configQUEUE_REGISTRY_SIZE       0
#define configIDLE_SHOULD_YIELD         1
#define configGENERATE_RUN_TIME_STATS   0
#define configUSE_CO_ROUTINES           0

#define INCLUDE_vTaskDelay                  1
#define INCLUDE_xTaskDelayUntil             1
#define INCLUDE_uxTaskGetStackHighWaterMark 1
#define INCLUDE_vTaskDelete                 0
#define INCLUDE_vTaskSuspend                1
#define INCLUDE_xTaskGetSchedulerState      0

/* configASSERT: ket thuc SoC voi ma 0xA55E0000 | dong (xem rtos_assert_failed trong main.c) */
void rtos_assert_failed( int line );
#define configASSERT( x )   do { if( ( x ) == 0 ) rtos_assert_failed( __LINE__ ); } while( 0 )

#endif
