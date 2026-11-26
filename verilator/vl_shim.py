"""Bo chuyen lenh iverilog / vvp sang Verilator cho cosim/run_cosim.py va cosim/run_random.py (khong sua hai tep do).
Hai script goi sh(["iverilog", ..., "-o", vvp, flags, tb, files]) roi sh(["vvp", "-n", vvp, "+prog=..", ...]); shim thay bang
verilator --binary --timing roi chay tep thuc thi, tra ve cung dang ket qua (stdout cua $display) nen phan so vet khong doi.
Do thoi gian bien dich va mo phong de so voi iverilog (bang dem o STATS)."""
import os, shutil, subprocess, tempfile, time

HERE_ = os.path.dirname(os.path.abspath(__file__))

STATS = {"compile_s": 0.0, "sim_s": 0.0, "compiles": 0, "runs": 0, "engine": "verilator"}
_EXE = {}
COVDIR = None            # neu dat: bien dich voi --coverage, moi lan chay gop coverage.dat vao COVDIR/<ten file thuc thi>.dat
_NRUN = [0]


def install(modules, engine="verilator", covdir=None):
    """thay modules[i].sh bang ham chuyen doi; engine = 'iverilog' chi do thoi gian, khong doi lenh"""
    global COVDIR
    STATS["engine"] = engine
    COVDIR = covdir
    if covdir:
        os.makedirs(covdir, exist_ok=True)
    for m in modules:
        orig = m.sh

        def sh(cmd, _orig=orig, **kw):
            t = time.time()
            if cmd[0] == "iverilog" and engine == "verilator":
                r = _compile(cmd)
                STATS["compile_s"] += time.time() - t
                STATS["compiles"] += 1
                return r
            if cmd[0] == "vvp" and engine == "verilator":
                r = _run(cmd, kw)
                STATS["sim_s"] += time.time() - t
                STATS["runs"] += 1
                return r
            r = _orig(cmd, **kw)
            if cmd[0] == "iverilog":
                STATS["compile_s"] += time.time() - t
                STATS["compiles"] += 1
            elif cmd[0] == "vvp":
                STATS["sim_s"] += time.time() - t
                STATS["runs"] += 1
            return r
        m.sh = sh


def _compile(cmd):
    out = cmd[cmd.index("-o") + 1]
    rest = [c for i, c in enumerate(cmd) if i > 0 and c not in ("-g2012", "-o", out)]
    mdir = out + ".vl"
    if COVDIR:      # --binary khong tu ghi coverage.dat (Verilator 5.020): dung main rieng cua cosim/vl_main.cpp
        args = ["verilator", "--cc", "--exe", "--build", "--timing", "--coverage", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-DNO_VCD",
                "--top-module", "tb_cosim", "-O1", "-j", "2", "-Mdir", mdir, os.path.join(os.path.dirname(HERE_), "cosim", "vl_main.cpp")] + rest
    else:
        args = ["verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-DNO_VCD", "--top-module", "tb_cosim",
                "-O2", "-j", "2", "-Mdir", mdir, "-o", "Vsim"] + rest
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode == 0:
        _EXE[out] = os.path.join(mdir, "Vtb_cosim" if COVDIR else "Vsim")
        open(out, "w").write("verilator")
    return r


def _run(cmd, kw):
    sim = cmd[2] if cmd[1] == "-n" else cmd[1]
    rest = [c for c in cmd[1:] if c != "-n" and c != sim]
    if not COVDIR:
        return subprocess.run([_EXE[sim]] + rest, capture_output=True, text=True, **kw)
    wd = tempfile.mkdtemp(prefix="vlrun_")
    try:
        r = subprocess.run([_EXE[sim]] + rest, capture_output=True, text=True, cwd=wd, **kw)
        dat = os.path.join(wd, "coverage.dat")
        if os.path.exists(dat):
            tgt = os.path.join(COVDIR, os.path.basename(sim).replace(".vvp", "") + ".dat")
            if os.path.exists(tgt):
                subprocess.run(["verilator_coverage", "-write", tgt + ".new", tgt, dat], capture_output=True)
                os.replace(tgt + ".new", tgt)
            else:
                shutil.move(dat, tgt)
        return r
    finally:
        shutil.rmtree(wd, ignore_errors=True)
