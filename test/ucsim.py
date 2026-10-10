"""Run a relay16 firmware binary in ucsim (8051 simulator) for tests.

The UART is connected through two FIFOs; ucsim's command console (TCP) is
used to read simulated time, port pins and the XRAM that stands in for the
EEPROM in the SIM build.
"""
import errno
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "host"))
from relay16 import Relay16  # noqa: E402

LITE_SIM_HEX = os.path.join(ROOT, "firmware", "build", "relay16-lite-sim.ihx")
UCSIM = shutil.which("ucsim_51")


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FifoSerial:
    """Just enough of pyserial's interface for Relay16, over ucsim's FIFOs."""

    name = "ucsim"

    def __init__(self, rfd, wfd, timeout=3.0):
        self.rfd, self.wfd, self.timeout = rfd, wfd, timeout
        self.buf = b""

    def _fill(self, wait):
        if select.select([self.rfd], [], [], wait)[0]:
            try:
                self.buf += os.read(self.rfd, 4096)
            except BlockingIOError:
                pass

    def write(self, data):
        os.write(self.wfd, data)

    def readline(self):
        end = time.time() + self.timeout
        while b"\n" not in self.buf and time.time() < end:
            self._fill(0.02)
        if b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            return line + b"\n"
        line, self.buf = self.buf, b""
        return line

    def reset_input_buffer(self):
        self._fill(0)
        self.buf = b""

    @property
    def in_waiting(self):
        self._fill(0)
        return len(self.buf)

    def read(self, n):
        self._fill(0)
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def close(self):
        pass


class UcsimBoard:
    def __init__(self, hexfile=LITE_SIM_HEX):
        self.dir = tempfile.mkdtemp(prefix="relay16-ucsim-")
        fin, fout = os.path.join(self.dir, "in"), os.path.join(self.dir, "out")
        os.mkfifo(fin)
        os.mkfifo(fout)
        port = _free_port()
        self.proc = subprocess.Popen(
            [UCSIM, "-b", "-t", "51", "-X", "22.1184M",
             "-S", f"in={fin},out={fout}", "-Z", str(port), "-g", hexfile],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        self.rfd = os.open(fout, os.O_RDONLY | os.O_NONBLOCK)
        self.wfd = self._open_writer(fin)
        self.con = self._connect(port)
        self.marker = 0
        self.console("")
        self.serial = FifoSerial(self.rfd, self.wfd)
        self.relay = Relay16(self.serial)

    def _open_writer(self, path, timeout=5):
        end = time.time() + timeout
        while True:
            try:
                return os.open(path, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as e:
                if e.errno != errno.ENXIO or time.time() > end:
                    raise
                time.sleep(0.02)

    def _connect(self, port, timeout=5):
        end = time.time() + timeout
        while True:
            try:
                c = socket.create_connection(("127.0.0.1", port))
                c.settimeout(5)
                return c
            except OSError:
                if time.time() > end:
                    raise
                time.sleep(0.05)

    def console(self, command):
        """Run a console command, return its output. An echo marker ends
        each reply, so stray prompts can never shift replies."""
        self.marker += 1
        mark = f"@@{self.marker}@@".encode()
        self.con.sendall(command.encode() + b"\necho " + mark + b"\n")
        out = b""
        while not re.search(rb"(?<!echo )" + mark + rb"\r?\n", out):
            out += self.con.recv(65536)
        text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", out.decode(errors="replace"))
        drop = {command.strip(), "echo " + mark.decode()}
        return "\n".join(l for l in text.splitlines() if l.strip() not in drop)

    def sim_time(self):
        m = re.search(r"Total time since last reset= ([\d.]+) sec", self.console("state"))
        return float(m.group(1))

    def wait_sim(self, ms):
        """Wait until `ms` milliseconds of simulated time have passed."""
        t0 = self.sim_time()
        while self.sim_time() - t0 < ms / 1000:
            time.sleep(0.02)

    def sfr(self, addr):
        m = re.search(rf"0x{addr:02x} ([0-9a-f]{{2}})", self.console(f"ds 0x{addr:02x} 0x{addr:02x}"))
        return int(m.group(1), 16)

    def pins(self):
        """(P1, P3, P5 & 0x30)"""
        return self.sfr(0x90), self.sfr(0xB0), self.sfr(0xC8) & 0x30

    def xram(self, start, end):
        data = bytearray()
        for line in self.console(f"dx {start} {end}").splitlines():
            m = re.match(r"0x[0-9a-f]{4} ((?:[0-9a-f]{2} ?)+)", line)
            if m:
                data += bytes.fromhex(m.group(1))
        return bytes(data)

    def set_xram(self, addr, data):
        self.console(f"set memory xram {addr} " + " ".join(f"0x{b:02x}" for b in data))

    def reset(self):
        self.console("reset")
        time.sleep(0.1)
        self.serial.reset_input_buffer()

    def close(self):
        try:
            self.con.close()
        finally:
            self.proc.kill()
            self.proc.wait()
            os.close(self.rfd)
            os.close(self.wfd)
            shutil.rmtree(self.dir, ignore_errors=True)
