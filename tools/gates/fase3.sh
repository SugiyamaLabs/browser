#!/usr/bin/env bash
# Gate for phase 3 (control.*, tab.*, page.*). Usage: BROWSER_WORK=~/browser-work-4 tools/gates/fase3.sh
# Runs unattended: AGENS_BRIDGE_TEST_ANSWER=allow answers the approval sheet. Opens browser windows
# (they can take focus); captures only the browser's own windows, into $OUT.
source "$(dirname "$0")/lib.sh"
SITE_PID=""
if ! curl -sf -o /dev/null http://127.0.0.1:8765/form; then
  python3 "$REPO/tools/sites-teste/serve.py" >"$OUT/site.log" 2>&1 &
  SITE_PID=$!
  for _ in $(seq 20); do curl -sf -o /dev/null http://127.0.0.1:8765/form && break; sleep 0.25; done
fi
export AGENS_BRIDGE_TEST_ANSWER=allow
start
export GATES OUT BROWSER_PID
python3 - <<'EOF'
import base64, json, os, re, socket, struct, subprocess, time
SOCK, OUT, GATES, PID = os.environ["AGENS_SOCK"], os.environ["OUT"], os.environ["GATES"], os.environ["BROWSER_PID"]
SITE = "http://127.0.0.1:8765"
failed = []

def check(name, ok, detail=""):
    print(("PASS: " if ok else "FAIL: ") + name + ("" if ok or not detail else f"  [{detail}]"))
    if not ok: failed.append(name)

def skip(name, why):
    print(f"SKIP: {name} ({why})")

def shot(label):  # the browser's own windows only, never the screen
    ids = subprocess.run([f"{GATES}/winids", PID], capture_output=True, text=True).stdout.split()
    for i, w in enumerate(ids, 1):
        subprocess.run(["screencapture", "-x", "-l", w, f"{OUT}/{label}-{i}.png"])
    print(f"captured {len(ids)} window(s): {OUT}/{label}-*.png")

class Conn:  # one connection: control belongs to it
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(SOCK)
        self.f = self.s.makefile("r")
        self.n, self.events, self.replies = 0, [], {}
    def send(self, op, **params):  # without waiting: requests pipelined on the connection
        self.n += 1
        self.s.sendall((json.dumps({"id": self.n, "op": op, **params}) + "\n").encode())
        return self.n
    def wait(self, rid, timeout=45):
        self.s.settimeout(timeout)
        while rid not in self.replies:
            line = self.f.readline()
            if not line: raise SystemExit(f"FAIL: connection closed waiting for request {rid}")
            msg = json.loads(line)
            if "event" in msg:
                self.events.append(msg)
            else:
                self.replies[msg.get("id")] = msg
        return self.replies.pop(rid)
    def ask(self, op, timeout=45, **params):
        return self.wait(self.send(op, **params), timeout)
    def event(self, name, timeout=10):  # the first event `name`; None after `timeout`
        end = time.time() + timeout
        while True:  # a "hello" round trip collects what came before it, with no read timeout
            for e in self.events:
                if e["event"] == name:
                    self.events.remove(e)
                    return e
            if time.time() > end: return None
            self.ask("hello")
            time.sleep(0.3)
    def close(self):
        self.s.close()

def code(r):
    return "ok" if r.get("ok") else r.get("error")

def snapshot(c, tab, until=lambda nodes: True, wait=10):
    end, r = time.time() + wait, None
    while time.time() < end:
        r = c.ask("page.snapshot", tab=tab)
        if r.get("ok") and until(r["nodes"]): return r
        time.sleep(0.3)
    return r

def find(nodes, role, name=None, pred=lambda n: True):
    for n in nodes:
        if n["role"] == role and (name is None or re.search(name, n["name"], re.I)) and pred(n): return n
    return None

c = Conn()
ato = c.ask("atos.create", name="Controle", color="teal").get("ato")
check("atos.create for the gate", bool(ato))

