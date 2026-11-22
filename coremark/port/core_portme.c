/*
Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Original Author: Shay Gal-on

Port cho lo RV32 tu viet (rv32i_core / rv32i_pipeline / rv32im_pipeline), dua tren ban "barebones" cua EEMBC.
- Khong co bo dem thoi gian trong loi: start_time() / stop_time() ghi 1 / 2 vao o nho MARK_ADDR. Testbench
  (cosim/tb_cosim.v) ghi lai so chu ky luc lenh store do hoan tat, va tinh CoreMark/MHz = so vong * 10^6 / so chu ky.
  Vi chi la cac lenh store vao RAM nen Spike chay giong het (so vet tung lenh duoc).
- get_time() tra ve 0 nen CoreMark luon bao "phai chay it nhat 10 giay": dung la mot lan chay mo phong khong phai ket
  qua nop chinh thuc. Tinh dung dan duoc kiem bang CRC (xem coremark/run_coremark.py).
- ee_printf ghi tung ky tu vao vung dem trong RAM (CONSOLE_ADDR..); testbench in byte moi lan lenh store vao vung do
  hoan tat.
*/
#include "coremark.h"
#include "core_portme.h"

#ifndef MARK_ADDR
#define MARK_ADDR 0x8003F800
#endif
#ifndef CONSOLE_ADDR
#define CONSOLE_ADDR 0x80038000
#endif

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

#define EE_TICKS_PER_SEC 1000

void
start_time(void)
{
    *(volatile ee_u32 *)MARK_ADDR = 1;
}

void
stop_time(void)
{
    *(volatile ee_u32 *)MARK_ADDR = 2;
}

CORE_TICKS
get_time(void)
{
    return 0;
}

secs_ret
time_in_secs(CORE_TICKS ticks)
{
    return ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
}

ee_u32 default_num_contexts = 1;

static volatile char *con = (volatile char *)CONSOLE_ADDR;

void
uart_send_char(char c)
{
    *con++ = c;
}

void
portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    p->portable_id = 1;
}

void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

/* -nostdlib: GCC co the tu sinh loi goi memset / memcpy (khoi tao mang, sao chep struct) */
void *
memset(void *d, int c, unsigned int n)
{
    unsigned char *p = d;
    while (n--)
        *p++ = (unsigned char)c;
    return d;
}

void *
memcpy(void *d, const void *s, unsigned int n)
{
    unsigned char *p = d;
    const unsigned char *q = s;
    while (n--)
        *p++ = *q++;
    return d;
}
