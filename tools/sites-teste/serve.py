#!/usr/bin/env python3
"""Local test sites for the AgensBrowser socket phases. Binds 127.0.0.1 only. Usage: serve.py [PORT]"""
import http.server, json, sys, urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAGES = {"/login": "login.html", "/app/": "app.html", "/form": "form.html", "/other": "other.html"}
SID = "sid-fake-123"  # fake test values only
SEEN = {}  # /whoami tag -> whether that request carried the login cookie (in memory only)


class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body=b"", headers=(), ctype="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, to, cookies=()):
        self.reply(303, headers=[("Location", to), *[("Set-Cookie", c) for c in cookies]])

    def logged_in(self):
        return f"sid={SID}" in self.headers.get("Cookie", "")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/app":
            return self.redirect("/app/")
        if path == "/":
            return self.redirect("/login")
        if path == "/app/" and not self.logged_in():
            return self.redirect("/login")
        if path == "/logout":
            return self.redirect("/login", ["sid=; Path=/; Max-Age=0; HttpOnly", "d=; Path=/; Max-Age=0"])
        if path in ("/whoami", "/seen"):
            tag = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("tag", [""])[0]
            if path == "/whoami":
                SEEN[tag] = self.logged_in()
                return self.reply(200, b"<p>whoami</p>")
            return self.reply(200, json.dumps({"seen": tag in SEEN, "logged_in": SEEN.get(tag, False)}).encode(),
                              ctype="application/json")
        if path == "/api/ping":
            auth = self.headers.get("Authorization", "")
            return self.reply(200, ('{"ok": true, "bearer": %s}' % str(auth == "Bearer test-bearer-123").lower()).encode(),
                              ctype="application/json")
        if self.path == "/login?auto=1":  # logs in by itself, for gates that cannot type
            return self.login()
        if path in PAGES:
            return self.reply(200, (HERE / PAGES[path]).read_bytes())
        self.reply(404, b"not found")

    def login(self):
        self.redirect("/app/", [f"sid={SID}; Path=/; Max-Age=3600; HttpOnly", "d=fake-d-cookie-456; Path=/; Max-Age=3600"])  # persistent: they survive a browser restart

    def do_POST(self):
        if self.path != "/login":
            return self.reply(404, b"not found")
        self.rfile.read(int(self.headers.get("Content-Length") or 0))  # any credentials work: they are fake
        self.login()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"test sites on http://127.0.0.1:{port}/login", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