# Without control.start, tab and page ops are refused.
check("tab.open without control.start is unauthorized", code(c.ask("tab.open", ato=ato, url=f"{SITE}/form")) == "unauthorized")
check("page.snapshot without control.start is unauthorized", code(c.ask("page.snapshot", tab="t1")) == "unauthorized")

r = c.ask("control.start", ato=ato, reason="Gate da fase 3")
check("control.start (test answer allow)", code(r) == "ok", r)
check("a second control.start on the same connection is refused", code(c.ask("control.start", ato=ato, reason="x")) == "bad_request")
check("tab.open on another ato is denied", code(c.ask("tab.open", ato="Default", url=f"{SITE}/form")) == "denied")
for bad in ("file:///etc/passwd", "javascript:alert(1)", "chrome://settings", "data:text/html,hi"):
    check(f"tab.open {bad.split(':')[0]}: is bad_request", code(c.ask("tab.open", ato=ato, url=bad)) == "bad_request")

r = c.ask("tab.open", ato=ato, url=f"{SITE}/form")
tab = r.get("tab")
check("tab.open /form gives a tab id", code(r) == "ok" and bool(tab), r)

r = snapshot(c, tab, lambda ns: find(ns, "button", "^Show$") is not None)
nodes = r.get("nodes", []) if r else []
text = find(nodes, "textField", "Text", lambda n: not n.get("password"))
pw = find(nodes, "textField", "Password")
box = find(nodes, "checkBox")
sel = find(nodes, "comboBoxSelect")
show = find(nodes, "button", "^Show$")
link = find(nodes, "link", "Other page")
check("snapshot lists the form fields (text, password, checkbox, select, button, link)",
      all([text, pw, box, sel, show, link]), [n["role"] + ":" + n["name"] for n in nodes][:40])
check("snapshot: the password field is flagged and has no value", bool(pw) and pw.get("password") is True and "value" not in pw, pw)
check("snapshot: checkbox carries checked=false", bool(box) and box.get("checked") is False, box)
if box:
    for want in (True, False):
        c.ask("page.click", tab=tab, ref=box["ref"])
        r = snapshot(c, tab, lambda ns: (find(ns, "checkBox") or {}).get("checked") is want, wait=4)
        b2 = find(r.get("nodes", []), "checkBox") if r else None
        check(f"click on the checkbox: snapshot says checked={want}", bool(b2) and b2.get("checked") is want, b2)
shot("controlled")  # look: the pill at the bottom of the card ("<app> está usando esta aba", Assumir), mark on the tab

if text and show:
    check("page.type into the text field", code(c.ask("page.type", tab=tab, ref=text["ref"], text="hello agens")) == "ok")
    check("page.click on Show", code(c.ask("page.click", tab=tab, ref=show["ref"])) == "ok")
    r = snapshot(c, tab, lambda ns: any("hello agens" in n["name"] for n in ns if n["role"] == "staticText"), wait=6)
    check("snapshot shows the typed text written by the page", bool(r) and r.get("ok") and
          any("hello agens" in n["name"] for n in r["nodes"] if n["role"] == "staticText"))
    t2 = find(r["nodes"], "textField", "Text", lambda n: not n.get("password")) if r and r.get("ok") else None
    check("snapshot: the text field's value is what was typed", bool(t2) and t2.get("value") == "hello agens", t2)
if pw:
    r = c.ask("page.type", tab=tab, ref=pw["ref"], text="secret")
    check("page.type into the password field is denied", code(r) == "denied", r)
    check("page.click on the password field (focus) is allowed", code(c.ask("page.click", tab=tab, ref=pw["ref"])) == "ok")
    for k in ("a", "Backspace", "Delete"):
        r = c.ask("page.key", tab=tab, key=k)
        check(f"page.key {k} while the password field has the focus is denied", code(r) == "denied", r)
    r = c.ask("page.key", tab=tab, key="v", modifiers=["meta"])
    check("page.key meta+v (paste) is denied", code(r) == "denied", r)
    r = c.ask("page.key", tab=tab, key="Tab")
    check("page.key Tab while the password field has the focus is allowed", code(r) == "ok", r)
