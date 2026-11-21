"""Tao ban sao mo phong chuc nang (khong timing) cua thu vien cell IHP SG13G2 cho iverilog.

Mo hinh flip-flop cua IHP lay D/CLK/RESET_B qua cac day delayed_*, va cac day nay chi duoc noi trong khoi specify
($setuphold/$recrem). iverilog khong noi chung, nen flip-flop ra X. Script nay chen 'assign delayed_X = X;' vao moi
module co day delayed_*. File PDK goc khong bi sua.
Dung: python3 make_func_lib.py <sg13g2_stdcell.v> <file_ra.v>
"""
import re, sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
out, n_mod, n_asg = [], 0, 0
for chunk in re.split(r"(?=^module\s)", text, flags=re.M):
    names = sorted(set(re.findall(r"\bdelayed_(\w+)", chunk)))
    if chunk.startswith("module") and names:
        assigns = "".join("    assign delayed_%s = %s;\n" % (nm, nm) for nm in names)
        chunk = re.sub(r"(\n\s*specify\b)", "\n" + assigns + r"\1", chunk, count=1)
        n_mod += 1
        n_asg += len(names)
    out.append(chunk)
open(dst, "w", encoding="utf-8").write("".join(out))
print("%d module, %d day delayed_* da noi" % (n_mod, n_asg))
