"""cocotb: he thong bo nho (icache + dcache + arbiter + bo nho do tre ngau nhien). Hai luong giao dich chay DONG THOI:
  - phia lenh: fetch ngau nhien (giu addr cho toi khi ready), so voi bo nho kien truc
  - phia du lieu: load/store/fence ngau nhien, co luc store vao vung ma phia lenh doc, sau do FENCE + FENCE.I (flush) roi fetch phai thay du lieu moi
Scoreboard theo mo hinh kien truc; functional coverage: ai thang bus, tuong tranh, do tre, FENCE.I coherence. Assertion SVA (arbiter, cache) bind san."""
import itertools, os, random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge
from cocotb_coverage.coverage import CoverCross, CoverPoint, coverage_db

from common import BusMemory, cycle_counter, dump_cov, init_word, merge

NOPS = int(os.environ.get("TB_NOPS", "2000"))
LAT = int(os.environ.get("TB_LAT", "4"))
IREG = 0x4000                       # vung A (byte 0x4000..0x7FFF): chi doc, phia lenh fetch ngau nhien, khong ai ghi vao
IWORDS_SPAN = 0x1000
BREG = 0x2000                       # vung B (chi so tu): chi tu phia du lieu ghi; phia lenh chi doc B ngay sau FENCE + flush (FENCE.I)
BSPAN = 16
A_LO, A_HI = IREG // 4, IREG // 4 + IWORDS_SPAN


DKINDS = ["load_hit", "load_miss", "store", "fence", "uncached", "idle"]
WHO = ["i_only", "d_only", "both"]
IGN = [(w, k) for w, k in itertools.product(WHO, DKINDS) if (w == "i_only") != (k == "idle") or (w == "both" and k == "idle")]


class Ev:
    pass


@CoverPoint("bus.who", xf=lambda e: e.who, bins=["i_only", "d_only", "both"])
@CoverPoint("bus.i_wait", xf=lambda e: 0 if e.iw == 0 else (1 if e.iw < 8 else (2 if e.iw < 32 else 3)), bins=[0, 1, 2, 3])   # 0 / 1-7 / 8-31 / 32+ chu ky
@CoverPoint("bus.d_kind", xf=lambda e: e.dk, bins=DKINDS)
@CoverPoint("bus.fencei", xf=lambda e: e.fi, bins=["none", "flush_then_fetch_new"])
@CoverCross("bus.who_dkind", items=["bus.who", "bus.d_kind"], ign_bins=IGN)
def sample(e):
    pass


