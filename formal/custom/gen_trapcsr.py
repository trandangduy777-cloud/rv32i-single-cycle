# Nhan ban mot sby da sinh (csrc_any_mie_ch0) thanh cac check tu viet trapcsr_<bien the>_ch0.sby
# (doi RISCV_FORMAL_CHECKER, bo define CSRC, them define TC_<bien the>). Chay trong thu muc cores/rv32im_pipeline.
import re
base = open("checks/csrc_any_mie_ch0.sby").read()
VARIANTS = (("MEPC", 12), ("MCAUSE", 12), ("MTVAL", 12), ("MSTATUS", 14), ("MRET", 14))
# lenh khong hop le / load / store lech: tung CSR doc lai
VARIANTS += tuple(("%s_%s" % (k, c), 12) for k in ("ILL", "LD", "ST") for c in ("MCAUSE", "MTVAL", "MEPC"))
for v, depth in VARIANTS:
    s = base
    s = re.sub(r"depth \d+", "depth %d" % depth, s, count=1)
    s = re.sub(r"skip \d+", "skip %d" % (depth - 1), s, count=1)
    s = s.replace("csrc_any_mie_ch0", "trapcsr_%s_ch0" % v.lower())
    s = s.replace("rvfi_csrc_any_check", "rvfi_trapcsr_check")
    s = re.sub(r"`define RISCV_FORMAL_CSRC_(MASK|NAME).*\n", "", s)
    s = s.replace("CHECK_CYCLE 25", "CHECK_CYCLE %d" % (depth - 1))
    s = s.replace("`define RISCV_FORMAL_CHANNEL_IDX 0", "`define RISCV_FORMAL_CHANNEL_IDX 0\n" + "".join("`define TC_%s\n" % t for t in v.split("_")))
    open("checks/trapcsr_%s_ch0.sby" % v.lower(), "w").write(s)

# Monitor muc bus (wrapper.sv, RV_FORMAL_MISALIGNED): can skip 0 de assert kiem o MOI chu ky (skip mac dinh = do sau - 1 chi kiem o chu ky cuoi)
if "RV_FORMAL_MISALIGNED" in base:
    s = base.replace("csrc_any_mie_ch0", "mon_misal_ch0")
    s = re.sub(r"depth \d+", "depth 16", s, count=1)
    s = re.sub(r"skip \d+", "skip 0", s, count=1)
    open("checks/mon_misal_ch0.sby", "w").write(s)
