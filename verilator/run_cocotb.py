#!/usr/bin/env python3
"""Chay cac test cocotb (verilator/cocotb_tests) bang Verilator: scoreboard + functional coverage (cocotb-coverage), co assertion SVA bind.
  test_dcache.py  rv32_dcache voi bo nho co do tre ngau nhien (nhieu cau hinh: kich thuoc, so duong, bo dem ghi)
  test_bus.py     he thong bo nho: rv32_icache + rv32_dcache + rv32_bus_arbiter + bo nho chung
Gop coverage cac lan chay thanh bao cao text + HTML o results/cocotb/. Dung: python3 verilator/run_cocotb.py [--seeds 3] [--nops 3000]"""
import argparse, glob, json, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = os.environ.get("RV_ROOT") or REPO
sys.path.insert(0, os.path.join(HERE, "cocotb_tests"))
from cocotb.runner import get_runner          # noqa: E402
import common                                 # noqa: E402

SVA = [os.path.join(HERE, "sva", f"sva_{k}.sv") for k in ("arbiter", "dcache", "icache")]
if os.environ.get("COCOTB_NO_SVA"):       # mutation: chi scoreboard cua testbench, khong co assertion SVA ho tro
    SVA = []
# (ten, tham so dcache, bien moi truong test): LINES, WORDS, WAYS, WBUF
DC_CFGS = [("16x4 truc tiep, bo dem 4", dict(LINES=16, WORDS=4, WAYS=1, WBUF=4)), ("4x2 truc tiep, bo dem 2", dict(LINES=4, WORDS=2, WAYS=1, WBUF=2)),
           ("8x2 2 duong, bo dem 4", dict(LINES=8, WORDS=2, WAYS=2, WBUF=4)), ("8x4 4 duong, bo dem 1", dict(LINES=8, WORDS=4, WAYS=4, WBUF=1))]
BUILD_ARGS = ["--public-flat-rw", "--assert", "-Wno-fatal", "-Wno-lint", "-Wno-style", "--coverage-user", "-O1"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--nops", type=int, default=3000)
    ap.add_argument("--tests", nargs="+", default=["dcache", "bus"], choices=["dcache", "bus"])
    ap.add_argument("--cfgs", type=int, default=99, help="chi chay N cau hinh dau moi test (mutation nhanh)")
    ap.add_argument("--out", default=os.path.join(REPO, "results", "cocotb"))
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="cocotb_")
    covs = {"dcache": [], "bus": []}
    runs = fails = 0
    if "dcache" in a.tests:
        for ci, (cname, par) in enumerate(DC_CFGS[:a.cfgs]):
            bd = os.path.join(tmp, f"dc{ci}")
            r = get_runner("verilator")
            r.build(sources=[os.path.join(ROOT, "rv32_dcache.v")] + SVA[1:2], hdl_toplevel="rv32_dcache", build_dir=bd, always=True,
                    parameters=dict(par, CMASK=0xFFFF0000, CBASE=0), build_args=BUILD_ARGS)
            for sd in range(a.seeds):
                covf = os.path.join(tmp, f"dc{ci}_{sd}.json")
                os.environ.update(RANDOM_SEED=str(sd + 1), COV_OUT=covf, TB_NOPS=str(a.nops), TB_WBUF=str(par["WBUF"]), TB_WORDS=str(par["WORDS"]),
                                  TB_WAYS=str(par["WAYS"]), TB_LINES=str(par["LINES"]), TB_LAT=str(3 + 2 * sd))
                xml = r.test(hdl_toplevel="rv32_dcache", test_module="test_dcache", build_dir=bd, test_dir=bd, results_xml=os.path.join(bd, f"r{sd}.xml"))
                runs += 1
                ok = os.path.exists(covf)
                if not ok:
                    fails += 1
                else:
                    covs["dcache"].append(covf)
    if "bus" in a.tests:
        for ci, (cname, par) in enumerate([("i8x4 d8x4 1 duong", dict(ILINES=8, IWORDS=4, IWAYS=1, LINES=8, WORDS=4, WAYS=1, WBUF=2)),
                                           ("i4x2 2 duong d8x2 2 duong", dict(ILINES=4, IWORDS=2, IWAYS=2, LINES=8, WORDS=2, WAYS=2, WBUF=1)),
                                           ("i8x4 4 duong d16x4 1 duong", dict(ILINES=8, IWORDS=4, IWAYS=4, LINES=16, WORDS=4, WAYS=1, WBUF=4))][:a.cfgs]):
            bd = os.path.join(tmp, f"bus{ci}")
            r = get_runner("verilator")
            r.build(sources=[os.path.join(ROOT, f) for f in ("rv32_icache.v", "rv32_dcache.v", "rv32_bus_arbiter.v")] + [os.path.join(HERE, "cocotb_tests", "mem_sys.sv")] + SVA,
                    hdl_toplevel="mem_sys", build_dir=bd, always=True, parameters=par, build_args=BUILD_ARGS)
            for sd in range(a.seeds):
                covf = os.path.join(tmp, f"bus{ci}_{sd}.json")
                os.environ.update(RANDOM_SEED=str(sd + 1), COV_OUT=covf, TB_NOPS=str(a.nops), TB_LAT=str(2 + 2 * sd))
                r.test(hdl_toplevel="mem_sys", test_module="test_bus", build_dir=bd, test_dir=bd, results_xml=os.path.join(bd, f"r{sd}.xml"))
                runs += 1
                if os.path.exists(covf):
                    covs["bus"].append(covf)
                else:
                    fails += 1
    for k in ("dcache", "bus"):
        if covs[k]:
            h, t = common.write_reports(common.merge_cov(covs[k]), f"functional coverage {k}", a.out, f"cov_{k}")
            print(f"COVERAGE {k}: {h}/{t} bin = {100.0 * h / t:.1f} %  -> {a.out}/cov_{k}.html")
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"COCOTB: {runs} lan chay, {fails} that bai")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