if text and pw:
    # Pipelined, no wait between them: Tab moves the focus from Text to Password, so the "a"
    # sent right after must be checked against the focus after the Tab.
    c.ask("page.click", tab=tab, ref=text["ref"])
    t_id, a_id = c.send("page.key", tab=tab, key="Tab"), c.send("page.key", tab=tab, key="a")
    rt, ra = c.wait(t_id), c.wait(a_id)
    check("pipelined Tab then a: Tab ok, a denied (focus landed on the password field)",
          code(rt) == "ok" and code(ra) == "denied", (rt, ra))
check("page.key with an unknown key is bad_request", code(c.ask("page.key", tab=tab, key="Hyper")) == "bad_request")
check("page.type with a newline is bad_request", code(c.ask("page.type", tab=tab, ref=text["ref"] if text else "e1", text="a\nb")) == "bad_request")

r = c.ask("page.screenshot", tab=tab)
png = base64.b64decode(r.get("png", "")) if r.get("ok") else b""
good = png[:8] == b"\x89PNG\r\n\x1a\n" and len(png) > 1000
w, h = struct.unpack(">II", png[16:24]) if good else (0, 0)
check("page.screenshot is a PNG of a sane size", good and w >= 200 and h >= 100, f"{code(r)} {len(png)} bytes {w}x{h}")
if good:
    open(f"{OUT}/screenshot.png", "wb").write(png)

# "Show password" toggle: needs the addition to /form described in the report (id pin, button eye).
r = c.ask("page.snapshot", tab=tab)
nodes = r.get("nodes", [])
pin = find(nodes, "textField", "PIN")
eye = find(nodes, "button", "Mostrar senha")
if not (pin and eye):
    skip("show-password protection", "no PIN field with a 'Mostrar senha' button on /form")
else:
    check("snapshot never carries the PIN's value", "pin-secret-42" not in json.dumps(r))
    c.ask("page.click", tab=tab, ref=eye["ref"])
    time.sleep(0.5)
    r = c.ask("page.snapshot", tab=tab)
    p2 = find(r.get("nodes", []), "textField", "PIN")
    check("revealed PIN stays a password: flagged, no value", bool(p2) and p2.get("password") is True and "value" not in p2, p2)
    check("revealed PIN: its value is nowhere in the snapshot", "pin-secret-42" not in json.dumps(r))
    # Hide it again, then pipeline "show" and a screenshot: the screenshot must see the click.
    c.ask("page.click", tab=tab, ref=eye["ref"])
    time.sleep(0.5)
    check("screenshot with the PIN hidden works", code(c.ask("page.screenshot", tab=tab)) == "ok")
    e_id, s_id = c.send("page.click", tab=tab, ref=eye["ref"]), c.send("page.screenshot", tab=tab)
    re_, rs = c.wait(e_id), c.wait(s_id)
    check("pipelined click on Mostrar senha then screenshot: screenshot denied",
          code(re_) == "ok" and code(rs) == "denied", (re_, {k: v for k, v in rs.items() if k != "png"}))
    check("page.type into the revealed PIN is denied", code(c.ask("page.type", tab=tab, ref=pin["ref"], text="x")) == "denied")
    check("page.screenshot while the PIN shows its text is denied", code(c.ask("page.screenshot", tab=tab)) == "denied")
    c.ask("page.click", tab=tab, ref=pin["ref"])
    check("page.key a with the revealed PIN focused is denied", code(c.ask("page.key", tab=tab, key="a")) == "denied")
    c.ask("page.click", tab=tab, ref=eye["ref"])
    time.sleep(0.5)
    check("page.screenshot once the PIN is hidden again works", code(c.ask("page.screenshot", tab=tab)) == "ok")

