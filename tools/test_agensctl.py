#!/usr/bin/env python3
"""Tests agensctl against a fake socket server with canned replies. Run: tools/test_agensctl.py"""
import base64, json, os, shutil, socket, subprocess, sys, tempfile, threading, unittest
from pathlib import Path

CTL = str(Path(__file__).resolve().parent / "agensctl")
PNG = b"\x89PNG\r\n\x1a\nfake"


class Fake:
    """Unix socket server. Handles one JSON line at a time, replies from canned rules."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="ag")  # short path: sun_path is limited to 104 bytes
        self.path = os.path.join(self.dir, "s")
        self.atos, self.seen, self.event_on_connect = [], [], None
        self.srv = socket.socket(socket.AF_UNIX)
        self.srv.bind(self.path)
        self.srv.listen(5)
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(c,), daemon=True).start()

    def serve(self, c):
        if self.event_on_connect:
            c.sendall(json.dumps(self.event_on_connect).encode() + b"\n")
        for line in c.makefile("rb"):
            r = json.loads(line)
            self.seen.append(r)
            out = {"id": r["id"], **self.handle(r)}
            c.sendall(json.dumps(out).encode() + b"\n")

    def handle(self, r):
        op = r["op"]
        if op == "hello":
            return {"ok": True, "protocol": 1, "browser": "test"}
        if op == "atos.create":
            self.atos.append({"id": "a1", "name": r["name"], "color": r["color"], "tag": r["tag"], "asleep": False})
            return {"ok": True, "ato": "a1"}
        if op == "atos.list":
            return {"ok": True, "atos": self.atos}
        if op == "session":
            return {"ok": True, "items": [{**n, "value": "v"} for n in r["need"]]}
        if op == "page.screenshot":
            return {"ok": True, "png": base64.b64encode(PNG).decode()}
        if op == "control.start":
            return {"ok": False, "error": "denied", "message": "no"}
        return {"ok": False, "error": "unknown_op"}

    def close(self):
        self.srv.close()
        shutil.rmtree(self.dir, ignore_errors=True)


class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fake = Fake()

    @classmethod
    def tearDownClass(cls):
        cls.fake.close()

    def ctl(self, *args, stdin=None, socket_path=None):
        return subprocess.run([CTL, "--socket", socket_path or self.fake.path, *args], input=stdin,
                              capture_output=True, text=True, timeout=20)

    def test_atos_roundtrip(self):
        r = self.ctl("atos", "create", "Cliente A", "--cor", "blue", "--tag", "t1")
        self.assertEqual((r.returncode, json.loads(r.stdout)["ato"]), (0, "a1"))
        out = json.loads(self.ctl("atos", "list").stdout)
        self.assertEqual((out["atos"][0]["name"], out["atos"][0]["tag"]), ("Cliente A", "t1"))

    def test_error_exit_1(self):
        r = self.ctl("control", "start", "--ato", "a1", "--reason", "x")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(json.loads(r.stdout)["error"], "denied")

    def test_need_parsing_with_port(self):
        r = self.ctl("session", "--ato", "a1", "--reason", "r", "--need", "cookie:https://localhost:8765:d",
                     "--need", "header:https://x.test:Authorization")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.fake.seen[-1]["need"], [
            {"type": "cookie", "from": "https://localhost:8765", "name": "d"},
            {"type": "header", "from": "https://x.test", "name": "Authorization"}])

    def test_bad_need_is_usage_error(self):
        self.assertEqual(self.ctl("renew", "--ato", "a", "--need", "bogus").returncode, 2)

    def test_login_done(self):
        self.ctl("login", "--ato", "a", "--url", "http://h/", "--done", "cookie:http://127.0.0.1:8765:d")
        self.ctl("login", "--ato", "a", "--url", "http://h/", "--done", "url_prefix:http://127.0.0.1:8765/app/")
        a, b = self.fake.seen[-2:]
        self.assertEqual(a["done"], {"cookie": "d", "from": "http://127.0.0.1:8765"})
        self.assertEqual(b["done"], {"url_prefix": "http://127.0.0.1:8765/app/"})

    def test_raw_one_connection(self):
        n = len(self.fake.seen)
        lines = '{"id":1,"op":"hello"}\n{"id":2,"op":"atos.list"}\n{"id":3,"op":"nope"}\n'
        r = self.ctl("raw", stdin=lines)
        out = [json.loads(l) for l in r.stdout.splitlines()]
        self.assertEqual([o["id"] for o in out], [1, 2, 3])
        self.assertEqual(r.returncode, 1)  # the third reply is an error
        self.assertEqual(len(self.fake.seen) - n, 3)

    def test_listen_event(self):
        self.fake.event_on_connect = {"event": "session.lost", "ato": "a1", "from": "https://x", "name": "d"}
        p = subprocess.Popen([CTL, "--socket", self.fake.path, "listen"], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(json.loads(p.stdout.readline())["event"], "session.lost")
        finally:
            p.kill()
            p.wait()
            self.fake.event_on_connect = None

    def test_screenshot_file(self):
        out = Path(self.fake.dir) / "s.png"
        r = self.ctl("page", "screenshot", "t1", "--out", str(out))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(out.read_bytes(), PNG)
        self.assertNotIn("png", json.loads(r.stdout))

    def test_missing_socket(self):
        r = self.ctl("hello", socket_path="/tmp/agens-nope.sock")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not running", r.stderr)
        self.assertIn("/tmp/agens-nope.sock", r.stderr)


if __name__ == "__main__":
    unittest.main()
