#!/bin/sh
# Bien dich benchmark: bench.hex (RV32I thuan, chay duoc tren ca 3 loi) va bench_m.hex (RV32IM, nang lenh nhan/chia)
# Can riscv64-unknown-elf-gcc
set -e
cd "$(dirname "$0")"
build() {   # build <ten> <march>
    riscv64-unknown-elf-gcc -march=$2 -mabi=ilp32 -O2 -fno-builtin -fno-tree-loop-distribute-patterns \
        -nostdlib -nostartfiles -static -mcmodel=medany -T bench.ld crt0.S $1.c -o $1.elf
    riscv64-unknown-elf-objcopy -O binary $1.elf $1.bin
    python3 - $1 <<'PY'
import sys
n = sys.argv[1]
d = open(n + '.bin', 'rb').read()
d += b'\0' * (-len(d) % 4)
open(n + '.hex', 'w').write(''.join('%08x\n' % int.from_bytes(d[i:i+4], 'little') for i in range(0, len(d), 4)))
print(n, len(d), 'bytes')
PY
}
build bench rv32i
build bench_m rv32im