if link and show:
    check("page.click on the link", code(c.ask("page.click", tab=tab, ref=link["ref"])) == "ok")
    r = snapshot(c, tab, lambda ns: find(ns, "heading", "Other page") is not None)
    check("the link navigated to /other", bool(r) and r.get("ok") and find(r["nodes"], "heading", "Other page") is not None)
    check("an old ref after navigation is not_found", code(c.ask("page.click", tab=tab, ref=show["ref"])) == "not_found")

check("a tab id this session never opened is not_found", code(c.ask("page.snapshot", tab="t999")) == "not_found")
c2 = Conn()
check("second connection: control.start", code(c2.ask("control.start", ato=ato, reason="outra conexão")) == "ok")
check("second connection cannot use the first one's tab (not_found)", code(c2.ask("page.snapshot", tab=tab)) == "not_found")
check("second connection: control.stop", code(c2.ask("control.stop")) == "ok")
check("after control.stop, page ops are unauthorized", code(c2.ask("page.snapshot", tab=tab)) == "unauthorized")
c2.close()

r = c.ask("tab.open", ato=ato, url=f"{SITE}/other")
second = r.get("tab")
check("tab.open a second tab", code(r) == "ok" and second and second != tab, r)
check("tab.close it", code(c.ask("tab.close", tab=second)) == "ok")
check("a closed tab is not_found", code(c.ask("page.snapshot", tab=second)) == "not_found")

# Agent name, status lines, history, hover, scroll, console, network, dialogs, eval, allow.
c4 = Conn()
check("control.status without control.start is unauthorized", code(c4.ask("control.status", title="x")) == "unauthorized")
check("control.start with an unknown allow value is bad_request",
      code(c4.ask("control.start", ato=ato, reason="x", allow=["passwords", "camera"])) == "bad_request")
check("control.start with allow not a list is bad_request", code(c4.ask("control.start", ato=ato, reason="x", allow="clipboard")) == "bad_request")
for bad in ("", "a\nb", "x" * 41, "a\u202eb"):
    check(f"control.start with agent {bad[:8]!r} is bad_request", code(c4.ask("control.start", ato=ato, reason="x", agent=bad)) == "bad_request")
for bad in ("a\nb", "a\u202eb", "a\u2060b"):
    check(f"control.start with reason {bad!r} is bad_request", code(c4.ask("control.start", ato=ato, reason=bad)) == "bad_request")
r = c4.ask("control.start", ato=ato, reason="Gate da fase 3: o agente", agent="Popi", allow=["eval"])
check("control.start with agent Popi and allow [eval]", code(r) == "ok", r)
for good in ({"title": "Popi está testando a página", "detail": "passo 1 de 3"}, {"detail": "passo 2 de 3"},
             {"title": "", "detail": ""}, {}):
    check(f"control.status {good} is ok", code(c4.ask("control.status", **good)) == "ok")
for bad in ({"title": "x" * 121}, {"detail": "a\nb"}, {"title": 3}, {"detail": "a\u202eb"}):
    check(f"control.status {str(bad)[:30]} is bad_request", code(c4.ask("control.status", **bad)) == "bad_request")
c4.ask("control.status", title="Popi está testando a página", detail="passo 3 de 3")
r = c4.ask("tab.open", ato=ato, url=f"{SITE}/agent#frag-secret")
at = r.get("tab")
check("tab.open /agent", code(r) == "ok" and bool(at), r)
heading = lambda name: (lambda ns: find(ns, "heading", name) is not None)

