#!/bin/sh
# Bien dich benchmark thanh bench.hex (can riscv64-unknown-elf-gcc)
set -e
cd "$(dirname "$0")"
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -O2 -fno-builtin -fno-tree-loop-distribute-patterns \
    -nostdlib -nostartfiles -static -mcmodel=medany -T bench.ld crt0.S bench.c -o bench.elf
riscv64-unknown-elf-objcopy -O binary bench.elf bench.bin
python3 - <<'PY'
d = open('bench.bin', 'rb').read()
d += b'\0' * (-len(d) % 4)
open('bench.hex', 'w').write(''.join('%08x\n' % int.from_bytes(d[i:i+4], 'little') for i in range(0, len(d), 4)))
print(len(d), 'bytes')
PY