@cocotb.test()
async def bus_random(dut):
    seed = int(os.environ.get("RANDOM_SEED", "1"))
    random.seed(seed)
    cyc = [0]
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    cocotb.start_soon(cycle_counter(dut, cyc))
    bus = BusMemory(dut, "m_", LAT)
    cocotb.start_soon(bus.run(cyc))
    ref = {}

    def rv(wa):
        return ref.get(wa, init_word(wa))

    for n in ("ia", "iflush", "da", "dre", "dwe", "dfence", "dwstrb", "dwdata", "m_ack", "m_rdata"):
        getattr(dut, n).value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    state = dict(i_waiting=0, d_busy=0, i_done=0, d_done=0, flush_pending=None, pulsed=False, cur_b=None)
    stats = dict(i_ops=0, d_ops=0, fencei=0)
    st = dict(iw=0, dkind=None, iact=False)
    stop = False

    hist = {}                                  # tu vung B -> moi gia tri tung co (fetch khong flush co the thay gia tri cu hop le)

    async def flusher():
        """FENCE.I: sau khi phia du lieu FENCE xong, xung flush den bat dong bo voi i-side (co the giua luc dang nap dong)"""
        while True:
            await RisingEdge(dut.clk)
            if state["flush_pending"] is not None and not state["pulsed"]:
                for _ in range(random.choice([0, 0, 0, 1])):
                    await RisingEdge(dut.clk)
                dut.iflush.value = 1
                await RisingEdge(dut.clk)
                dut.iflush.value = 0
                state["pulsed"] = True

    async def i_side():
        n = 0
        while n < NOPS and not stop:
            strict = False
            if state["flush_pending"] is not None and state["pulsed"]:
                wa = state["flush_pending"]
                fi = strict = True
            else:
                r = random.random()
                if r < 0.5:
                    wa = BREG + random.randrange(0, BSPAN)              # vung B khong flush: co the cu (cache) hoac moi
                elif r < 0.8:
                    wa = A_LO + random.randrange(0, IWORDS_SPAN)
                else:
                    wa = A_LO + random.choice([0, 1, 4, 5, 8, 9])
                fi = False
            dut.ia.value = wa * 4
            state["cur_b"] = wa if (BREG <= wa < BREG + BSPAN and not strict) else None
            iw = 0
            st["iact"] = True
            while True:
                await FallingEdge(dut.clk)
                await ReadOnly()
                if int(dut.iready.value):
                    break
                iw += 1
                assert iw < 5000, f"i-side khong ready sau {iw} chu ky"
            st["iact"] = False
            state["cur_b"] = None
            got = int(dut.idata.value)
            exp = rv(wa)
            if strict or not (BREG <= wa < BREG + BSPAN):
                assert got == exp, f"fetch {wa * 4:#x}: {got:08x}, kien truc {exp:08x} (seed {seed}, thao tac {n}{', sau FENCE.I' if strict else ''})"
            else:
                assert got in hist.get(wa, {init_word(wa)}), f"fetch {wa * 4:#x}: {got:08x} khong tung la gia tri cua tu nay"
            e = Ev()
            e.iw = iw
            e.fi = "flush_then_fetch_new" if fi else "none"
            both = st["dkind"] is not None
            e.who = "both" if both else "i_only"
            e.dk = st["dkind"] or "idle"
            if fi:
                stats["fencei"] += 1
            stats["i_ops"] += 1
            sample(e)
            if fi:
                state["flush_pending"] = None          # xong FENCE.I: tha phia du lieu chay tiep
                state["pulsed"] = False
            n += 1
            await RisingEdge(dut.clk)
            for _ in range(random.choice([0, 0, 1, 2])):
                await RisingEdge(dut.clk)
        state["i_done"] = 1

    async def d_side():
        n = 0
        dirty = set()
        while n < NOPS:
            r = random.random()
            op = "fence" if r < 0.06 else ("store" if r < 0.46 else "load")
            x = random.random()
            if x < 0.3:
                wa = BREG + random.randrange(0, BSPAN)
            elif x < 0.5 and op != "store":
                wa = A_LO + random.choice([0, 1, 4, 5, 8, 9, random.randrange(0, IWORDS_SPAN)])    # doc vung A qua dcache: tranh bus voi phia lenh
            elif x < 0.58:
                wa = 0x10000 // 4 + random.randrange(0, 8)               # thiet bi (khong cache)
            else:
                wa = random.randrange(0, 0x10000 // 4)
                if A_LO <= wa < A_HI:
                    wa += IWORDS_SPAN
            strb = random.choice([0xF, 0xF, 0x3, 0xC, 0x1, 0x2, 0x4, 0x8]) if op == "store" else 0
            wdata = random.getrandbits(32)
            dut.da.value = wa * 4
            dut.dre.value = int(op == "load")
            dut.dwe.value = int(op == "store")
            dut.dfence.value = int(op == "fence")
            dut.dwstrb.value = strb
            dut.dwdata.value = wdata
            st["dkind"] = "uncached" if (wa * 4 >= 0x10000 and op != "fence") else {"load": "load_miss", "store": "store", "fence": "fence"}[op]
            w = 0
            while True:
                await FallingEdge(dut.clk)
                await ReadOnly()
                if int(dut.dready.value):
                    break
                w += 1
                assert w < 5000, f"d-side khong ready sau {w} chu ky ({op} {wa * 4:#x})"
            if op == "load":
                got, exp = int(dut.drdata.value), rv(wa)
                assert got == exp, f"load {wa * 4:#x}: {got:08x}, kien truc {exp:08x} (seed {seed}, thao tac {n})"
                if w == 0 and st["dkind"] == "load_miss":
                    st["dkind"] = "load_hit"
            elif op == "store":
                ref[wa] = merge(rv(wa), wdata, strb)
                hist.setdefault(wa, {init_word(wa)}).add(ref[wa])
                dirty.add(wa)
            e = Ev()
            e.iw, e.fi, e.who, e.dk = 0, "none", ("both" if st["iact"] else "d_only"), st["dkind"]
            sample(e)
            stats["d_ops"] += 1
            st["dkind"] = None
            n += 1
            await RisingEdge(dut.clk)
            dut.dre.value = 0
            dut.dwe.value = 0
            dut.dfence.value = 0
            # FENCE.I: sau FENCE (store da toi bo nho) bao phia lenh flush roi doc lai tu vua store
            if op == "fence" and dirty and random.random() < 0.8:
                bw = [w2 for w2 in dirty if BREG <= w2 < BREG + BSPAN]
                if bw:
                    cb = state["cur_b"]
                    near = [w2 for w2 in bw if cb is not None and (w2 >> 1) == (cb >> 1)]       # cung khoi voi tu phia lenh dang nap: dong cache dang nap co the chua gia tri cu
                    state["flush_pending"] = random.choice(near) if near and random.random() < 0.85 else random.choice(bw)
                    while state["flush_pending"] is not None:           # cho phia lenh flush + fetch xong
                        await RisingEdge(dut.clk)
            for _ in range(random.choice([0, 0, 1, 3])):
                await RisingEdge(dut.clk)
        # ket thuc: FENCE de bo dem ghi rong, doi i-side xong
        state["d_done"] = 1

    cocotb.start_soon(flusher())
    ti = cocotb.start_soon(i_side())
    td = cocotb.start_soon(d_side())
    await td
    stop = True
    await ti
    # xa bo dem ghi roi so bo nho voi mo hinh
    dut.dfence.value = 1
    for _ in range(3000):
        await FallingEdge(dut.clk)
        await ReadOnly()
        if int(dut.dready.value):
            break
    await RisingEdge(dut.clk)
    dut.dfence.value = 0
    for _ in range(50):
        await RisingEdge(dut.clk)
    for w, v in ref.items():
        assert bus.rd(w) == v, f"cuoi: bo nho tu {w * 4:#x} = {bus.rd(w):08x}, kien truc {v:08x}"
    dump_cov(coverage_db, os.environ["COV_OUT"])
    dut._log.info(f"bus_random seed {seed}: {stats['i_ops']} fetch ({stats['fencei']} sau FENCE.I), {stats['d_ops']} thao tac du lieu, bus doc {bus.reads} ghi {bus.writes}")