check("tab.back with nothing behind is bad_request", code(c4.ask("tab.back", tab=at)) == "bad_request")
check("tab.forward with nothing ahead is bad_request", code(c4.ask("tab.forward", tab=at)) == "bad_request")
check("tab.back on an unknown tab is not_found", code(c4.ask("tab.back", tab="t999")) == "not_found")
c4.ask("tab.navigate", tab=at, url=f"{SITE}/other")
r = c4.ask("tab.back", tab=at)
check("tab.back answers with the tab", code(r) == "ok" and r.get("tab") == at, r)
r = snapshot(c4, at, heading("Agent page"), wait=6)
check("after tab.back the tab shows /agent", bool(r) and r.get("ok") and heading("Agent page")(r["nodes"]))
check("tab.forward", code(c4.ask("tab.forward", tab=at)) == "ok")
r = snapshot(c4, at, heading("Other page"), wait=6)
check("after tab.forward the tab shows /other", bool(r) and r.get("ok") and heading("Other page")(r["nodes"]))
c4.ask("tab.back", tab=at)
check("tab.reload", code(c4.ask("tab.reload", tab=at)) == "ok")
r = snapshot(c4, at, lambda ns: heading("Agent page")(ns) and find(ns, "button", "^Hover me$") is not None, wait=6)
nodes = r.get("nodes", []) if r else []
check("after tab.reload the tab shows /agent", heading("Agent page")(nodes))

hover, ask = find(nodes, "button", "^Hover me$"), find(nodes, "button", "^Ask$")
if hover:
    check("page.hover", code(c4.ask("page.hover", tab=at, ref=hover["ref"])) == "ok")
    r = snapshot(c4, at, lambda ns: find(ns, "staticText", "Hovered: yes") is not None, wait=4)
    check("page.hover reached the page (Hovered: yes)", bool(r) and find(r.get("nodes", []), "staticText", "Hovered: yes") is not None)
check("page.hover without ref is bad_request", code(c4.ask("page.hover", tab=at)) == "bad_request")
check("page.scroll without dy is bad_request", code(c4.ask("page.scroll", tab=at)) == "bad_request")
check("page.scroll dy 600", code(c4.ask("page.scroll", tab=at, dy=600)) == "ok")
scrolled = lambda ns: any(re.match(r"Scrolled: [1-9]", n["name"]) for n in ns if n["role"] == "staticText")
r = snapshot(c4, at, scrolled, wait=4)
check("page.scroll moved the page (Scrolled: > 0)", bool(r) and scrolled(r.get("nodes", [])),
      [n["name"] for n in (r or {}).get("nodes", []) if n["name"].startswith("Scrolled")])
if hover:
    check("page.scroll at an element (ref)", code(c4.ask("page.scroll", tab=at, dy=-300, ref=hover["ref"])) == "ok")

time.sleep(0.5)
r = c4.ask("page.console", tab=at)
msgs = r.get("messages", [])
check("page.console has the page's console.log", any("agens-console-test" in m.get("text", "") for m in msgs), msgs[-5:])
check("page.console has the uncaught error, as an error",
      any("agens-uncaught-test" in m.get("text", "") and m.get("level") == "error" for m in msgs), msgs[-5:])
check("page.console entries carry level, text, url and line",
      bool(msgs) and all(set(m) == {"level", "text", "url", "line"} for m in msgs), msgs[:2])
r = c4.ask("page.network", tab=at)
reqs = r.get("requests", [])
check("page.network has the 404 the page fetched",
      any(q.get("url", "").endswith("/missing-404") and q.get("status") == 404 for q in reqs), reqs)
check("page.network has no entry for the successful /api/ping", not any("/api/ping" in q.get("url", "") for q in reqs), reqs)
check("no fragment in page.console or page.network URLs",
      not any("#" in e.get("url", "") for e in msgs + reqs), [e.get("url") for e in msgs + reqs if "#" in e.get("url", "")])
check("page.network entries carry only url, method, status or error, type",
      all(set(q) <= {"url", "method", "status", "error", "type"} for q in reqs), reqs[:2])

