#!/bin/sh
# Dung moi truong kiem chung tren Ubuntu 24.04 (may moi hoac phien cloud moi), giong job CI:
#   iverilog, gcc-riscv64-unknown-elf, Spike (build tu ma nguon, ghim phien ban), riscv-tests, yowasp-yosys + z3.
# Dung: sudo sh tools/setup_env.sh   (mat khoang 15-30 phut, phan lon la build Spike)
# Ket qua: spike o /opt/spike/bin/spike, riscv-tests o /tmp/riscv-tests.
set -e
SPIKE_SHA=7d1ee24bcc3308557e1c6a45c579db9ca5e97dd9      # cung ban voi CI (.github/workflows/verify.yml)
echo "[1/4] goi apt: iverilog, trinh bien dich RISC-V, dtc, cong cu build"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iverilog gcc-riscv64-unknown-elf device-tree-compiler \
    build-essential git python3-pip >/dev/null
echo "[2/4] yowasp-yosys va z3 (chung minh hinh thuc bo nhan)"
pip install -q --break-system-packages yowasp-yosys==0.71.0.0.post1285 z3-solver==5.4.1.0
echo "[3/4] Spike $SPIKE_SHA"
if [ ! -x /opt/spike/bin/spike ]; then
    rm -rf /tmp/spike-src
    git clone -q https://github.com/riscv-software-src/riscv-isa-sim.git /tmp/spike-src
    cd /tmp/spike-src && git checkout -q $SPIKE_SHA && git submodule update -q --init --depth 1
    mkdir -p build && cd build && ../configure -q --prefix=/opt/spike >/dev/null
    make -j"$(nproc)" >/dev/null && make install >/dev/null
fi
echo "[4/4] riscv-tests"
[ -d /tmp/riscv-tests ] || git clone -q --depth 1 https://github.com/riscv-software-src/riscv-tests.git /tmp/riscv-tests
echo "xong: $(/opt/spike/bin/spike --help 2>&1 | head -1)"
