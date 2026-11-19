#!/usr/bin/env python3
"""Tinh checksum ma vong lap chinh cua irq_test.S phai cho ra (khong co ngat)."""
M = 0xFFFFFFFF
s2, n = 0, 300
for i in range(n):
    s2 = (s2 + i * i) & M
    s2 ^= s2 % n
    s2 = ((s2 << 3) | (s2 >> 29)) & M
print(f"0x{s2:08x}")
