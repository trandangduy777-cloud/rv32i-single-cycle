#!/bin/sh
# Lay FreeRTOS-Kernel V11.1.0 (ghim theo commit) vao soc/freertos/FreeRTOS-Kernel (khong commit vao repo, xem .gitignore).
set -e
PIN=dbf70559b27d39c1fdb68dfb9a32140b6a6777a0
cd "$(dirname "$0")"
if [ ! -d FreeRTOS-Kernel/.git ]; then
  git clone -q --depth 1 --branch V11.1.0 https://github.com/FreeRTOS/FreeRTOS-Kernel.git FreeRTOS-Kernel
fi
GOT=$(git -C FreeRTOS-Kernel rev-parse HEAD)
[ "$GOT" = "$PIN" ] || { echo "FreeRTOS-Kernel o commit $GOT, mong doi $PIN" >&2; exit 1; }
echo "FreeRTOS-Kernel $GOT (V11.1.0)"
