#!/usr/bin/env python3
"""Dich debug/dbg_rom.S thanh danh sach hang so Verilog (localparam ROM_n) de dan vao rv32_dm.v.
  python3 debug/gen_rom.py          # in ra
  python3 debug/gen_rom.py --check  # thoat 1 neu rv32_dm.v khong khop ROM vua dich (dung trong CI / regress)"""
import os, re, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp()
elf, binf = os.path.join(tmp, "r.elf"), os.path.join(tmp, "r.bin")
cmd = ["riscv64-unknown-elf-gcc", "-march=rv32i_zicsr", "-mabi=ilp32", "-nostdlib", "-nostartfiles", "-Wl,-Ttext=0xFFFFF800",
       "-o", elf, os.path.join(HERE, "dbg_rom.S")]
r = subprocess.run(cmd, capture_output=True, text=True)
if r.returncode:
    sys.exit(r.stderr)
subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", elf, binf], check=True)
d = open(binf, "rb").read()
words = [int.from_bytes(d[i:i + 4], "little") for i in range(0, len(d), 4)]
text = "".join(f"    localparam [31:0] ROM_{i:02d} = 32'h{w:08x};\n" for i, w in enumerate(words))
text += f"    localparam ROM_N = {len(words)};\n"
if "--check" in sys.argv:
    cur = open(os.path.join(HERE, "rv32_dm.v")).read()
    a, b = cur.index("// ROM-BEGIN\n") + 13, cur.index("    // ROM-END")
    if cur[a:b] != text:
        sys.exit("rv32_dm.v: ROM khong khop debug/dbg_rom.S, chay: python3 debug/gen_rom.py --write")
    print(f"ROM khop ({len(words)} tu)")
elif "--write" in sys.argv:
    p = os.path.join(HERE, "rv32_dm.v")
    cur = open(p).read()
    a, b = cur.index("// ROM-BEGIN\n") + 13, cur.index("    // ROM-END")
    open(p, "w").write(cur[:a] + text + cur[b:])
    print(f"da ghi {len(words)} tu")
else:
    print(text, end="")
