#!/usr/bin/env python3
"""Local test sites for the AgensBrowser socket phases. Binds 127.0.0.1 only. Usage: serve.py [PORT]"""
import base64, http.server, json, sys, urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAGES = {"/login": "login.html", "/app/": "app.html", "/form": "form.html", "/other": "other.html", "/agent": "agent.html", "/post": "post.html",
         "/ui/dialog": "ui-dialog.html", "/ui/perm": "ui-perm.html", "/ui/pick": "ui-pick.html", "/ext": "ext.html", "/pick": "pick.html"}
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
        if path == "/":  # renew and session load the origin's root: logged in, it leads to the app
            return self.redirect("/app/" if self.logged_in() else "/login")
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
        if path == "/auth" or path.startswith("/auth/"):
            return self.basic_auth(path)
        if self.path == "/login?auto=1":  # logs in by itself, for gates that cannot type
            return self.login()
        if path in PAGES:
            return self.reply(200, (HERE / PAGES[path]).read_bytes())
        self.reply(404, b"not found")

    def basic_auth(self, path):
        # One realm per path: Chromium answers a repeated realm from its auth cache without asking again.
        realm = "teste" if path == "/auth" else "teste-" + path[len("/auth/"):]
        if self.headers.get("Authorization") == "Basic " + base64.b64encode(b"test-user:fake-password").decode():
            return self.reply(200, b'<!doctype html><meta charset="utf-8"><title>Auth ok</title><h1>Auth ok</h1>')
        self.reply(401, b'<!doctype html><meta charset="utf-8"><title>Auth 401</title><h1>Auth 401</h1>',
                   [("WWW-Authenticate", 'Basic realm="%s"' % realm.replace('"', ""))])

    def login(self):
        self.redirect("/app/", [f"sid={SID}; Path=/; Max-Age=3600; HttpOnly", "d=fake-d-cookie-456; Path=/; Max-Age=3600"])  # persistent: they survive a browser restart

    def do_POST(self):
        if self.path == "/posted":  # a page reached by a form POST, for tab.reload
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            return self.reply(200, b'<!doctype html><meta charset="utf-8"><title>Posted (test)</title><h1>Posted</h1>')
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
