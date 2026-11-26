#!/bin/sh
# Bien dich phan mem SoC (can riscv64-unknown-elf-gcc): sinh build/<ten>.hex (moi dong 1 tu 32 bit cua ROM, .data nam sau .rodata) va build/<ten>.lst
# Dung: sh soc/sw/build.sh [ten ...]   (AXI=1 sh soc/sw/build.sh: bien dich cho SoC AXI4 voi -DAXI_SOC vao build_axi/)   (mac dinh: hello t_mem t_timer t_uart t_gpio t_irq_uart t_mepc t_ramexec t_plic)
set -e
cd "$(dirname "$0")"
OUT=build; EXTRA=""
if [ -n "$AXI" ]; then OUT=build_axi; EXTRA="-DAXI_SOC"; fi
mkdir -p $OUT
CC=riscv64-unknown-elf-gcc
CFLAGS="$EXTRA -mabi=ilp32 -Os -g0 -ffreestanding -fno-builtin -fno-pic -mno-relax -nostdlib -nostartfiles -Wall -Wextra -Werror"
DEF="hello t_mem t_timer t_uart t_gpio t_irq_uart t_mepc t_ramexec t_plic t_atomic"   # t_atomic chi chay tren SoC co A (run_soc.py --a)
[ -n "$AXI" ] && DEF="$DEF t_dma"     # t_dma chi chay tren SoC AXI4
LIST=${*:-$DEF}
for t in $LIST; do
    M=rv32imc_zicsr; [ "$t" = t_atomic ] && M=rv32imac_zicsr     # chi t_atomic dung lenh A
    $CC $CFLAGS -march=$M -T link.ld -Wl,--no-warn-rwx-segments,-Map=$OUT/$t.map -o $OUT/$t.elf crt0.S trap_default.c $t.c
    riscv64-unknown-elf-objcopy -O binary $OUT/$t.elf $OUT/$t.bin
    riscv64-unknown-elf-objdump -d -M no-aliases $OUT/$t.elf > $OUT/$t.lst
    python3 - "$t" "$OUT" <<'PY'
import sys
t, OUT = sys.argv[1], sys.argv[2]
b = open(f'{OUT}/{t}.bin', 'rb').read(); b += bytes((-len(b)) % 4)
assert len(b) <= 16384, f'{t}: ROM image {len(b)} byte > 16 KB'
open(f'{OUT}/{t}.hex', 'w').write(''.join('%08x\n' % int.from_bytes(b[i:i+4], 'little') for i in range(0, len(b), 4)))
print(f'{t}: {len(b)} byte ROM')
PY
done