if ask:
    c4.ask("page.click", tab=at, ref=ask["ref"])  # answers once the click is handled, or after 2 s with the page held
    ev = c4.event("page.dialog", timeout=10)
    check("confirm() is held and reported as page.dialog", bool(ev) and ev.get("type") == "confirm" and
          ev.get("tab") == at and ev.get("message") == "Proceed?", ev)
    r = c4.ask("page.snapshot", tab=at)
    check("page.snapshot while the dialog is open is dialog_open", code(r) == "dialog_open", code(r))
    check("page.eval while the dialog is open is dialog_open", code(c4.ask("page.eval", tab=at, js="1")) == "dialog_open")
    check("page.dialog with a bad action is bad_request", code(c4.ask("page.dialog", tab=at, action="maybe")) == "bad_request")
    check("page.dialog accept", code(c4.ask("page.dialog", tab=at, action="accept")) == "ok")
    r = snapshot(c4, at, lambda ns: find(ns, "staticText", "Answer: true") is not None, wait=4)
    check("the page got confirm() == true", bool(r) and find(r.get("nodes", []), "staticText", "Answer: true") is not None)
    check("page.dialog with no dialog open is bad_request", code(c4.ask("page.dialog", tab=at, action="dismiss")) == "bad_request")

r = c4.ask("page.eval", tab=at, js="document.title")
check("with allow [eval]: page.eval works on the local site", code(c4.ask("page.eval", tab=at, js="1 + 1")) == "ok")
check("page.eval on the local site returns the value", code(r) == "ok" and r.get("result") == "Agent (test)", r)
r = c4.ask("page.eval", tab=at, js="({a: 1 + 1, b: [true, null]})")
check("page.eval returns an object as JSON", code(r) == "ok" and r.get("result") == {"a": 2, "b": [True, None]}, r)
check("page.eval of undefined returns null", c4.ask("page.eval", tab=at, js="undefined").get("result", 0) is None)
r = c4.ask("page.eval", tab=at, js="throw new Error('boom')")
check("page.eval that throws is failed", code(r) == "failed" and "boom" in r.get("message", ""), r)
check("page.eval of a function (not JSON) is failed", code(c4.ask("page.eval", tab=at, js="(() => 1)")) == "failed")
check("page.eval with a too long script is bad_request", code(c4.ask("page.eval", tab=at, js="1;" * 50001)) == "bad_request")
# A look-alike of localhost that still reaches the test site without any network: "localhost."
# (trailing dot) is not local for page.eval.
c4.ask("tab.navigate", tab=at, url="http://localhost.:8765/agent")
r = snapshot(c4, at, heading("Agent page"), wait=4)
print("info: http://localhost.:8765/agent", "loaded" if r and r.get("ok") and heading("Agent page")(r["nodes"]) else "did not load (error page)")
check("page.eval on http://localhost.:8765 (look-alike) is denied", code(c4.ask("page.eval", tab=at, js="1")) == "denied")
c4.ask("tab.navigate", tab=at, url="http://example.invalid/")
check("page.eval on http://example.invalid/ (error page) is denied", code(c4.ask("page.eval", tab=at, js="1")) == "denied")

# tab.reload after a form POST would resubmit it: refused.
r = c4.ask("tab.navigate", tab=at, url=f"{SITE}/post")
r = snapshot(c4, at, lambda ns: find(ns, "button", "^Send$") is not None, wait=6)
send = find(r.get("nodes", []), "button", "^Send$") if r else None
if send:
    c4.ask("page.click", tab=at, ref=send["ref"])
    r = snapshot(c4, at, heading("Posted"), wait=6)
    check("the POST form landed on /posted", bool(r) and r.get("ok") and heading("Posted")(r["nodes"]))
    r = c4.ask("tab.reload", tab=at)
    check("tab.reload after a form POST is bad_request", code(r) == "bad_request" and "resubmit" in r.get("message", ""), r)
else:
    check("the /post page shows its Send button", False)

