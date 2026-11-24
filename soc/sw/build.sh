#!/bin/sh
# Bien dich phan mem SoC (can riscv64-unknown-elf-gcc): sinh build/<ten>.hex (moi dong 1 tu 32 bit cua ROM, .data nam sau .rodata) va build/<ten>.lst
# Dung: sh soc/sw/build.sh [ten ...]   (mac dinh: hello t_mem t_timer t_uart t_gpio t_irq_uart t_mepc t_ramexec t_plic)
set -e
cd "$(dirname "$0")"
mkdir -p build
CC=riscv64-unknown-elf-gcc
CFLAGS="-march=rv32imc_zicsr -mabi=ilp32 -Os -g0 -ffreestanding -fno-builtin -fno-pic -mno-relax -nostdlib -nostartfiles -Wall -Wextra -Werror"
LIST=${*:-hello t_mem t_timer t_uart t_gpio t_irq_uart t_mepc t_ramexec t_plic}
for t in $LIST; do
    $CC $CFLAGS -T link.ld -Wl,--no-warn-rwx-segments,-Map=build/$t.map -o build/$t.elf crt0.S trap_default.c $t.c
    riscv64-unknown-elf-objcopy -O binary build/$t.elf build/$t.bin
    riscv64-unknown-elf-objdump -d -M no-aliases build/$t.elf > build/$t.lst
    python3 - "$t" <<'PY'
import sys
t = sys.argv[1]
b = open(f'build/{t}.bin', 'rb').read(); b += bytes((-len(b)) % 4)
assert len(b) <= 16384, f'{t}: ROM image {len(b)} byte > 16 KB'
open(f'build/{t}.hex', 'w').write(''.join('%08x\n' % int.from_bytes(b[i:i+4], 'little') for i in range(0, len(b), 4)))
print(f'{t}: {len(b)} byte ROM')
PY
done
