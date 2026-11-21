#!/usr/bin/env python3
"""Kiem tra vet can bo giai nen RV32C (rv32c_decompress.v) voi GNU objdump.

Voi moi ma lenh 16 bit (49.152 gia tri co 2 bit thap khac 11):
  - objdump giai ma ma lenh nen (dat o dia chi 4*i, theo sau la c.nop de giu canh 4 byte);
  - objdump giai ma lenh 32 bit ma RTL sinh ra (dat o cung dia chi 4*i, nen dich cua nhanh/nhay trung nhau).
Hai chuoi lenh (dang alias, vd. "addi a0,a0,1", "ret") phai giong het nhau. Ma lenh RTL bao illegal thi objdump
phai giai ra lenh khong thuoc RV32IM (so thuc, lenh RV64, unimp hoac khong giai ma duoc).
Can: iverilog, riscv64-unknown-elf-objdump. Chay tu thu muc goc repo: python3 rvc/check_decompress.py
"""
import os, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def objdump(binf):
    out = subprocess.run(["riscv64-unknown-elf-objdump", "-D", "-b", "binary", "-m", "riscv:rv32", binf],
                         capture_output=True, text=True, check=True).stdout
    res = {}
    for line in out.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+[0-9a-f]+\s+(.*)$", line)
        if m:
            res[int(m.group(1), 16)] = re.sub(r"\s+", " ", m.group(2).split("#")[0].strip())
    return res


def reserved_rv32(c):
    """Ma lenh danh rieng theo dac ta RV32C ma objdump van giai ma: shamt[5] = 1 cua c.slli/c.srli/c.srai
    (chi co nghia o RV64), va c.addi16sp voi nzimm = 0."""
    q, f3 = c & 3, c >> 13
    if q == 2 and f3 == 0 and c & 0x1000:                                 # c.slli shamt[5]
        return True
    if q == 1 and f3 == 4 and ((c >> 10) & 3) in (0, 1) and c & 0x1000:  # c.srli / c.srai shamt[5]
        return True
    if q == 1 and f3 == 3 and ((c >> 7) & 31) == 2 and (c & 0x107C) == 0:  # c.addi16sp nzimm = 0
        return True
    return False


# lenh khong thuoc RV32IM (decompressor phai bao illegal)
NOT_RV32IM = re.compile(r"^(f\w+|c\.f\w+|\.2byte|\.insn|unimp|c\.unimp|(ld|sd|addiw|addw|subw|c\.ld|c\.sd)\b)")