# Clipboard: refused without allow, open with allow ["clipboard"] (also on a password field).
r = c4.ask("tab.open", ato=ato, url=f"{SITE}/form")
ft = r.get("tab")
r = snapshot(c4, ft, lambda ns: find(ns, "textField", "Text", lambda n: not n.get("password")) is not None)
ftext = find(r.get("nodes", []), "textField", "Text", lambda n: not n.get("password")) if r else None
if ftext:
    c4.ask("page.click", tab=ft, ref=ftext["ref"])
check("without clipboard: page.key meta+v is denied", code(c4.ask("page.key", tab=ft, key="v", modifiers=["meta"])) == "denied")
check("control.stop (agent session)", code(c4.ask("control.stop")) == "ok")
c4.close()
c5 = Conn()
r = c5.ask("control.start", ato=ato, reason="Gate: copiar e colar", allow=["clipboard"])
check("control.start with allow [clipboard]", code(r) == "ok", r)
r = c5.ask("tab.open", ato=ato, url=f"{SITE}/form")
ft = r.get("tab")
r = snapshot(c5, ft, lambda ns: find(ns, "textField", "Password") is not None)
fnodes = r.get("nodes", []) if r else []
ftext, fpw = find(fnodes, "textField", "Text", lambda n: not n.get("password")), find(fnodes, "textField", "Password")
r = c5.ask("page.eval", tab=ft, js="1")
check("without allow [eval]: page.eval on the local site is denied", code(r) == "denied", r)
if ftext:
    c5.ask("page.click", tab=ft, ref=ftext["ref"])
    r = c5.ask("page.key", tab=ft, key="v", modifiers=["meta"])
    check("with clipboard: page.key meta+v is no longer refused", code(r) == "ok", r)
if fpw:
    c5.ask("page.click", tab=ft, ref=fpw["ref"])
    r = c5.ask("page.key", tab=ft, key="v", modifiers=["meta"])
    check("with clipboard: page.key meta+v on the password field is not refused", code(r) == "ok", r)
    check("with clipboard: page.type into the password field is still denied",
          code(c5.ask("page.type", tab=ft, ref=fpw["ref"], text="x")) == "denied")
check("control.stop (clipboard session)", code(c5.ask("control.stop")) == "ok")
c5.close()
skip("Assumir: tab and page ops answer paused, event control.paused {by: user}", "needs a person to press it (PauseBlocks is in the self-check)")
skip("Devolver: event control.resumed and ops work again", "needs a person to press it")
skip("Assumir with a dialog pending shows it to the person", "needs a person")
skip("allow [passwords]: saved logins fill in the session's tabs", "needs a saved login and a person to look")

c.close()  # disconnect: control ends, its tabs stay open but are no longer controlled
time.sleep(1.5)
c3 = Conn()
check("after disconnect, a new connection has no control (unauthorized)", code(c3.ask("page.snapshot", tab=tab)) == "unauthorized")
check("new connection: control.start", code(c3.ask("control.start", ato=ato, reason="depois")) == "ok")
check("after disconnect, the old tab can't be adopted (not_found)", code(c3.ask("page.snapshot", tab=tab)) == "not_found")
shot("after-disconnect")  # look: the /other tab is still open, without border, strip or mark
check("control.stop", code(c3.ask("control.stop")) == "ok")
c3.close()
skip("Encerrar (the stop bubble) sends control.stopped {reason: user}", "needs a person to press it")

print("\nRESULT:", "PASS" if not failed else f"FAIL ({len(failed)}): " + "; ".join(failed))
EOF
kill -0 "$BROWSER_PID" 2>/dev/null && echo "browser still running" || echo "FAIL: the browser is gone (crash?)"
grep -iE "check failed|crash" "$OUT/browser.log" | head -5
stop
[ -n "$SITE_PID" ] && kill "$SITE_PID" 2>/dev/null
echo "output: $OUT"
