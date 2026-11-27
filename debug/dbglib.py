"""Thu vien chay mo phong debug (Vdbg) + OpenOCD va gui lenh qua cong Tcl cua OpenOCD."""
import os, re, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VDBG = os.environ.get("VDBG", "/tmp/vdbg/Vdbg")


class Sim:
    def __init__(self, prog=None, rbb=9824, tcl=6666, timeout=240, quiet=True, extra_sim=("--halt-at-start",)):
        self.rbb, self.tcl = rbb, tcl
        self.log = tempfile.NamedTemporaryFile("w+", suffix=".log", delete=False)
        sim_cmd = [VDBG, "--port", str(rbb), "--timeout", str(timeout)] + ([f"+prog={prog}"] if prog else []) + list(extra_sim)
        self.sim = subprocess.Popen(sim_cmd, stdout=self.log, stderr=subprocess.STDOUT)
        time.sleep(0.4)
        env = dict(os.environ, RBB_PORT=str(rbb))
        self.oocd_log = tempfile.NamedTemporaryFile("w+", suffix=".log", delete=False)
        self.oocd = subprocess.Popen(["openocd", "-c", "gdb_port disabled", "-c", "telnet_port disabled", "-c", f"tcl_port {tcl}",
                                      "-f", os.path.join(HERE, "openocd.cfg")], stdout=self.oocd_log, stderr=subprocess.STDOUT, env=env)
        self.sock = None
        for _ in range(100):
            try:
                self.sock = socket.create_connection(("localhost", tcl), timeout=60)
                break
            except OSError:
                time.sleep(0.1)
        if self.sock is None:
            raise RuntimeError("khong ket noi duoc OpenOCD:\n" + self.oocd_text())
        self.cmd("capture \"echo ok\"")

    def oocd_text(self):
        self.oocd_log.flush()
        return open(self.oocd_log.name).read()

    def sim_text(self):
        self.log.flush()
        return open(self.log.name).read()

    def cmd(self, c):
        self.sock.sendall(c.encode() + b"\x1a")
        buf = b""
        while not buf.endswith(b"\x1a"):
            d = self.sock.recv(65536)
            if not d:
                raise RuntimeError("OpenOCD dong ket noi")
            buf += d
        return buf[:-1].decode(errors="replace").strip()

    def ok(self, c):
        """chay lenh, bao loi neu OpenOCD tra loi chua loi"""
        r = self.cmd(f"if {{[catch {{{c}}} e]}} {{ return \"ERR $e\" }} else {{ return $e }}")
        return r

    # tien ich
    def halt(self):
        return self.cmd("halt")

    def resume(self):
        return self.cmd("resume")

    def reg(self, name):
        r = self.cmd(f"reg {name}")
        m = re.search(r"0x([0-9a-fA-F]+)", r)
        if not m:
            raise RuntimeError(f"doc {name}: {r}")
        return int(m.group(1), 16)

    def wreg(self, name, v):
        r = self.cmd(f"reg {name} 0x{v:x}")
        return r

    def dmi_read(self, a):
        return int(self.cmd(f"riscv dmi_read 0x{a:x}"), 0)

    def dmi_write(self, a, v):
        return self.cmd(f"riscv dmi_write 0x{a:x} 0x{v:x}")

    def mem(self, addr, n=1, width=32):
        r = self.cmd(f"read_memory 0x{addr:x} {width} {n}")
        return [int(x, 0) for x in r.split()]

    def wmem(self, addr, vals, width=32):
        return self.cmd(f"write_memory 0x{addr:x} {width} {{{' '.join(hex(v) for v in vals)}}}")

    def close(self):
        try:
            if self.sock:
                self.sock.sendall(b"shutdown\x1a")
        except OSError:
            pass
        for p in (self.oocd, self.sim):
            try:
                p.wait(timeout=5)
            except Exception:
                p.kill()
        for f in (self.log, self.oocd_log):
            try:
                os.unlink(f.name)
            except OSError:
                pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()