def main():
    tmp = tempfile.mkdtemp(prefix="rvc_")
    vvp = os.path.join(tmp, "d.vvp")
    subprocess.run(["iverilog", "-g2012", "-o", vvp, os.path.join(HERE, "tb_decompress_all.v"),
                    os.path.join(ROOT, "rv32c_decompress.v")], check=True)
    rtl = {}
    for line in subprocess.run(["vvp", "-n", vvp], capture_output=True, text=True, check=True).stdout.splitlines():
        p = line.split()
        if len(p) == 3:
            rtl[int(p[0], 16)] = (int(p[1], 16), p[2] == "1")

    codes = [c for c in range(65536) if c & 3 != 3]
    cbin, ebin = os.path.join(tmp, "c.bin"), os.path.join(tmp, "e.bin")
    with open(cbin, "wb") as f:
        for c in codes:
            f.write(struct.pack("<HH", c, 0x0001))
    with open(ebin, "wb") as f:
        for c in codes:
            f.write(struct.pack("<I", rtl[c][0]))
    dc, de = objdump(cbin), objdump(ebin)

    bad, diff, n_ill, n_ok, n_hint, n_alias, n_res, n_mv = [], [], 0, 0, 0, 0, 0, 0
    for i, c in enumerate(codes):
        out, ill = rtl[c]
        ref = dc.get(4 * i, "?")
        if ill:
            n_ill += 1
            if reserved_rv32(c):
                n_res += 1                     # danh rieng theo dac ta, objdump van giai ma (xem reserved_rv32)
            elif not NOT_RV32IM.match(ref):
                bad.append(f"{c:04x}: RTL bao illegal, objdump: {ref}")
        else:
            n_ok += 1
            got = de.get(4 * i, "?")
            # HINT: objdump in dang c.xxx. Hop le neu RTL sinh lenh tinh toan ghi x0, hoac c.slli64 -> slli rd,rd,0
            rd_ = (out >> 7) & 31
            rs1_, rs2_ = (out >> 15) & 31, (out >> 20) & 31
            hint = ref.startswith("c.") and (
                (rd_ == 0 and (out & 0x7F) in (0x13, 0x33, 0x37)) or
                # c.slli64 / c.srli64 / c.srai64 (shamt = 0): dich 0 bit, khong doi rd
                (re.match(r"c\.s(ll|rl|ra)i64", ref) is not None and (out & 0xFFF0007F) in (0x00000013, 0x40000013)
                 and rd_ == rs1_ and ((out >> 12) & 7) in (1, 5)))
            # c.mv: dac ta gian ra "add rd, x0, rs2"; objdump in "mv rd,rs2" (alias cua addi rd, rs2, 0)
            m = re.match(r"mv (\w+),(\w+)$", ref)
            if m and (out & 0xFE00707F) == 0x00000033 and rs1_ == 0 and got == f"add {m.group(1)},zero,{m.group(2)}":
                hint, n_mv = False, n_mv + 1
            if hint:
                n_hint += 1
            elif m and (out & 0xFE00707F) == 0x00000033 and rs1_ == 0 and got == f"add {m.group(1)},zero,{m.group(2)}":
                pass
            elif NOT_RV32IM.match(ref):
                bad.append(f"{c:04x}: objdump: '{ref}' (khong phai lenh RV32IM), RTL giai nen thanh {out:08x}")
            elif got != ref:
                diff.append((i, c, out, ref, got))
    # Chuoi khac nhau do alias (vd. "addi a0,a0,0" va "mv a0,a0"): bien dich lai chuoi cua objdump bang GNU as
    # (khong co C) va so ma lenh 32 bit voi RTL. Lenh nhanh/nhay co dich tuyet doi thi khong qua duoc buoc nay.
    if diff:
        src = os.path.join(tmp, "alias.s")
        with open(src, "w") as f:
            f.write(".option norvc\n" + "".join(d[3] + "\n" for d in diff))
        obj, raw = os.path.join(tmp, "alias.o"), os.path.join(tmp, "alias.bin")
        r = subprocess.run(["riscv64-unknown-elf-as", "-march=rv32im", src, "-o", obj], capture_output=True, text=True)
        if r.returncode:
            for d in diff:
                bad.append(f"{d[1]:04x}: objdump(nen) '{d[3]}'  !=  objdump(RTL {d[2]:08x}) '{d[4]}'")
            print(r.stderr[:2000])
        else:
            subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", obj, raw], check=True)
            words = open(raw, "rb").read()
            for k, (i, c, out, ref, got) in enumerate(diff):
                w = struct.unpack_from("<I", words, 4 * k)[0]
                if w == out:
                    n_alias += 1
                else:
                    bad.append(f"{c:04x}: '{ref}' -> {w:08x} (GNU as), RTL {out:08x} ('{got}')")
    for b in bad[:int(os.environ.get("SHOW", "30"))]:
        print(b)
    print(f"{len(codes)} ma lenh 16 bit: {n_ok} giai nen (khop chuoi {n_ok - n_hint - n_alias - n_mv}, khop sau khi bien dich lai alias {n_alias}, c.mv {n_mv}, HINT {n_hint}), {n_ill} illegal (trong do {n_res} danh rieng ma objdump van giai ma), {len(bad)} lech")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
