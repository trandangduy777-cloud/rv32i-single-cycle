"""cocotb: rv32_dcache voi mo hinh bo nho co do tre ngau nhien, giao dich ngau nhien co rang buoc, scoreboard theo bo nho kien truc
va functional coverage (cocotb-coverage). Giao thuc phia loi giong tang MEM: giu addr / re / we / fence cho toi khi ready."""
import itertools, os, random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge
from cocotb_coverage.coverage import CoverCross, CoverPoint, coverage_db

from common import BusMemory, cycle_counter, dump_cov, init_word, merge

CACHE_END = 0x10000                     # [0, 0x10000) cacheable (CMASK = 0xFFFF0000, CBASE = 0); tren do la thiet bi, khong cache
DEV = 0x10000
WBUF = int(os.environ.get("TB_WBUF", "4"))
WORDS = int(os.environ.get("TB_WORDS", "4"))
WAYS = int(os.environ.get("TB_WAYS", "1"))
LINES = int(os.environ.get("TB_LINES", "16"))
LAT = int(os.environ.get("TB_LAT", "5"))
NOPS = int(os.environ.get("TB_NOPS", "3000"))


class Tr:
    pass


def kind_strb(s):
    return {0xF: "word", 0x3: "half_lo", 0xC: "half_hi", 0x1: "b0", 0x2: "b1", 0x4: "b2", 0x8: "b3"}.get(s, "other")


def _ign(items, valid):
    return [c for c in itertools.product(*items) if c not in valid]


OPS, REGS, OUTS = ["load", "store", "fence"], ["cached", "uncached"], ["hit", "miss", "none"]
STRBS = ["word", "half_lo", "half_hi", "b0", "b1", "b2", "b3", "other", "none"]
VALID_ORO = {("load", "cached", "hit"), ("load", "cached", "miss"), ("load", "uncached", "miss"), ("store", "cached", "hit"),
             ("store", "cached", "miss"), ("store", "uncached", "miss"), ("fence", "cached", "none"), ("fence", "uncached", "none")}
VALID_SSO = {("store", s, o) for s in STRBS[:-1] for o in ("hit", "miss")}


@CoverPoint("dc.op", xf=lambda t: t.op, bins=OPS)
@CoverPoint("dc.region", xf=lambda t: t.region, bins=REGS)
@CoverPoint("dc.outcome", xf=lambda t: t.outcome, bins=OUTS)
@CoverPoint("dc.strb", xf=lambda t: t.strb, bins=STRBS)
@CoverPoint("dc.wb_occupancy", xf=lambda t: t.occ, bins=list(range(0, WBUF + 1)))
@CoverPoint("dc.event", xf=lambda t: t.event, bins=["none", "forward", "store_stall_full", "load_after_store_same_word", "fence_with_pending"])
@CoverCross("dc.op_region_outcome", items=["dc.op", "dc.region", "dc.outcome"], ign_bins=_ign([OPS, REGS, OUTS], VALID_ORO))
@CoverCross("dc.store_strb_outcome", items=["dc.op", "dc.strb", "dc.outcome"], ign_bins=_ign([OPS, STRBS, OUTS], VALID_SSO))
def sample(t):
    pass


