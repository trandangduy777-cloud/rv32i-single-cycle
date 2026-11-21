#!/bin/sh
# Bien dich irq_test.S thanh irq_test.hex (can riscv64-unknown-elf-gcc). irq_test.hex da co san trong repo.
set -e
cd "$(dirname "$0")"
EXP=$(python3 checksum.py)
riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -mno-relax -Ttext=0 \
    -DEXPECTED=$EXP -o irq_test.elf irq_test.S
riscv64-unknown-elf-objcopy -O binary irq_test.elf irq_test.bin
python3 -c "
import sys
b = open('irq_test.bin','rb').read(); b += bytes((-len(b)) % 4)
open('irq_test.hex','w').write(''.join('%08x\n' % int.from_bytes(b[i:i+4],'little') for i in range(0,len(b),4)))
"
rm -f irq_test.elf irq_test.bin
echo "irq_test.hex: $(wc -l < irq_test.hex) tu, checksum $EXP"
