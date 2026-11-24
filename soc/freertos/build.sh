#!/bin/sh
# Bien dich FreeRTOS + ung dung (can riscv64-unknown-elf-gcc va mang de lay nhan o lan dau): sinh soc/freertos/build/rtos_demo.{elf,hex,lst,map}
# hex: moi dong 1 tu 32 bit cua ROM. ROM cua SoC la 16 KB (soc/sw/link.ld) - dung chung crt0.S, trap_default.c, link.ld voi cac test khac.
set -e
cd "$(dirname "$0")"
sh fetch.sh
K=FreeRTOS-Kernel
P=$K/portable/GCC/RISC-V
mkdir -p build
CC=riscv64-unknown-elf-gcc
COMMON="-march=rv32imc_zicsr -mabi=ilp32 -Os -g0 -ffreestanding -fno-builtin -fno-pic -mno-relax -ffunction-sections -fdata-sections"
INC="-I. -Istubs -I$K/include -I$P -I$P/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions -I../sw"
SRCS="$K/tasks.c $K/queue.c $K/list.c $P/port.c $K/portable/MemMang/heap_4.c rtos_libc.c main.c ../sw/trap_default.c"
$CC $COMMON $INC -Wall -Wextra -Werror -Wno-unused-parameter -nostdlib -nostartfiles -T ../sw/link.ld \
    -Wl,--no-warn-rwx-segments,--gc-sections,-Map=build/rtos_demo.map -o build/rtos_demo.elf ../sw/crt0.S $P/portASM.S $SRCS -lgcc
riscv64-unknown-elf-objcopy -O binary build/rtos_demo.elf build/rtos_demo.bin
riscv64-unknown-elf-objdump -d -M no-aliases build/rtos_demo.elf > build/rtos_demo.lst
riscv64-unknown-elf-size build/rtos_demo.elf
python3 - <<'PY'
b = open('build/rtos_demo.bin', 'rb').read(); b += bytes((-len(b)) % 4)
assert len(b) <= 16384, f'rtos_demo: ROM image {len(b)} byte > 16 KB'
open('build/rtos_demo.hex', 'w').write(''.join('%08x\n' % int.from_bytes(b[i:i+4], 'little') for i in range(0, len(b), 4)))
print(f'rtos_demo: {len(b)} byte ROM')
PY
