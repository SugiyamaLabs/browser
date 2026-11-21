#!/usr/bin/env python3
"""Measures the hidden engine (--agens-embedded, no window, no focus) with the fixed tab set.

Usage:
  tools/measure_hidden.py [--app PATH] [--settle 120] [--sample 30] [--atos 1] [--show] [-- ENGINE_ARGS...]

Throwaway profile; this script is the engine's parent, so it is the host (host.attach). Opens the
tabs of tools/tabs.txt with view.open, round-robin over --atos atos, then prints one sample line every
--sample seconds until --settle: total footprint, process count, renderers, by process kind.
Engine args after "--" (e.g. --enable-features=..., --mute-audio is always on). Not for docs/medicoes.md
rows: those come from tools/measure.py on the official build.
"""
import argparse, json, os, select, shutil, socket, subprocess, sys, tempfile, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from measure import descendants, footprint, tabs, ROOT  # noqa: E402

DEFAULT_APP = Path.home() / "browser-work-4/ungoogled-chromium-macos/build/src/out/Dev/AgensBrowser.app/Contents/MacOS/AgensBrowser"


class Conn:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.buf, self.n, self.events = b"", 0, []

    def ask(self, op, timeout=60, **params):
        self.n += 1
        self.s.sendall((json.dumps({"id": self.n, "op": op, **params}) + "\n").encode())
        end = time.time() + timeout
        while time.time() < end:
            if select.select([self.s], [], [], 0.5)[0]:
                data = self.s.recv(1 << 20)
                if not data:
                    break
                self.buf += data
                while b"\n" in self.buf:
                    line, self.buf = self.buf.split(b"\n", 1)
                    msg = json.loads(line)
                    if "event" in msg:
                        self.events.append(msg)
                    elif msg.get("id") == self.n:
                        return msg
        return {"ok": False, "error": "timeout"}

    def drain(self):
        while select.select([self.s], [], [], 0)[0]:
            if not self.s.recv(1 << 20):
                return


def sample(pid, t0):
    pids = descendants(pid)
    total, nproc, by_kind = footprint(pids)
    renderers = sum(1 for p in pids if "--type=renderer" in subprocess.run(["ps", "-o", "command=", "-p", str(p)], capture_output=True, text=True).stdout)
    print(f"t={time.time() - t0:5.0f}s total={total / 2**20:7.0f} MB processes={nproc:2d} renderers={renderers:2d} "
          + json.dumps({k: round(v) for k, v in sorted(by_kind.items(), key=lambda x: -x[1])}), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", default=str(DEFAULT_APP))
    ap.add_argument("--tabs", default=ROOT / "tabs.txt")
    ap.add_argument("--settle", type=int, default=120)
    ap.add_argument("--sample", type=int, default=30)
    ap.add_argument("--atos", type=int, default=1)
    ap.add_argument("--show", action="store_true", help="the host shows the first tab (view.attach), as the app does")
    ap.add_argument("engine_args", nargs="*")
    a = ap.parse_args()

    profile = tempfile.mkdtemp(prefix="agens-m.", dir="/tmp")  # short: a socket path is limited to 104 bytes
    sock = profile + "/agens.sock"
    proc = subprocess.Popen([a.app, f"--user-data-dir={profile}", "--agens-embedded", "--use-mock-keychain", "--no-first-run",
                             "--mute-audio", *a.engine_args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            if os.path.exists(sock):
                break
            time.sleep(0.5)
        c = Conn(sock)
        assert c.ask("hello", client="measure-hidden").get("ok")
        assert c.ask("host.attach").get("ok")
        atos = [x["id"] for x in c.ask("atos.list")["atos"]]
        while len(atos) < a.atos:
            atos.append(c.ask("atos.create", name=f"Medida {len(atos) + 1}")["ato"])
        t0 = time.time()
        opened = []
        for i, url in enumerate(tabs(a.tabs)):
            r = c.ask("view.open", ato=atos[i % a.atos], url=url)
            opened.append(r.get("tab"))
            if not r.get("ok"):
                print(f"view.open {url}: {r}", file=sys.stderr)
        if a.show:
            c.ask("view.attach", tab=opened[0], width=1280, height=800, scale=2)
        while time.time() - t0 < a.settle:
            time.sleep(min(a.sample, max(a.settle - (time.time() - t0), 0)))
            c.drain()
            sample(proc.pid, t0)
            if a.atos > 1:
                print("  atos: " + json.dumps({x["id"]: "sleeping" if x.get("sleeping") else "awake" for x in c.ask("atos.list")["atos"]}), flush=True)
    finally:
        proc.terminate()
        try:
            proc.wait(30)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    main()
