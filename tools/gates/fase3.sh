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
        self.n, self.events = 0, []
    def ask(self, op, timeout=45, **params):
        self.n += 1
        self.s.sendall((json.dumps({"id": self.n, "op": op, **params}) + "\n").encode())
        self.s.settimeout(timeout)
        while True:
            line = self.f.readline()
            if not line: raise SystemExit(f"FAIL: connection closed during {op}")
            msg = json.loads(line)
            if "event" in msg:
                self.events.append(msg)
            elif msg.get("id") == self.n:
                return msg
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
shot("controlled")  # look: warm border around the card, strip "Controlado pelo … · Parar", mark on the tab

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

c.close()  # disconnect: control ends, its tabs stay open but are no longer controlled
time.sleep(1.5)
c3 = Conn()
check("after disconnect, a new connection has no control (unauthorized)", code(c3.ask("page.snapshot", tab=tab)) == "unauthorized")
check("new connection: control.start", code(c3.ask("control.start", ato=ato, reason="depois")) == "ok")
check("after disconnect, the old tab can't be adopted (not_found)", code(c3.ask("page.snapshot", tab=tab)) == "not_found")
shot("after-disconnect")  # look: the /other tab is still open, without border, strip or mark
check("control.stop", code(c3.ask("control.stop")) == "ok")
c3.close()
skip("Parar on the strip sends control.stopped {reason: user}", "needs a person to press it")

print("\nRESULT:", "PASS" if not failed else f"FAIL ({len(failed)}): " + "; ".join(failed))
EOF
kill -0 "$BROWSER_PID" 2>/dev/null && echo "browser still running" || echo "FAIL: the browser is gone (crash?)"
grep -iE "check failed|crash" "$OUT/browser.log" | head -5
stop
[ -n "$SITE_PID" ] && kill "$SITE_PID" 2>/dev/null
echo "output: $OUT"
