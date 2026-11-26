"""Phan dung chung cua cac test cocotb: mo hinh bo nho co do tre ngau nhien, giao thuc bus, bao cao coverage (text + HTML)."""
import html, json, os, random

from cocotb.triggers import FallingEdge, RisingEdge


def init_word(wa):
    """gia tri ban dau cua tu wa (chi so tu): ham bam co dinh, de bo nho va mo hinh tham chieu cung biet gia tri chua ai ghi"""
    return (wa * 2654435761 + 0x9E3779B9) & 0xFFFFFFFF


def merge(old, new, strb):
    m = 0
    for i in range(4):
        if strb >> i & 1:
            m |= 0xFF << (8 * i)
    return (old & ~m & 0xFFFFFFFF) | (new & m)


class BusMemory:
    """Bo nho chung phia bus: yeu cau (req) giu cho toi khi ack 1 chu ky; do tre 1..lat chu ky ngau nhien.
    Lay mau o suon xuong (FallingEdge) sau khi dau vao da duoc dat o suon len: cac ngo ra khi do da on dinh voi dau vao cua chu ky nay."""

    def __init__(self, dut, prefix, lat, port_pairs=None):
        self.d, self.p, self.lat = dut, prefix, lat
        self.mem = {}                 # chi so tu -> gia tri (chi tu da bi ghi)
        self.wait = None
        self.reads = self.writes = 0
        self.trace = []               # (cycle, 'R'/'W', addr) cho kiem tra thu tu

    def rd(self, wa):
        return self.mem.get(wa, init_word(wa))

    def sig(self, n):
        return getattr(self.d, self.p + n)

    async def run(self, clk_cycles):
        d = self.d
        while True:
            await FallingEdge(d.clk)
            ack = False
            if int(self.sig("req").value) and not int(self.sig("ack").value):
                if self.wait is None:
                    self.wait = random.randint(0, self.lat - 1)
                if self.wait == 0:
                    a = int(self.sig("addr").value) >> 2
                    if hasattr(d, self.p + "we") and int(self.sig("we").value):
                        old = self.rd(a)
                        self.mem[a] = merge(old, int(self.sig("wdata").value), int(self.sig("wstrb").value))
                        self.writes += 1
                        self.trace.append((clk_cycles[0], "W", a))
                    else:
                        self.sig("rdata").value = self.rd(a)
                        self.reads += 1
                        self.trace.append((clk_cycles[0], "R", a))
                    ack = True
                    self.wait = None
                else:
                    self.wait -= 1
            self.sig("ack").value = 1 if ack else 0


async def cycle_counter(dut, box):
    while True:
        await RisingEdge(dut.clk)
        box[0] += 1


def dump_cov(db, path):
    """coverage_db (cocotb-coverage) -> JSON {item: {bin: so lan}} de gop giua cac lan chay"""
    with open(path, "w") as f:
        json.dump({item: {str(b): v for b, v in cov.detailed_coverage.items()} for item, cov in db.items() if "." in item}, f)


def merge_cov(paths):
    out = {}
    for p in paths:
        for item, det in json.load(open(p)).items():
            o = out.setdefault(item, {})
            for b, v in det.items():
                o[b] = o.get(b, 0) + v
    return out


def write_reports(db, title, outdir, name):
    """db: {item: {bin: so lan}} -> <name>.txt, <name>.html, <name>.json; tra ve (bin da toi, tong bin)"""
    os.makedirs(outdir, exist_ok=True)
    rows, lines = [], []
    tot_bins = hit_bins = 0
    for item, det in sorted(db.items()):
        n = len(det)
        h = sum(1 for v in det.values() if v > 0)
        tot_bins += n
        hit_bins += h
        rows.append((item, n, h, det))
        lines.append(f"{item:<32} {h:>4}/{n:<4} bin ({100.0 * h / n if n else 100:5.1f} %)")
        for b, v in sorted(det.items()):
            if v == 0:
                lines.append(f"      chua toi: {b}")
    lines.append(f"TONG {title}: {hit_bins}/{tot_bins} bin = {100.0 * hit_bins / tot_bins if tot_bins else 100:.1f} %")
    open(os.path.join(outdir, name + ".txt"), "w").write("\n".join(lines) + "\n")
    h = ["<html><head><meta charset='utf-8'><title>" + html.escape(title) + "</title><style>body{font-family:sans-serif}table{border-collapse:collapse}"
         "td,th{border:1px solid #999;padding:2px 6px;font-size:13px}.z{background:#f9c}.ok{background:#cf9}</style></head><body>"
         f"<h2>{html.escape(title)}</h2><p>{hit_bins}/{tot_bins} bin = {100.0 * hit_bins / tot_bins if tot_bins else 100:.1f} %</p>"
         "<table><tr><th>coverage point / cross</th><th>bin</th><th>so lan</th></tr>"]
    for item, n, hh, det in rows:
        for i, (b, v) in enumerate(sorted(det.items())):
            h.append(f"<tr class='{'ok' if v else 'z'}'>" + (f"<td rowspan='{n}'>{html.escape(item)}<br>{hh}/{n}</td>" if i == 0 else "") +
                     f"<td>{html.escape(str(b))}</td><td>{v}</td></tr>")
    h.append("</table></body></html>")
    open(os.path.join(outdir, name + ".html"), "w").write("\n".join(h))
    json.dump({"hit": hit_bins, "total": tot_bins}, open(os.path.join(outdir, name + ".json"), "w"))
    return hit_bins, tot_bins