@cocotb.test()
async def dcache_random(dut):
    seed = int(os.environ.get("RANDOM_SEED", "1"))
    random.seed(seed)
    cyc = [0]
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    cocotb.start_soon(cycle_counter(dut, cyc))
    bus = BusMemory(dut, "m_", LAT)
    cocotb.start_soon(bus.run(cyc))
    ref = {}                                   # chi so tu -> gia tri kien truc (chi tu da bi store)
    dirty = set()

    def rv(wa):
        return ref.get(wa, init_word(wa))

    dut.rst_n.value = 0
    for sname in ("addr", "wdata", "wstrb", "re", "we", "fence", "m_ack", "m_rdata"):
        getattr(dut, sname).value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    # tap dia chi nong: nhieu tu cung tap / cung dong de co xung dot va forward
    sets_span = max(1, LINES // WAYS) * WORDS
    hot = [(random.randrange(0, 64) * sets_span + random.randrange(0, WORDS)) for _ in range(6)]
    n_ld = n_st = n_fe = 0
    last_store_word = None
    for opn in range(NOPS):
        r = random.random()
        t = Tr()
        prev_store = last_store_word
        t.strb, t.event, t.occ = "none", "none", 0
        if r < 0.05:
            op = "fence"
        elif r < 0.45:
            op = "store"
        else:
            op = "load"
        # chon dia chi (tu) co rang buoc: 55% tap nong, 25% rong trong vung cache, 12% thiet bi, 8% bam cung tu vua store
        x = random.random()
        if x < 0.55:
            wa = random.choice(hot) + random.choice([0, 0, 1, sets_span, 2 * sets_span])
        elif x < 0.80:
            wa = random.randrange(0, CACHE_END // 4)
        elif x < 0.92:
            wa = DEV // 4 + random.randrange(0, 16)
        else:
            wa = last_store_word if last_store_word is not None else random.randrange(0, 64)
        if op == "store" and random.random() < 0.15 and WBUF > 1:        # chuoi don dap: nhieu store lien tiep vao cung tu
            pass
        wa &= 0x3FFFFFFF
        t.region = "cached" if wa * 4 < CACHE_END else "uncached"
        t.op = op
        # dat tin hieu CPU (sau suon len, nhu thanh ghi EX/MEM)
        dut.addr.value = wa * 4
        dut.re.value = 1 if op == "load" else 0
        dut.we.value = 1 if op == "store" else 0
        dut.fence.value = 1 if op == "fence" else 0
        strb = random.choice([0xF, 0xF, 0x3, 0xC, 0x1, 0x2, 0x4, 0x8, 0x5, 0xA, 0x7]) if op == "store" else 0
        wdata = random.getrandbits(32)
        dut.wstrb.value = strb
        dut.wdata.value = wdata
        # cho ready: do so chu ky, ghi nhan hit / miss theo trang thai (dut.hit) luc bat dau thao tac
        await FallingEdge(dut.clk)
        await ReadOnly()          # ack cua bo nho duoc dat o chinh suon xuong nay; ready la to hop theo ack
        t.occ = int(dut.q_cnt.value)
        hit0 = int(dut.hit.value) and t.region == "cached"
        was_full = int(dut.q_full.value)
        waited = 0
        seen_fwd = seen_full_stall = False
        while True:
            ready = int(dut.ready.value)
            if int(dut.fill_fwd.value) and int(dut.state.value) == 1 and int(dut.m_ack.value):
                seen_fwd = True
            if op == "store" and int(dut.q_full.value) and not ready:
                seen_full_stall = True
            if ready:
                break
            waited += 1
            assert waited < 5000, f"khong ready sau {waited} chu ky (op={op} addr={wa * 4:#x})"
            await FallingEdge(dut.clk)
            await ReadOnly()
        # kiem tra ket qua o chu ky ready
        if op == "load":
            got = int(dut.rdata.value)
            exp = rv(wa)
            assert got == exp, f"load {wa * 4:#x}: tra {got:08x}, kien truc {exp:08x} (thao tac {opn}, seed {seed})"
            n_ld += 1
        elif op == "store":
            ref[wa] = merge(rv(wa), wdata, strb)
            dirty.add(wa)
            last_store_word = wa
            n_st += 1
            t.strb = kind_strb(strb)
        else:
            n_fe += 1
        if op == "fence":
            t.outcome = "none"
        elif t.region == "uncached":
            t.outcome = "miss"
        elif op == "store":
            t.outcome = "hit" if hit0 else "miss"
        else:
            t.outcome = "hit" if (hit0 and waited == 0) else "miss"
        if seen_fwd:
            t.event = "forward"
        elif seen_full_stall:
            t.event = "store_stall_full"
        elif op == "fence" and t.occ > 0:
            t.event = "fence_with_pending"
        elif op == "load" and wa == prev_store:
            t.event = "load_after_store_same_word"
        sample(t)
        # FENCE xong: moi store truoc do da toi bo nho
        if op == "fence":
            for w in dirty:
                assert bus.rd(w) == ref[w], f"sau FENCE bo nho tu {w * 4:#x} = {bus.rd(w):08x}, kien truc {ref[w]:08x}"
        await RisingEdge(dut.clk)
        # nghi ngau nhien 0-2 chu ky (giong pipeline bi dung)
        dut.re.value = 0; dut.we.value = 0; dut.fence.value = 0
        if random.random() < 0.3:
            for _ in range(random.randrange(1, 3)):
                await RisingEdge(dut.clk)
    # xa het bo dem ghi roi so toan bo bo nho voi mo hinh
    for _ in range(2000):
        await FallingEdge(dut.clk)
        if int(dut.wb_empty.value) and not int(dut.m_req.value):
            break
    for w in dirty:
        assert bus.rd(w) == ref[w], f"cuoi: bo nho tu {w * 4:#x} = {bus.rd(w):08x}, kien truc {ref[w]:08x}"
    dump_cov(coverage_db, os.environ["COV_OUT"])
    dut._log.info(f"dcache_random seed {seed}: {n_ld} load, {n_st} store, {n_fe} fence, bus doc {bus.reads} ghi {bus.writes}")


async def _unused():
    pass
