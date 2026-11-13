#!/usr/bin/env bash
# Gate for the embedded engine (docs/protocolo.md, "host e view"). Usage:
#   BROWSER_WORK=~/browser-work-2 tools/gates/embutido.sh
# A small Python parent starts the engine with --agens-embedded on a throwaway profile and acts as
# its host on one connection (the parent always gets in); a second short launch adds
# --agens-accept-unsigned to check that switch. The engine must never put a window on
# screen nor show in the Dock, so this gate should not take focus. It never captures the screen and
# never sends system-wide input. EMBUTIDO_STANDALONE=1 also launches the engine WITHOUT the switch
# to check unknown_op: that one is a normal Dock app and can take focus, so it is opt-in.
# EMBUTIDO_INSPECT=1 also opens a real DevTools window (view.inspect): that window shows on screen
# and takes the keyboard focus, so it is opt-in too.
# SITE_PORT=8766 runs (or reuses) the test site on another port, e.g. when an older one holds 8765.
source "$(dirname "$0")/lib.sh"
SITE_PORT="${SITE_PORT:-8765}"
EMBUTIDO_INSPECT="${EMBUTIDO_INSPECT:-0}"
export APP OUT GATES REPO SITE_PORT EMBUTIDO_INSPECT

SITE_PID=""
if ! curl -sf -o /dev/null "http://127.0.0.1:$SITE_PORT/janela"; then   # /janela: the newest page, so an older site is not reused
  python3 "$REPO/tools/sites-teste/serve.py" "$SITE_PORT" >"$OUT/site.log" 2>&1 &
  SITE_PID=$!
  for _ in $(seq 20); do curl -sf -o /dev/null "http://127.0.0.1:$SITE_PORT/janela" && break; sleep 0.25; done
  curl -sf -o /dev/null "http://127.0.0.1:$SITE_PORT/janela" || { echo "FAIL: the test site has no /janela (an older serve.py on port $SITE_PORT? try SITE_PORT=8766)"; exit 1; }
fi

# winids lists every normal window of a pid, also the ones off screen; this one counts only those
# on screen (what a person could see).
cat >"$OUT/onscreen.swift" <<'EOF'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
print(list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }.count)
EOF
swiftc -O "$OUT/onscreen.swift" -o "$OUT/onscreen" || { echo "FAIL: could not build the on-screen check"; exit 1; }

# Mouse and key events as the host's view sends them: built and serialized, never posted. One line
# per name given: move, down, up (left button), rightdown, rightup, esc, escup (the Escape key).
cat >"$OUT/events.swift" <<'EOF'
import CoreGraphics
import Foundation
let mouse: [String: (CGEventType, CGMouseButton)] = [
  "move": (.mouseMoved, .left), "down": (.leftMouseDown, .left), "up": (.leftMouseUp, .left),
  "rightdown": (.rightMouseDown, .right), "rightup": (.rightMouseUp, .right)]
for name in CommandLine.arguments.dropFirst() {
  let event: CGEvent
  if name == "esc" || name == "escup" {
    event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: name == "esc")!
  } else {
    let (type, button) = mouse[name]!
    event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button)!
    if name == "down" || name == "up" { event.setIntegerValueField(.mouseEventClickState, value: 1) }
  }
  print((event.data! as Data).base64EncodedString())
}
EOF
swiftc -O "$OUT/events.swift" -o "$OUT/events" || { echo "FAIL: could not build the events helper"; exit 1; }

cat >"$OUT/parent.py" <<'EOF'
import base64, json, os, re, select, socket, struct, subprocess, sys, tempfile, time, zlib
APP, OUT, GATES = os.environ["APP"], os.environ["OUT"], os.environ["GATES"]
PORT = os.environ["SITE_PORT"]
SITE = f"http://127.0.0.1:{PORT}"
failed = []

def check(name, ok, detail=""):
    print(("PASS: " if ok else "FAIL: ") + name + ("" if ok or not detail else f"  [{detail}]"), flush=True)
    if not ok: failed.append(name)

profile = tempfile.mkdtemp(prefix="agens-e.", dir="/tmp")   # short: a socket path is limited to 104 bytes
SOCK = profile + "/agens.sock"
# The test extension marks /ext pages (" +ext" in the title): --load-extension works in this build.
EXTENSION = os.environ["REPO"] + "/tools/sites-teste/extensao"
def launch(profile, *extra):
    log = open(f"{OUT}/engine{'-' + extra[0].strip('-') if extra else ''}.log", "w")
    p = subprocess.Popen([APP, f"--user-data-dir={profile}", "--agens-embedded", *extra, f"--load-extension={EXTENSION}",
                          "--use-mock-keychain", "--no-first-run"], stdout=log, stderr=log)
    for _ in range(60):
        if os.path.exists(profile + "/agens.sock"): return p
        time.sleep(0.5)
    print("FAIL: no socket after 30 s"); open(f"{OUT}/done", "w").write("1"); time.sleep(3600)

# A second ato that sleeps from the start (listed in Local State, never loaded): step 5.6 installs
# into it and must wake it.
SLEEPER = "Profile 9"
os.makedirs(f"{profile}/{SLEEPER}")
json.dump({"profile": {"info_cache": {SLEEPER: {"name": "Gate dormindo", "is_using_default_name": False}}}},
          open(f"{profile}/Local State", "w"))
engine = launch(profile)
open(f"{OUT}/engine.pid", "w").write(str(engine.pid))
open(f"{OUT}/profile", "w").write(profile)

def other_process(sock, *lines):  # another process: sends each line, prints each answer (or "closed")
    code = f"""
import json, socket
s = socket.socket(socket.AF_UNIX); s.connect({sock!r}); f = s.makefile()
for line in {list(lines)!r}:
    try: s.sendall((line + "\\n").encode())
    except OSError: pass
    print(f.readline().strip() or "closed")"""
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=30).stdout.split("\n")
    return [json.loads(l) if l.startswith("{") else {"ok": False, "error": l} for l in out if l]

class Conn:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX); self.s.connect(SOCK)
        self.buf, self.n, self.events, self.replies = b"", 0, [], {}
    def send_raw(self, obj):
        self.s.sendall((json.dumps(obj) + "\n").encode())
    def send(self, op, **params):
        self.n += 1; self.send_raw({"id": self.n, "op": op, **params}); return self.n
    def pump(self, timeout):  # reads what arrives within `timeout`; False once closed
        r, _, _ = select.select([self.s], [], [], timeout)
        if not r: return True
        data = self.s.recv(1 << 20)
        if not data: return False
        self.buf += data
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            msg = json.loads(line)
            if "event" in msg: self.events.append(msg)
            else: self.replies.setdefault(msg.get("id"), msg)
        return True
    def wait(self, rid, timeout=30):
        end = time.time() + timeout
        while rid not in self.replies:
            if time.time() > end: return {"ok": False, "error": "timeout"}
            if not self.pump(0.5): return {"ok": False, "error": "closed"}
        return self.replies.pop(rid)
    def ask(self, op, timeout=30, **params):
        return self.wait(self.send(op, **params), timeout)
    def event(self, pred, timeout=20):  # the first stored or arriving event matching, consumed
        end = time.time() + timeout
        while True:
            for i, e in enumerate(self.events):
                if pred(e): return self.events.pop(i)
            if time.time() > end or not self.pump(0.5): return None

def err(r): return r.get("error") if not r.get("ok") else "ok"

c = Conn()
check("hello", c.ask("hello", client="embutido-gate").get("ok"))

# Not a Dock app: LaunchServices calls it a UIElement (or never heard of it), not Foreground.
apps = subprocess.run(["lsappinfo", "list"], capture_output=True, text=True).stdout
m = re.search(r"pid = %d .*?type=\"(\w+)\"" % engine.pid, apps)
kind = m.group(1) if m else "not registered"
check("engine is not a Dock app", kind != "Foreground", kind)

# Another process, unsigned and not listed in --agens-allowed-clients: refused at connect.
r = other_process(SOCK, '{"id":1,"op":"hello"}', '{"id":2,"op":"hello"}')
check("another process is refused at connect", len(r) == 2 and err(r[0]) == "unauthorized" and r[1].get("error") == "closed", r)

# With --agens-accept-unsigned it gets in, but host.attach stays the parent's.
profile2 = tempfile.mkdtemp(prefix="agens-u.", dir="/tmp")
engine2 = launch(profile2, "--agens-accept-unsigned")
r = other_process(profile2 + "/agens.sock", '{"id":1,"op":"hello"}', '{"id":2,"op":"host.attach"}')
check("--agens-accept-unsigned lets another process in", len(r) == 2 and r[0].get("ok"), r)
check("host.attach from another process is unauthorized", len(r) == 2 and err(r[1]) == "unauthorized", r)
engine2.terminate()
try: engine2.wait(15)
except subprocess.TimeoutExpired: engine2.kill()
subprocess.run(["rm", "-rf", profile2])

check("host.attach from the parent", c.ask("host.attach").get("ok"))
r = c.ask("host.attach")
check("a second host.attach on the same connection is refused", not r.get("ok"), r)
c2 = Conn()
r = c2.ask("host.attach")
check("a second host connection is refused", err(r) == "unauthorized", r)
r = c2.ask("view.tabs")
check("view.* from a connection that is not the host is unauthorized", err(r) == "unauthorized", r)
check("host.nope is unknown_op", err(c.ask("host.nope")) == "unknown_op")
r = c.ask("host.settings")
check("host.settings with no field reads the defaults (site_requests false, agent_extensions true)",
      r.get("ok") and r.get("site_requests") is False and r.get("agent_extensions") is True, r)
check("host.settings from a connection that is not the host is unauthorized",
      err(c2.ask("host.settings", site_requests=True)) == "unauthorized")
check("host.settings with a value that is not a boolean is bad_request",
      err(c.ask("host.settings", agent_extensions="no")) == "bad_request")

atos = c.ask("atos.list").get("atos") or []
ato = atos[0]["id"] if atos else c.ask("atos.create", name="Gate").get("ato")
print(f"ato: {ato}")

def tab_event(tab, pred=lambda e: True, timeout=20):
    return c.event(lambda e: e["event"] == "view.tab" and e.get("tab") == tab and pred(e), timeout)
def layer_event(tab, width, timeout=20):
    return c.event(lambda e: e["event"] == "view.layer" and e.get("tab") == tab and e.get("width") == width, timeout)
def drop(tab):  # forget the view.tab events seen so far, so the next check sees only new ones
    c.pump(0.5)
    c.events = [e for e in c.events if not (e["event"] == "view.tab" and e.get("tab") == tab)]
def loaded(path):
    return lambda e: e.get("url", "").startswith(SITE + path) and not e.get("loading")

r = c.ask("view.open", ato=ato, url=SITE + "/form")
t1 = r.get("tab", "")
check("view.open gives a v<n> tab", bool(re.fullmatch(r"v[1-9][0-9]*", t1)), r)
c.ask("view.attach", tab=t1, width=800, height=600, scale=1)
l1 = layer_event(t1, 800)
check("view.layer for the attached tab, non-zero context, the asked size",
      bool(l1) and l1["context"] > 0 and l1["width"] == 800 and l1["height"] == 600, l1)
e = tab_event(t1, loaded("/form"))
r = c.ask("view.attach", tab=t1, width=8193, height=600, scale=1)
check("view.attach past 8192 points is bad_request", err(r) == "bad_request", r)
check("view.tab with title and url of the test site", bool(e) and e.get("title") == "Form (test)" and e.get("ato") == ato, e)

drop(t1); c.ask("view.navigate", tab=t1, text=SITE + "/other")
e = tab_event(t1, loaded("/other"))
check("view.navigate changes the url", bool(e) and e.get("can_back") is True, e)
drop(t1); c.ask("view.back", tab=t1)
check("view.back goes back", bool(tab_event(t1, loaded("/form"))))
drop(t1); c.ask("view.forward", tab=t1)
check("view.forward goes forward", bool(tab_event(t1, loaded("/other"))))
drop(t1); c.ask("view.reload", tab=t1)
check("view.reload reloads", bool(tab_event(t1, lambda e: e.get("loading"))) and bool(tab_event(t1, loaded("/other"))))
r = c.ask("view.navigate", tab=t1, text="agens gate search words")
check("view.navigate takes a search", r.get("ok"), r)

r = c.ask("view.open", ato=ato, url=SITE + "/login")
t2 = r.get("tab", "")
c.ask("view.attach", tab=t2, width=640, height=480, scale=1)
l2 = layer_event(t2, 640)
check("a second attached tab gets its own layer",
      bool(l2) and l2["context"] > 0 and l2["width"] == 640 and l2["height"] == 480 and t2 != t1, l2)
c.ask("view.resize", tab=t1, width=700, height=500, scale=1)
l1b = layer_event(t1, 700)
check("view.resize sends a new layer at the new size", bool(l1b) and l1b["width"] == 700 and l1b["height"] == 500, l1b)
r = c.ask("view.tabs", ato=ato)
ids = [t["tab"] for t in r.get("tabs", [])]
check("view.tabs lists both", t1 in ids and t2 in ids, ids)
r = c.ask("view.favicon", tab=t2)
check("view.favicon answers png", r.get("ok") and isinstance(r.get("png"), str), r)

# Garbage input: no reply, dropped, the connection goes on.
for bad in [{"op": "view.mouse", "tab": t1, "data": "!!!", "x": "a"},
            {"op": "view.key", "tab": t1, "data": 123},
            {"op": "view.wheel", "tab": t1, "data": "A" * 70000, "x": 1, "y": 1},
            {"op": "view.mouse", "tab": "v999999", "data": "AAAA", "x": 1, "y": 1},
            {"op": "view.edit", "tab": t1, "command": "rm -rf"},
            {"op": "view.focus", "tab": t1, "on": "yes"},
            {"op": "view.mouse.leave", "tab": "nope"},
            {"op": "view.key", "tab": t1, "data": "AAAA", "commands": [""]},
            {"op": "view.key", "tab": t1, "data": "AAAA", "commands": ["not a selector"]}]:
    c.send_raw(bad)
c.send_raw({"op": "view.focus", "tab": t1, "on": True})
r = c.ask("hello")
check("garbage input is ignored and the connection survives", r.get("ok") and None not in c.replies, c.replies.get(None))

# A normal op without id: refused (bad_request, without id) and not run.
c.send_raw({"op": "atos.create", "name": "NoIdGate"})
r = c.ask("atos.list")
bad = c.replies.pop(None, {})
check("a normal op without id is bad_request and does nothing",
      err(bad) == "bad_request" and all(a.get("name") != "NoIdGate" for a in r.get("atos", [])), bad)

# Attached again after a detach, at the same size: the layer comes again although nothing redraws.
c.ask("view.detach", tab=t1)
c.pump(1)
c.events = [e for e in c.events if e["event"] != "view.layer"]
c.ask("view.attach", tab=t1, width=700, height=500, scale=1)
l1c = layer_event(t1, 700, 5)
check("view.attach of an idle tab at the same size gets view.layer", bool(l1c) and l1c["context"] > 0, l1c)

# The engine has no window on screen (its tabs live in windows that never show).
time.sleep(1)
onscreen = subprocess.run([f"{OUT}/onscreen", str(engine.pid)], capture_output=True, text=True).stdout.strip()
listed = subprocess.run([f"{GATES}/winids", str(engine.pid)], capture_output=True, text=True).stdout.split()
check("engine has no window on screen", onscreen == "0", f"on screen: {onscreen}")
print(f"info: winids lists {len(listed)} window(s) for the engine, all off screen when the line above passes")

# Approvals go to the host; an agent's tab shows up with control.
agent = Conn()
rid = agent.send("control.start", ato=ato, reason="gate", agent="Gate Agent", allow=["clipboard", "eval"])
a = c.event(lambda e: e["event"] == "approval.ask", 20)
check("control.start asks the host (approval.ask)", bool(a) and isinstance(a.get("ask"), str) and a.get("title"), a)
check("the control approval carries its parts (kind, ato, ato_name, agent, reason, allow; no shares_with)",
      bool(a) and a.get("kind") == "control" and a.get("ato") == ato and bool(a.get("ato_name"))
      and a.get("agent") == "Gate Agent" and a.get("reason") == "gate" and a.get("allow") == ["clipboard", "eval"]
      and "shares_with" not in a, a)
if a:
    check("approval.answer deny", c.ask("approval.answer", ask=a["ask"], answer="deny").get("ok"))
    check("the agent gets denied", err(agent.wait(rid)) == "denied")
rid = agent.send("control.start", ato=ato, reason="gate")
a = c.event(lambda e: e["event"] == "approval.ask", 20)
if a: c.ask("approval.answer", ask=a["ask"], answer="allow")
check("the agent gets in after allow", agent.wait(rid).get("ok"))
r = agent.ask("tab.open", ato=ato, url=SITE + "/form")
e = c.event(lambda e: e["event"] == "view.tab" and isinstance(e.get("control"), dict) and e["control"].get("state") == "working", 20)
check("an agent's tab reaches the host as view.tab with control", r.get("ok") and bool(e), e)
if e:
    check("the agent's tab carries its two lines", bool(e["control"].get("agent")) and bool(e["control"].get("title")), e["control"])
    check("view.control take (Assumir)", c.ask("view.control", tab=e["tab"], action="take").get("ok"))
    check("the agent is told it paused", bool(agent.event(lambda m: m["event"] == "control.paused", 10)))
    check("the host sees the tab paused",
          bool(c.event(lambda m: m["event"] == "view.tab" and (m.get("control") or {}).get("state") == "paused", 10)))
    check("the agent's ops answer paused", err(agent.ask("page.snapshot", tab=r.get("tab"))) == "paused")
    check("view.control give (Devolver)", c.ask("view.control", tab=e["tab"], action="give").get("ok"))
    check("the agent is told it resumed", bool(agent.event(lambda m: m["event"] == "control.resumed", 10)))
    check("the agent's ops work again", agent.ask("page.snapshot", tab=r.get("tab")).get("ok"))
    # The reply of an input op comes once the page shows it: the very next snapshot has the change.
    def snap_node(role, name):
        return next((n for n in agent.ask("page.snapshot", tab=r.get("tab")).get("nodes", [])
                     if n.get("role") == role and n.get("name") == name), {})
    field = snap_node("textField", "Text").get("ref", "none")
    typed = agent.ask("page.type", tab=r.get("tab"), ref=field, text="gate typed")
    got = snap_node("textField", "Text")
    check("page.type then page.snapshot at once: the value is there", typed.get("ok") and got.get("value") == "gate typed", got)
    agent.ask("page.key", tab=r.get("tab"), key="Backspace")
    got = snap_node("textField", "Text")
    check("page.key then page.snapshot at once: the change is there", got.get("value") == "gate type", got)
    agent.ask("page.click", tab=r.get("tab"), ref=snap_node("checkBox", "Check me").get("ref", "none"))
    got = snap_node("checkBox", "Check me")
    check("page.click then page.snapshot at once: the checkbox is checked", got.get("checked") is True, got)
    # As a bot does it: a fresh tab, read, type, click Show, read; every time (half of them on a page
    # that is still loading when the tab opens).
    wrong = []
    for i in range(12):
        ft = agent.ask("tab.open", ato=ato, url=SITE + "/form" + ("?slow=1500" if i % 2 else "")).get("tab")
        nodes = agent.ask("page.snapshot", tab=ft).get("nodes", [])
        ref = lambda role, name: next((n["ref"] for n in nodes if n.get("role") == role and n.get("name") == name), "none")
        typed = agent.ask("page.type", tab=ft, ref=ref("textField", "Text"), text=f"bot {i}")
        clicked = agent.ask("page.click", tab=ft, ref=ref("button", "Show"))
        shown = [n.get("name") for n in agent.ask("page.snapshot", tab=ft).get("nodes", []) if n.get("role") == "staticText"]
        if not (typed.get("ok") and clicked.get("ok") and f"bot {i} | false | a" in shown): wrong.append((i, err(typed), err(clicked), shown[-3:]))
        if i == 0:  # the label's text next to the field: no focus can land there, so no keys are lost silently
            r2 = agent.ask("page.type", tab=ft, ref=ref("staticText", "Text "), text="lost")
            check("page.type on a label's text is bad_request (the keys would be lost)", err(r2) == "bad_request", r2)
        agent.ask("tab.close", tab=ft)
    check("12 fresh tabs: page.type then page.click Show at once, the value every time", not wrong, wrong)
    c.ask("view.control", tab=e["tab"], action="end")
    check("view.control end: the agent's control stops",
          bool(agent.event(lambda m: m["event"] == "control.stopped", 10)))

c.ask("view.close", tab=t2)
check("view.close sends view.closed", bool(c.event(lambda e: e["event"] == "view.closed" and e.get("tab") == t2)))
c.ask("view.detach", tab=t1)

# Step 5.3: the host draws menus, dialogs and requests (ui.ask / ui.answer). Every result is read from
# the tab's title, the only thing this host sees of a page. Nothing here clicks or types on the system.
def skip(name, why): print(f"SKIP: {name} ({why})", flush=True)
def ui_ask(kind, tab=None, timeout=20):
    return c.event(lambda e: e["event"] == "ui.ask" and e.get("kind") == kind and (tab is None or e.get("tab") == tab), timeout)
def ui_tab(path):  # a fresh attached tab, so no title or permission of an earlier check carries over
    t = c.ask("view.open", ato=ato, url=SITE + path).get("tab", "")
    c.ask("view.attach", tab=t, width=600, height=400, scale=1)
    return t
def titled(tab, title, timeout=10):
    return bool(tab_event(tab, lambda e: e.get("title") == title, timeout))
def answer(a, **fields): return c.ask("ui.answer", ask=(a or {}).get("ask", "none"), **fields)

# dialog on a tab without an agent
t = ui_tab("/ui/dialog?auto=confirm")
a = ui_ask("dialog", t)
check("ui.ask dialog reaches the host for a tab without an agent (type, message, origin)",
      bool(a) and a.get("type") == "confirm" and a.get("message") == "Proceed?" and a.get("origin") == SITE, a)
check("ui.answer from a connection that is not the host is unauthorized",
      err(c2.ask("ui.answer", ask=(a or {}).get("ask", "none"), accept=True)) == "unauthorized")
check("ui.answer without ask is bad_request", err(c.ask("ui.answer", accept=True)) == "bad_request")
check("ui.answer with a field of another kind (index) is bad_request", err(answer(a, index=0)) == "bad_request")
check("ui.answer with text on a confirm is bad_request", err(answer(a, text="x")) == "bad_request")
check("ui.answer with a non-boolean accept is bad_request", err(answer(a, accept="yes")) == "bad_request")
check("ui.answer accept on a dialog", err(answer(a, accept=True)) == "ok")
check("the page got confirm() == true", titled(t, "confirm:true"))
check("ui.answer for an ask already answered is not_found", err(answer(a, accept=True)) == "not_found")
check("ui.answer for an unknown ask is not_found", err(c.ask("ui.answer", ask="u999999", accept=True)) == "not_found")
c.ask("view.close", tab=t)
for kind, label, fields, want in [
        ("confirm", "refuse", dict(accept=False), "confirm:false"),
        ("confirm", "cancel", dict(cancel=True), "confirm:false"),
        ("alert", "accept", dict(accept=True), "alert:done"),
        ("prompt", "accept with text", dict(accept=True, text="gate-text"), "prompt:gate-text"),
        ("prompt", "refuse", dict(accept=False), "prompt:null"),
        ("prompt", "cancel", dict(cancel=True), "prompt:null")]:
    t = ui_tab("/ui/dialog?auto=" + kind)
    a = ui_ask("dialog", t)
    check(f"dialog {kind}: ui.ask has the type" + (" and the default" if kind == "prompt" else ""),
          bool(a) and a.get("type") == kind and (kind != "prompt" or a.get("default") == "anon"), a)
    check(f"dialog {kind}: ui.answer {label} gives {want} in the page", err(answer(a, **fields)) == "ok" and titled(t, want))
    c.ask("view.close", tab=t)
skip("dialog beforeunload", "needs a click or a key on the page first (sticky user activation); the gate has no input")

# the page or the tab ends a request: ui.cancel
t = ui_tab("/ui/dialog?auto=confirm"); a = ui_ask("dialog", t)
c.ask("view.close", tab=t)
x = c.event(lambda e: e["event"] == "ui.cancel" and e.get("ask") == (a or {}).get("ask"), 10)
check("ui.cancel (closed) when the tab closes with a dialog open", bool(x) and x.get("reason") == "closed", x)
check("answering a request cancelled by the tab closing is not_found", err(answer(a, accept=True)) == "not_found")
t = ui_tab("/ui/dialog?auto=confirm"); a = ui_ask("dialog", t)
c.ask("view.navigate", tab=t, text=SITE + "/other")
x = c.event(lambda e: e["event"] == "ui.cancel" and e.get("ask") == (a or {}).get("ask"), 10)
check("ui.cancel (navigated) when the tab navigates with a dialog open", bool(x) and x.get("reason") == "navigated", x)
check("answering a request cancelled by navigation is not_found", err(answer(a, accept=True)) == "not_found")
c.ask("view.close", tab=t)
skip("ui.cancel with reason gone", "the page has to give up on its own request; no test page does that")

# HTTP login
AUTH_USER, AUTH_PW = "test-user", "fake-password"   # the test site's fake values
# the cancel check goes first: once a credential is accepted Chromium sends it to the other paths by itself
t = ui_tab("/auth/cancel"); a = ui_ask("auth", t)
check("auth realm of another path", bool(a) and a.get("realm") == "teste-cancel", a)
check("auth ui.answer cancel shows the 401 page", err(answer(a, cancel=True)) == "ok" and titled(t, "Auth 401"))
c.ask("view.close", tab=t)
t = ui_tab("/auth")
a = ui_ask("auth", t)
check("ui.ask auth reaches the host (origin, realm, no proxy, no retry)",
      bool(a) and a.get("origin") == SITE and a.get("realm") == "teste" and a.get("proxy") is False and not a.get("retry"), a)
check("the auth ask carries no username or password", bool(a) and not {"username", "password"} & set(a), sorted(a or {}))
check("auth ui.answer without a password is bad_request", err(answer(a, username=AUTH_USER)) == "bad_request")
check("auth ui.answer with a dialog field (accept) is bad_request", err(answer(a, accept=True)) == "bad_request")
check("auth ui.answer with a wrong password", err(answer(a, username=AUTH_USER, password="wrong-password")) == "ok")
a2 = ui_ask("auth", t)
check("a refused credential asks again, with retry", bool(a2) and a2.get("retry") is True, a2)
check("auth ui.answer with the right credential", err(answer(a2, username=AUTH_USER, password=AUTH_PW)) == "ok")
check("the right credential loads the page", titled(t, "Auth ok"))
c.ask("view.close", tab=t)
c.pump(0.5)
engine_log = open(f"{OUT}/engine.log", errors="replace").read()
leaks = sum(s in engine_log or s in json.dumps([a, a2]) for s in ("wrong-password", AUTH_PW))   # a count: never print them
check("the engine log and the auth asks have none of the passwords", leaks == 0, f"{leaks} found")

# Sites may not ask by default (host.settings site_requests false): geolocation and notifications are blocked.
t = ui_tab("/ui/perm")
check("site_requests false: a page's permission request never reaches the host", ui_ask("permission", t, 4) is None)
check("site_requests false: the page sees both blocked", titled(t, "perm geo=denied notif=no"))
c.ask("view.close", tab=t)
r = c.ask("host.settings", site_requests=True)
check("host.settings site_requests true answers the values in force",
      r.get("ok") and r.get("site_requests") is True and r.get("agent_extensions") is True, r)

# permission: no remember, and a fresh tab each time (an allowed-once permission lives as long as its tab)
# deny: geolocation then notifications. allow: notifications only, because allowing geolocation can make
# macOS ask for Location Services on the real screen.
t = ui_tab("/ui/perm")
a = ui_ask("permission", t)
check("permission deny: geolocation reaches the host (origin, permission)",
      bool(a) and a.get("permission") == "geolocation" and a.get("origin") == SITE, a)
check("permission ui.answer with allow not a boolean is bad_request", err(answer(a, allow="yes")) == "bad_request")
check("permission ui.answer with index is bad_request", err(answer(a, index=0)) == "bad_request")
check("permission ui.answer with remember and no allow is bad_request", err(answer(a, remember=True)) == "bad_request")
answer(a, allow=False)
a = ui_ask("permission", t)
check("permission deny: notifications reach the host after geolocation",
      bool(a) and a.get("permission") == "notifications" and a.get("origin") == SITE, a)
answer(a, allow=False)
check("permission deny shows in the page title", titled(t, "perm geo=denied notif=no"))
c.ask("view.close", tab=t)

# a tab WITH an agent
ag = Conn()
rid = ag.send("control.start", ato=ato, reason="gate")
x = c.event(lambda e: e["event"] == "approval.ask", 20)
if x: c.ask("approval.answer", ask=x["ask"], answer="allow")
agent_ok = bool(x) and ag.wait(rid).get("ok")
check("agent: control.start for the ui checks", agent_ok)
if not agent_ok:
    skip("ui checks on tabs with an agent", "control.start did not go through")
else:
    def host_tab(path, timeout=10):  # the host's v<n> id of a tab the agent opened
        e = c.event(lambda e: e["event"] == "view.tab" and e.get("url", "").startswith(SITE + path) and isinstance(e.get("control"), dict), timeout)
        return (e or {}).get("tab")
    r = ag.ask("tab.open", ato=ato, url=SITE + "/ui/perm")
    a = ui_ask("permission")
    vt = (a or {}).get("tab")
    check("agent tab: permission reaches the host while the agent is working",
          bool(a) and a.get("permission") == "geolocation" and bool(vt), a)
    check("agent tab: the host sees that tab with the agent working",
          bool(vt) and bool(tab_event(vt, lambda e: (e.get("control") or {}).get("state") == "working", 5)))
    answer(a, allow=False)
    a = ui_ask("permission", vt)
    check("agent tab: notifications also reach the host", bool(a) and a.get("permission") == "notifications", a)
    answer(a, allow=False)
    check("agent tab: the host's answers reach the page", titled(vt, "perm geo=denied notif=no"))

    r = ag.ask("tab.open", ato=ato, url=SITE + "/ui/dialog?auto=confirm")
    pd = ag.event(lambda e: e["event"] == "page.dialog", 10)
    vt = host_tab("/ui/dialog")
    check("agent tab: the dialog goes to the agent as page.dialog",
          bool(pd) and pd.get("type") == "confirm" and pd.get("tab") == r.get("tab"), pd)
    check("agent tab: the dialog does not reach the host as ui.ask",
          c.event(lambda e: e["event"] == "ui.ask" and e.get("kind") == "dialog", 2) is None)
    ag.ask("page.dialog", tab=r.get("tab"), action="accept")
    check("agent tab: page.dialog accept reaches the page", bool(vt) and titled(vt, "confirm:true"))

    ag.ask("tab.open", ato=ato, url=SITE + "/auth/agent")
    check("agent tab: HTTP login does not reach the host while the agent works", ui_ask("auth", None, 3) is None)

    r = ag.ask("tab.open", ato=ato, url=SITE + "/ui/pick")
    at = r.get("tab")
    vt = host_tab("/ui/pick")
    c.ask("view.attach", tab=vt, width=800, height=600, scale=1)
    def node(role, name):
        return next((n for n in ag.ask("page.snapshot", tab=at).get("nodes", []) if n.get("role") == role and n.get("name") == name), None)
    def ref(role, name): return (node(role, name) or {}).get("ref", "none")

    # the cursor and the caret, provoked by the agent's own hover and click (no system input)
    ag.ask("page.hover", tab=at, ref=ref("link", "Other page"))
    x = c.event(lambda e: e["event"] == "view.cursor" and e.get("tab") == vt and e.get("cursor") == "pointer", 5)
    check("view.cursor pointer when the agent hovers a link", bool(x), x)
    ag.ask("page.click", tab=at, ref=ref("textField", "Text"))
    x = c.event(lambda e: e["event"] == "view.caret" and e.get("tab") == vt, 5)
    check("view.caret (x, y, width, height) when the agent focuses a text field",
          bool(x) and all(isinstance(x.get(k), (int, float)) for k in ("x", "y", "width", "height")), x)
    # the agent's own cursor, for the host to draw (the attached view is 800 x 600)
    x = c.event(lambda e: e["event"] == "view.agent_cursor" and e.get("tab") == vt and "x" in e, 5)
    check("view.agent_cursor (x, y inside the view) after the agent's hover and click",
          bool(x) and 0 <= x.get("x", -1) <= 800 and 0 <= x.get("y", -1) <= 600, x)
    c.ask("view.control", tab=vt, action="take")
    x = c.event(lambda e: e["event"] == "view.agent_cursor" and e.get("tab") == vt and "x" not in e, 5)
    check("view.agent_cursor without x, y after Assumir", bool(x), x)
    c.ask("view.control", tab=vt, action="give")  # the checks below start with the agent working

    # file and select open only on a page's own timer, after a click: the agent clicks, the person takes over
    ag.ask("page.click", tab=at, ref=ref("button", "Open file later"))
    check("agent tab: a file chooser does not reach the host while the agent works", ui_ask("file", vt, 4) is None)
    ag.ask("page.click", tab=at, ref=ref("button", "Open select later"))
    check("agent tab: a select menu does not reach the host while the agent works", ui_ask("select", vt, 4) is None)
    def pick(button):  # the agent clicks, then Assumir before the page's timer fires
        c.ask("view.control", tab=vt, action="give")
        ag.ask("page.click", tab=at, ref=ref("button", button))
        c.ask("view.control", tab=vt, action="take")

    tmp = tempfile.mkdtemp(prefix="agens-f.", dir="/tmp")
    f1, f2 = tmp + "/gate-a.txt", tmp + "/gate-b.txt"
    for f in (f1, f2): open(f, "w").write("fake")
    pick("Open file later")
    a = ui_ask("file", vt, 10)
    check("file: ui.ask reaches the host after Assumir (mode open, accept)",
          bool(a) and a.get("mode") == "open" and ".txt" in (a.get("accept") or []), a)
    check("file: a path that does not exist is bad_request", err(answer(a, paths=[tmp + "/missing.txt"])) == "bad_request")
    check("file: a directory in mode open is bad_request", err(answer(a, paths=[tmp])) == "bad_request")
    check("file: two paths in mode open is bad_request", err(answer(a, paths=[f1, f2])) == "bad_request")
    check("file: ui.answer with a dialog field (accept) is bad_request", err(answer(a, accept=True)) == "bad_request")
    check("file: ui.answer with one temp file", err(answer(a, paths=[f1])) == "ok")
    check("the page got the chosen file name", titled(vt, "file:gate-a.txt"))
    pick("Open files later")
    a = ui_ask("file", vt, 10)
    check("file: ui.ask for a multiple input is open_multiple", bool(a) and a.get("mode") == "open_multiple", a)
    check("file: ui.answer with two temp files", err(answer(a, paths=[f1, f2])) == "ok")
    check("the page got both file names", titled(vt, "files:gate-a.txt,gate-b.txt"))
    pick("Open file later")
    a = ui_ask("file", vt, 10)
    check("file: ui.answer cancel", bool(a) and err(answer(a, cancel=True)) == "ok", a)

    pick("Open select later")
    a = ui_ask("select", vt, 10)
    check("select: ui.ask reaches the host after Assumir (items, selected, x, y, width)",
          bool(a) and [i.get("label") for i in a.get("items", [])] == ["Brasil", "Chile", "Peru"] and a.get("selected") == 0
          and all(isinstance(a.get(k), (int, float)) for k in ("x", "y", "width")), a)
    check("select: the disabled item is bad_request", err(answer(a, index=1)) == "bad_request")
    check("select: an index past the list is bad_request", err(answer(a, index=3)) == "bad_request")
    check("select: ui.answer with a dialog field (accept) is bad_request", err(answer(a, accept=True)) == "bad_request")
    check("select: ui.answer with the third item", err(answer(a, index=2)) == "ok")
    check("the page got the chosen option", titled(vt, "select:pe"))
    ag.ask("control.stop")
    subprocess.run(["rm", "-rf", tmp])

# Extensions on tabs an agent controls (host.settings agent_extensions). The test extension adds " +ext"
# to the title of /ext when its document_start content script runs.
def ext_title(tab, origin=SITE, timeout=15):  # the title once /ext has loaded and settled (view.tabs), or None
    def now(): return next((x for x in c.ask("view.tabs", ato=ato).get("tabs", []) if x.get("tab") == tab), {})
    end = time.time() + timeout
    while time.time() < end:
        cur = now()
        if cur.get("url", "").startswith(origin + "/ext") and not cur.get("loading"):
            time.sleep(1.5)   # the content script changes the title at DOMContentLoaded
            return now().get("title")
        time.sleep(0.3)
    return None
MARKED, PLAIN = "Ext (test) +ext", "Ext (test)"
t = ui_tab("/ext")
title = ext_title(t)
check("extension: its content script runs on a tab without an agent", title == MARKED, title)
c.ask("view.close", tab=t)
ax = Conn()
rid = ax.send("control.start", ato=ato, reason="gate ext")
x = c.event(lambda e: e["event"] == "approval.ask", 20)
if x: c.ask("approval.answer", ask=x["ask"], answer="allow")
ext_ok = bool(x) and ax.wait(rid).get("ok")
check("extension: control.start for the extension checks", ext_ok)
if not ext_ok:
    skip("extension checks on controlled tabs", "control.start did not go through")
else:
    def controlled_tab(known=(), timeout=10):  # the host's id of the agent tab that just opened /ext
        e = c.event(lambda e: e["event"] == "view.tab" and e.get("url", "").startswith(SITE + "/ext")
                    and isinstance(e.get("control"), dict) and e.get("tab") not in known, timeout)
        return (e or {}).get("tab")
    at = ax.ask("tab.open", ato=ato, url=SITE + "/ext").get("tab")
    vt = controlled_tab()
    title = ext_title(vt) if vt else None
    check("extension: runs on a controlled tab with agent_extensions on", title == MARKED, title)
    r = c.ask("host.settings", agent_extensions=False)
    check("host.settings agent_extensions false answers the values in force",
          r.get("ok") and r.get("agent_extensions") is False and r.get("site_requests") is True, r)
    ax.ask("tab.reload", tab=at)
    title = ext_title(vt) if vt else None
    check("extension: turned off while the tab is controlled, it does not run after a reload", title == PLAIN, title)
    ax.ask("tab.navigate", tab=at, url=f"http://localhost:{PORT}/ext")
    title = ext_title(vt, f"http://localhost:{PORT}") if vt else None
    check("extension: does not run after a cross-origin navigation (another site, a new process)", title == PLAIN, title)
    at2 = ax.ask("tab.open", ato=ato, url=SITE + "/ext").get("tab")
    vt2 = controlled_tab((vt,))
    title = ext_title(vt2) if vt2 else None
    check("extension: does not run on a controlled tab opened while agent_extensions is off", title == PLAIN, title)
    c.ask("view.control", tab=vt, action="end")
    check("extension: control ends", bool(ax.event(lambda m: m["event"] == "control.stopped", 10)))
    drop(vt); c.ask("view.reload", tab=vt); tab_event(vt, lambda e: e.get("loading"), 10)   # the reload began
    title = ext_title(vt, f"http://localhost:{PORT}") if vt else None
    check("extension: runs again after control ends and the tab reloads", title == MARKED, title)
    for t in (vt, vt2):
        if t: c.ask("view.close", tab=t)
c.ask("host.settings", agent_extensions=True)
# context_menu on a tab without an agent: a right click on the page
t = ui_tab("/form"); titled(t, "Form (test)")
def events(*names): return subprocess.run([f"{OUT}/events", *names], capture_output=True, text=True).stdout.split()
for data in events("rightdown", "rightup"):
    c.send_raw({"op": "view.mouse", "tab": t, "data": data, "x": 300, "y": 300})
a = ui_ask("context_menu", t, 10)
actions = ((a or {}).get("context") or {}).get("actions", [])
check("context_menu: a right click reaches the host (actions, x, y)",
      "reload" in actions and all(isinstance((a or {}).get(k), (int, float)) for k in ("x", "y")), a)
check("context_menu: inspect (DevTools) is offered, last", actions[-1:] == ["inspect"], actions)
check("context_menu: an action that was not offered is bad_request", err(answer(a, action="copy_link")) == "bad_request")
drop(t)
check("context_menu: ui.answer reload reloads the page", err(answer(a, action="reload")) == "ok" and titled(t, "Form (test)"))
# view.inspect: only the paths that open nothing (the one that opens DevTools is EMBUTIDO_INSPECT=1, below)
check("view.inspect on an unknown tab is not_found", err(c.ask("view.inspect", tab="v999999")) == "not_found")
check("view.inspect with x but no y is bad_request", err(c.ask("view.inspect", tab=t, x=10)) == "bad_request")
c.ask("view.close", tab=t)

# Step 5.4: the element picker (view.pick, view.picked) and view.selection, on /pick, whose elements sit
# at fixed places. The clicks are serialized events, never posted; what the page did shows in its title and url.
def png_info(b64):  # (width, height, pixel(x, y) -> (r, g, b) or None) of an 8-bit RGB(A) PNG, or None
    try: data = base64.b64decode(b64 or "", validate=True)
    except ValueError: return None
    if data[:8] != b"\x89PNG\r\n\x1a\n": return None
    pos, idat, w, h, depth, color = 8, b"", 0, 0, 0, 0
    while pos + 8 <= len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8]); body = data[pos + 8:pos + 8 + n]; pos += 12 + n
        if kind == b"IHDR": w, h, depth, color = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT": idat += body
    bpp = {2: 3, 6: 4}.get(color) if depth == 8 else None
    if not bpp: return (w, h, lambda x, y: None)
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a, b, cc = (line[i - bpp] if i >= bpp else 0), prev[i], (prev[i - bpp] if i >= bpp else 0)
            p = a + b - cc
            line[i] = (line[i] + [0, a, b, (a + b) // 2, a if abs(p - a) <= abs(p - b) and abs(p - a) <= abs(p - cc)
                                  else b if abs(p - b) <= abs(p - cc) else cc][f]) & 255
        rows.append(line); prev = line
    return (w, h, lambda x, y: tuple(rows[y][x * bpp:x * bpp + 3]))
CLICK = events("move", "down", "up")
def click(tab, x, y):
    for data in CLICK: c.send_raw({"op": "view.mouse", "tab": tab, "data": data, "x": x, "y": y})
def picked(tab, timeout=10):
    return c.event(lambda e: e["event"] == "view.picked" and e.get("tab") == tab, timeout) or {}
def pick_tab(path="/pick"):  # an attached 800 x 600 tab on a fresh /pick, and its screen scale
    t = c.ask("view.open", ato=ato, url=SITE + path).get("tab", "")
    c.ask("view.attach", tab=t, width=800, height=600, scale=1)
    layer = layer_event(t, 800) or {}
    titled(t, "Pick (element)")
    return t, layer.get("scale", 1)
def shows(p, *keys): return {k: p.get(k) for k in keys}

t, scale = pick_tab()
check("view.pick without on is bad_request", err(c.ask("view.pick", tab=t)) == "bad_request")
check("view.pick.step before any pick is not_found", err(c.ask("view.pick.step", tab=t, to="parent")) == "not_found")
check("view.pick.step with a to that is not parent or child is bad_request",
      err(c.ask("view.pick.step", tab=t, to="up")) == "bad_request")
check("view.pick from a connection that is not the host is unauthorized",
      err(c2.ask("view.pick", tab=t, on=True)) == "unauthorized")
r = c.ask("view.pick", tab=t, on=True)
check("view.pick on:true arms the picker", r.get("ok"), r)
click(t, 55, 235)
p = picked(t)
check("view.picked for a click on the checkbox: selector #check, html with its tag",
      p.get("selector") == "#check" and "<input" in p.get("html", "") and 'id="check"' in p.get("html", ""),
      shows(p, "selector", "html", "cancelled"))
box = [p.get(k) for k in ("x", "y", "width", "height")]
check("view.picked box in the view's points (40, 220, 30 x 30)",
      all(isinstance(v, (int, float)) for v in box) and max(abs(a - b) for a, b in zip(box, [40, 220, 30, 30])) < 1, box)
styles = p.get("styles") or {}
check("view.picked styles: about a dozen, each a string of at most 40 characters",
      len(styles) >= 10 and bool(styles.get("display")) and all(isinstance(v, str) and len(v) <= 40 for v in styles.values()), shows(p, "styles"))
info = png_info(p.get("png"))
check("view.picked png decodes at the box's size times the screen scale",
      bool(info) and abs(info[0] - 30 * scale) <= 1 and abs(info[1] - 30 * scale) <= 1, (info and info[:2], scale))
check("the press that picked did not reach the page (the checkbox stays unchecked)", not titled(t, "checked:true", 2))

r = c.ask("view.pick", tab=t, on=True)
click(t, 230, 80)   # inside #inner (50..250 x 50..90), right of its text
p = picked(t)
check("view.pick on:true again picks again: #inner and its text",
      r.get("ok") and p.get("selector") == "#inner" and p.get("text") == "Card text", shows(p, "selector", "text"))
info = png_info(p.get("png"))
px = info[2](info[0] - 4, info[1] // 2) if info and info[0] > 4 else None
check("the picture shows the element without the highlight (its own colour, #ccddee)",
      bool(px) and max(abs(a - b) for a, b in zip(px, (204, 221, 238))) <= 6, px)
r = c.ask("view.pick.step", tab=t, to="parent")
p = picked(t)
check("view.pick.step parent: #card, with the child in its html",
      r.get("ok") and p.get("selector") == "#card" and 'id="inner"' in p.get("html", ""), shows(p, "selector"))
r = c.ask("view.pick.step", tab=t, to="child")
p = picked(t)
check("view.pick.step child: back to #inner", r.get("ok") and p.get("selector") == "#inner", shows(p, "selector"))
check("view.pick.step child of an element with no child element is not_found",
      err(c.ask("view.pick.step", tab=t, to="child")) == "not_found")
trail = []
for _ in range(2):
    c.ask("view.pick.step", tab=t, to="parent")
    trail.append(picked(t).get("selector"))
check("view.pick.step parent climbs to body and stops there (never html or head)",
      trail[-1] in ("body", "html > body") and err(c.ask("view.pick.step", tab=t, to="parent")) == "not_found", trail)
back = []
for _ in range(2):
    c.ask("view.pick.step", tab=t, to="child")
    back.append(picked(t).get("selector"))
check("view.pick.step child goes back the way parent came (body, #card, #inner)", back == ["#card", "#inner"], back)

c.ask("view.pick", tab=t, on=True)
click(t, 100, 340)
p = picked(t)
check("a password field is picked with no value in html or text",
      p.get("selector") == "#pw" and p.get("text") == "" and "pick-secret-77" not in json.dumps(p), shows(p, "selector", "html", "text"))
c.ask("view.pick", tab=t, on=True)
drop(t)
click(t, 50, 290)
p = picked(t)
check("a link is picked and the press does not follow it",
      p.get("selector") == "#go" and tab_event(t, lambda e: "/other" in e.get("url", ""), 2) is None, shows(p, "selector"))

c.ask("view.pick", tab=t, on=True)
c.send_raw({"op": "view.focus", "tab": t, "on": True})
for data, extra in zip(events("esc", "escup"), [{"commands": ["cancelOperation:"]}, {}]):
    c.send_raw({"op": "view.key", "tab": t, "data": data, **extra})
p = picked(t)
check("Escape in the page ends the picker: view.picked cancelled", p.get("cancelled") is True, p)
c.ask("view.pick", tab=t, on=True)
r = c.ask("view.pick", tab=t, on=False)
click(t, 55, 235)
check("view.pick on:false ends it: the next click acts on the page (the checkbox gets checked)",
      r.get("ok") and titled(t, "checked:true", 5))
check("view.pick on:false sends no view.picked", picked(t, 1) == {})
c.ask("view.pick", tab=t, on=True)
c.ask("view.navigate", tab=t, text=SITE + "/other")
p = picked(t)
check("navigation ends the picker: view.picked cancelled", p.get("cancelled") is True, p)
c.ask("view.close", tab=t)

t, _ = pick_tab("/pick?select")
r = c.ask("view.selection", tab=t)
check("view.selection gives what the page's script selected",
      r.get("ok") and r.get("text") == "Selected by the page" and not r.get("truncated"), r)
c.ask("view.close", tab=t)
t, _ = pick_tab()
r = c.ask("view.selection", tab=t)
check("view.selection with nothing selected is empty", r.get("ok") and r.get("text") == "", r)
c.ask("view.close", tab=t)

ap = Conn()
rid = ap.send("control.start", ato=ato, reason="gate pick")
x = c.event(lambda e: e["event"] == "approval.ask", 20)
if x: c.ask("approval.answer", ask=x["ask"], answer="allow")
if not (x and ap.wait(rid).get("ok")):
    skip("view.pick on an agent's tab", "control.start did not go through")
else:
    ap.ask("tab.open", ato=ato, url=SITE + "/pick")
    vt = (c.event(lambda e: e["event"] == "view.tab" and e.get("url", "").startswith(SITE + "/pick")
                  and isinstance(e.get("control"), dict), 10) or {}).get("tab")
    c.ask("view.attach", tab=vt, width=800, height=600, scale=1)
    check("view.pick on a tab while its agent works is denied", err(c.ask("view.pick", tab=vt, on=True)) == "denied")
    check("view.inspect on a tab while its agent works is denied", err(c.ask("view.inspect", tab=vt, x=50, y=50)) == "denied")
    check("view.inspect docked on a tab while its agent works is denied",
          err(c.ask("view.inspect", tab=vt, dock="bottom")) == "denied")
    for data in events("rightdown", "rightup"):
        c.send_raw({"op": "view.mouse", "tab": vt, "data": data, "x": 300, "y": 300})
    check("agent tab: a right click reaches no menu, so no inspect", ui_ask("context_menu", vt, 3) is None)
    c.ask("view.control", tab=vt, action="take")
    c.pump(0.5)
    for data in events("rightdown", "rightup"):
        c.send_raw({"op": "view.mouse", "tab": vt, "data": data, "x": 300, "y": 300})
    a = ui_ask("context_menu", vt, 10)
    check("after Assumir a right click offers inspect, last",
          ((a or {}).get("context") or {}).get("actions", [])[-1:] == ["inspect"], a)
    answer(a, cancel=True)
    r = c.ask("view.pick", tab=vt, on=True)
    check("after Assumir the person may pick on that tab", r.get("ok"), r)
    c.ask("view.control", tab=vt, action="give")
    p = picked(vt)
    check("the agent working again ends the picker: view.picked cancelled", p.get("cancelled") is True, p)
    ap.ask("control.stop")
    c.ask("view.close", tab=vt)

# Step 5.6: extensions for the host. The test extension has an action with a popup, a badge its
# background script sets, and an options page; it goes in from its folder and from a .crx packed
# here (CRX3, signed with a throwaway key by openssl: Chromium's own packer is the browser binary).
EXT2 = os.environ["REPO"] + "/tools/sites-teste/extensao-acao"
def varint(n):
    out = b""
    while True:
        out += bytes([(n & 0x7F) | (0x80 if n > 0x7F else 0)]); n >>= 7
        if not n: return out
def field(num, data): return varint((num << 3) | 2) + varint(len(data)) + data
def pack_crx(folder, out):
    import hashlib, io, zipfile
    key = f"{OUT}/crx-key.pem"
    subprocess.run(["openssl", "genrsa", "-out", key, "2048"], check=True, capture_output=True)
    der = subprocess.run(["openssl", "rsa", "-in", key, "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(folder)): z.write(os.path.join(folder, name), name)
    archive, crx_id = buf.getvalue(), hashlib.sha256(der).digest()[:16]
    signed = field(1, crx_id)                                         # SignedData.crx_id
    message = b"CRX3 SignedData\x00" + struct.pack("<I", len(signed)) + signed + archive
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=message, check=True, capture_output=True).stdout
    header = field(2, field(1, der) + field(2, signature)) + field(10000, signed)  # sha256_with_rsa, signed_header_data
    open(out, "wb").write(b"Cr24" + struct.pack("<II", 3, len(header)) + header + archive)
    return "".join(chr(97 + (b >> 4)) + chr(97 + (b & 15)) for b in crx_id)
def is_png(b64):
    try: return base64.b64decode(b64 or "")[:8] == b"\x89PNG\r\n\x1a\n"
    except Exception: return False
def changed(ato_id, ext, change, timeout=30):
    return c.event(lambda e: e["event"] == "extension.changed" and e.get("ato") == ato_id and e.get("extension") == ext
                   and e.get("change") == change, timeout)
def listed(ato_id, ext, **params):
    r = c.ask("extensions.list", ato=ato_id, **params)
    return next((x for x in r.get("extensions", []) if x.get("id") == ext), None)

before = {x["id"]: x for x in c.ask("atos.list").get("atos", [])}
sleeper_ok = SLEEPER in before and before[SLEEPER].get("asleep") is True
check("step 5.6: the second ato is there and asleep before the install", sleeper_ok, before.get(SLEEPER))
check("extensions.list from a connection that is not the host is unauthorized",
      err(c2.ask("extensions.list", ato=ato)) == "unauthorized")
check("extension.install with a relative path is bad_request", err(c.ask("extension.install", ato=ato, folder="tools/x")) == "bad_request")
check("extension.install with a folder that does not exist is bad_request",
      err(c.ask("extension.install", ato=ato, folder="/tmp/agens-no-such-extension")) == "bad_request")
check("extension.install crx pointing at a folder is bad_request", err(c.ask("extension.install", ato=ato, crx=EXT2)) == "bad_request")
check("extension.install with both crx and folder is bad_request",
      err(c.ask("extension.install", ato=ato, crx="/tmp/a.crx", folder=EXT2)) == "bad_request")
check("extension.install in an unknown ato is not_found", err(c.ask("extension.install", ato="Profile 404", folder=EXT2)) == "not_found")

rid = c.send("extension.install", ato=ato, folder=EXT2)
a = ui_ask("extension", None, 30)
ext_id = (a or {}).get("id", "")
offered = [x.get("id") for x in (a or {}).get("atos", [])]
check("install from a folder asks the host: ui.ask extension with ato, id, icon, from folder",
      bool(a) and a.get("ato") == ato and bool(re.fullmatch(r"[a-p]{32}", ext_id)) and is_png(a.get("icon"))
      and a.get("from") == "folder", {k: v for k, v in (a or {}).items() if k != "icon"})
check("the ask offers every ato (atos with id, name, color, installed)",
      ato in offered and SLEEPER in offered and all({"id", "name", "color", "installed"} <= set(x) for x in a.get("atos", [])),
      (a or {}).get("atos"))
check("ui.answer with an ato the ask did not offer is bad_request", err(answer(a, allow=True, atos=["Profile 404"])) == "bad_request")
check("ui.answer with atos and allow false is bad_request", err(answer(a, allow=False, atos=[SLEEPER])) == "bad_request")
check("ui.answer allow with two atos", err(answer(a, allow=True, atos=[ato, SLEEPER])) == "ok")
r = c.wait(rid, 60)
check("extension.install answers the extension once it is in", r.get("ok") and r.get("extension") == ext_id, r)
check("extension.changed installed in the asking ato", bool(changed(ato, ext_id, "installed")))
check("extension.changed installed in the sleeping ato (woken for it)", bool(changed(SLEEPER, ext_id, "installed", 60)))
mine, theirs = listed(ato, ext_id), listed(SLEEPER, ext_id)
check("extensions.list shows it in the asking ato with both atos, from folder, action and options",
      bool(mine) and set(mine.get("atos", [])) == {ato, SLEEPER} and mine.get("from") == "folder"
      and mine.get("action") is True and mine.get("options") is True and mine.get("enabled") is True, mine)
check("extensions.list shows it in the other ato too", bool(theirs) and set(theirs.get("atos", [])) == {ato, SLEEPER}, theirs)
r = c.ask("extension.icon", ato=ato, extension=ext_id)
check("extension.icon gives a PNG", r.get("ok") and is_png(r.get("png")), {k: v for k, v in r.items() if k != "png"})
x = c.event(lambda e: e["event"] == "extension.action" and e.get("extension") == ext_id and e.get("ato") == ato and e.get("badge") == "7"
              and e.get("badge_color"), 20)
check("extension.action with the badge the background script set (and its color)",
      bool(x) and x.get("badge_color") == "#D93025" and x.get("popup") is True and x.get("visible") is True, x)

t = ui_tab("/form"); titled(t, "Form (test)")
r = c.ask("extension.icon", ato=ato, extension=ext_id, tab=t)
check("extension.icon with a tab gives the action's PNG", r.get("ok") and is_png(r.get("png")))
mine = listed(ato, ext_id, tab=t)
check("extensions.list with a tab carries the action as that tab shows it (title, badge)",
      bool(mine) and mine.get("title") == "Gate action" and mine.get("badge") == "7", mine)
r = c.ask("extension.click", tab=t, extension=ext_id)
pop = r.get("popup", "")
check("extension.click gives a popup id", r.get("ok") and bool(re.fullmatch(r"v[1-9][0-9]*", pop)) and pop != t, r)
size = c.event(lambda e: e["event"] == "extension.popup" and e.get("popup") == pop, 20)
check("extension.popup with its tab, extension and a size from its page",
      bool(size) and size.get("tab") == t and size.get("extension") == ext_id and 25 <= size.get("width", 0) <= 800
      and 25 <= size.get("height", 0) <= 600, size)
w, h = (size or {}).get("width", 240), (size or {}).get("height", 120)
r = c.ask("view.attach", tab=pop, width=w, height=h, scale=1)
lp = c.event(lambda e: e["event"] == "view.layer" and e.get("tab") == pop, 20)
check("view.attach on the popup gives it a layer", r.get("ok") and bool(lp) and lp.get("context", 0) > 0, lp or r)
check("the popup is not a tab (no view.tab for it)", not any(e["event"] == "view.tab" and e.get("tab") == pop for e in c.events))
check("extension.popup.close closes it", err(c.ask("extension.popup.close", popup=pop)) == "ok"
      and bool(c.event(lambda e: e["event"] == "extension.popup.closed" and e.get("popup") == pop, 10)))
check("extension.popup.close again is not_found", err(c.ask("extension.popup.close", popup=pop)) == "not_found")
check("view.attach on the closed popup is not_found", err(c.ask("view.attach", tab=pop, width=w, height=h, scale=1)) == "not_found")
r = c.ask("extension.click", tab=t, extension=ext_id)
pop2 = r.get("popup", "")
c.ask("view.navigate", tab=t, text=SITE + "/other")
check("the tab navigating closes its popup", bool(pop2) and bool(c.event(lambda e: e["event"] == "extension.popup.closed" and e.get("popup") == pop2, 15)))

check("extension.pin on", err(c.ask("extension.pin", ato=ato, extension=ext_id, on=True)) == "ok" and bool(changed(ato, ext_id, "pinned", 10)))
check("extensions.list says pinned", (listed(ato, ext_id) or {}).get("pinned") is True)
check("extension.pin without on is bad_request", err(c.ask("extension.pin", ato=ato, extension=ext_id)) == "bad_request")
c.ask("extension.pin", ato=ato, extension=ext_id, on=False)
check("extension.enable off: extension.changed disabled",
      err(c.ask("extension.enable", ato=ato, extension=ext_id, on=False)) == "ok" and bool(changed(ato, ext_id, "disabled", 10)))
check("extensions.list says off", (listed(ato, ext_id) or {}).get("enabled") is False)
check("extension.click on an extension that is off is not_found", err(c.ask("extension.click", tab=t, extension=ext_id)) == "not_found")
check("extension.enable on: extension.changed enabled",
      err(c.ask("extension.enable", ato=ato, extension=ext_id, on=True)) == "ok" and bool(changed(ato, ext_id, "enabled", 10)))
r = c.ask("extension.options", ato=ato, extension=ext_id)
ot = r.get("tab", "")
e = tab_event(ot, lambda e: e.get("url", "").startswith(f"chrome-extension://{ext_id}/options.html"), 15) if ot else None
check("extension.options opens a tab at the extension's options page", r.get("ok") and bool(e), e or r)
if ot: c.ask("view.close", tab=ot)
check("extension.icon of an unknown extension is not_found", err(c.ask("extension.icon", ato=ato, extension="a" * 32)) == "not_found")

ax = Conn()
rid = ax.send("control.start", ato=ato, reason="gate ext click")
x = c.event(lambda e: e["event"] == "approval.ask", 20)
if x: c.ask("approval.answer", ask=x["ask"], answer="allow")
if not (x and ax.wait(rid).get("ok")):
    skip("extension.click on an agent's tab", "control.start did not go through")
else:
    c.pump(0.5)
    c.events = [e for e in c.events if e["event"] != "view.tab"]   # an earlier agent's /form tab is gone
    ax.ask("tab.open", ato=ato, url=SITE + "/form")
    vt = (c.event(lambda e: e["event"] == "view.tab" and e.get("url", "").startswith(SITE + "/form")
                  and isinstance(e.get("control"), dict), 10) or {}).get("tab")
    c.ask("host.settings", agent_extensions=False)
    r = c.ask("extension.click", tab=vt, extension=ext_id) if vt else {}
    check("extension.click on an agent's tab with agent_extensions off is denied", err(r) == "denied", f"{vt}: {r}")
    c.ask("host.settings", agent_extensions=True)
    ax.ask("control.stop")
c.ask("view.close", tab=t)

rid = c.send("extension.install", ato=ato, folder=EXT2)
a = ui_ask("extension", None, 30)
check("install again, the ask says which atos have it", bool(a) and all(x.get("installed") for x in a.get("atos", []) if x.get("id") in (ato, SLEEPER)), (a or {}).get("atos"))
answer(a, allow=False)
check("the person saying no answers extension.install denied", err(c.wait(rid, 30)) == "denied")
r = c.ask("extension.remove", ato=ato, extension=ext_id, all=True)
check("extension.remove all removes it from both atos", r.get("ok") and bool(changed(ato, ext_id, "removed", 20))
      and bool(changed(SLEEPER, ext_id, "removed", 30)) and not listed(ato, ext_id) and not listed(SLEEPER, ext_id), r)

crx = f"{OUT}/acao.crx"
try: crx_id = pack_crx(EXT2, crx)
except Exception as ex: crx_id = ""; print(f"could not pack: {ex}")
if not crx_id:
    skip("installing from a .crx", "the packer did not run")
else:
    rid = c.send("extension.install", ato=ato, crx=crx)
    a = ui_ask("extension", None, 30)
    check("install from a .crx asks the host (from file, the crx's id)", bool(a) and a.get("from") == "file" and a.get("id") == crx_id,
          {k: v for k, v in (a or {}).items() if k != "icon"})
    answer(a, allow=True)
    r = c.wait(rid, 60)
    mine = listed(ato, crx_id)
    check("the .crx installs in the asking ato only, from file", r.get("extension") == crx_id and bool(mine)
          and mine.get("from") == "file" and mine.get("atos") == [ato], mine or r)
    c.ask("extension.remove", ato=ato, extension=crx_id)
    check("extension.remove (this ato) removes the .crx's", bool(changed(ato, crx_id, "removed", 20)) and not listed(ato, crx_id))

# Nothing else may put a window on screen (only DevTools, below): each step that could is followed by
# the on-screen count, and the first window ends the run (the engine is killed) so it stays up at most a moment.
def on_screen(): return subprocess.run([f"{OUT}/onscreen", str(engine.pid)], capture_output=True, text=True).stdout.strip()
def no_window(step):
    time.sleep(1)
    n = on_screen()
    check(f"no window on screen after {step}", n == "0", f"on screen: {n}")
    if n != "0":
        engine.kill()
        print("parent: stopped at the first window on screen; failed: " + ", ".join(failed), flush=True)
        open(f"{OUT}/done", "w").write("1"); time.sleep(3600)
def others(tab, path):  # the tabs that showed up on path, other than tab
    return [e for e in c.events if e["event"] == "view.tab" and e.get("tab") != tab and e.get("url", "").startswith(SITE + path)]

c.events = [x for x in c.events if x["event"] != "view.tab"]
t = ui_tab("/popup"); titled(t, "Popup (test)")
click(t, 190, 100)
e = c.event(lambda e: e["event"] == "view.tab" and e.get("tab") != t and e.get("url", "").startswith(SITE + "/other"), 10)
check("a page's popup (window.open with features) becomes a tab of the same ato",
      bool(e) and e.get("ato") == ato and e.get("tab") != t, e)
no_window("a page's popup")
if e: c.ask("view.close", tab=e["tab"])
c.ask("view.close", tab=t)

# The test extension (extensao/) calls chrome.windows.create on /janela: a popup, then a normal window.
c.events = [x for x in c.events if x["event"] != "view.tab"]
t = ui_tab("/janela")
e = tab_event(t, lambda e: e.get("title", "").startswith("janela "), 20)
got = (e or {}).get("title", "")
check("windows.create popup and normal resolve, each a normal window with its tab",
      got == "janela popup:normal:1 normal:normal:1", got)
c.pump(1)
made = {e.get("url", "").split("from=")[-1]: e for e in others(t, "/other?from=")}
check("windows.create: both URLs reach the host as view.tab of the same ato",
      set(made) >= {"popup", "normal"} and all(x.get("ato") == ato for x in made.values()), sorted(made))
no_window("windows.create (popup and normal)")
for x in {x["tab"] for x in made.values()}: c.ask("view.close", tab=x)
c.ask("view.close", tab=t)

# Picture-in-picture is refused: no window, the page's request rejects.
t = ui_tab("/pip")
ready = titled(t, "PiP ready", 15)
click(t, 190, 90)
e = tab_event(t, lambda e: e.get("title", "").startswith("pip:"), 10)
check("video picture-in-picture after a click is refused (NotSupportedError)",
      ready and (e or {}).get("title") == "pip:NotSupportedError", (ready, (e or {}).get("title")))
no_window("video picture-in-picture")
click(t, 190, 230)
e = tab_event(t, lambda e: e.get("title", "").startswith("dpip:"), 10)
check("Document picture-in-picture is not available (documentPictureInPicture missing)",
      (e or {}).get("title") == "dpip:missing", (e or {}).get("title"))
no_window("Document picture-in-picture")
c.ask("view.close", tab=t)

# window.print(), a custom scheme and mailto:, the date and color pickers: no window, the page goes on.
t = ui_tab("/fuga"); titled(t, "Fuga (test)")
click(t, 190, 80)
check("window.print() returns at once (printing is off)", titled(t, "print:returned"))
no_window("window.print()")
click(t, 190, 180)
check("a custom-scheme link and mailto: launch nothing, the page goes on", titled(t, "scheme:alive"))
no_window("a custom-scheme link and mailto:")
check("the scheme links did not navigate the tab",
      next((x for x in c.ask("view.tabs", ato=ato).get("tabs", []) if x.get("tab") == t), {}).get("url", "").startswith(SITE + "/fuga"))
# Focused, as the host's view is when the person clicks: an unfocused page gets no picker popup at all.
c.send_raw({"op": "view.focus", "tab": t, "on": True})
click(t, 190, 280)
check("the date picker is asked for", titled(t, "date:asked"))
no_window("the date picker")
click(t, 190, 380)
check("the color picker is asked for", titled(t, "color:asked"))
no_window("the color picker")
c.ask("view.close", tab=t)
log = open(f"{OUT}/engine.log", errors="replace").read()
pickers = log.count("agens: kept off screen (embedded): a page's picker popup")
check("the date and color pickers got no window (the engine log names both)", pickers >= 2, f"{pickers} found")
print(f"info: the engine log names {log.count('agens: kept off screen') - pickers} other window(s) kept off screen by the last net", flush=True)

# Step 5.5, docked: DevTools as a view the host lays out next to the page (no window at all).
def devtools_event(tab, pred=lambda e: True, timeout=20):
    return c.event(lambda e: e["event"] == "view.devtools" and e.get("tab") == tab and pred(e), timeout)
def devtools_closed(tab, timeout=20):
    return c.event(lambda e: e["event"] == "view.devtools.closed" and e.get("tab") == tab, timeout)
t = ui_tab("/popup"); titled(t, "Popup (test)")
check("view.inspect with a dock that is not bottom, right or window is bad_request",
      err(c.ask("view.inspect", tab=t, dock="left")) == "bad_request")
check("view.devtools.dock on a tab with no DevTools is not_found", err(c.ask("view.devtools.dock", tab=t, dock="right")) == "not_found")
check("view.devtools.close on a tab with no DevTools is not_found", err(c.ask("view.devtools.close", tab=t)) == "not_found")
for data in events("rightdown", "rightup"):
    c.send_raw({"op": "view.mouse", "tab": t, "data": data, "x": 190, "y": 100})
a = ui_ask("context_menu", t, 10)
check("context_menu: inspect with a dock that is not bottom, right or window is bad_request",
      err(answer(a, action="inspect", dock="left")) == "bad_request")
check("context_menu: inspect with dock bottom answers ok", err(answer(a, action="inspect", dock="bottom")) == "ok")
e = devtools_event(t)
dv = (e or {}).get("devtools", "")
check("right-click inspect docked at the bottom: view.devtools gives a DevTools view id, dock bottom",
      bool(re.fullmatch(r"v[1-9][0-9]*", dv)) and dv != t and (e or {}).get("dock") == "bottom", e)
no_window("DevTools docked at the bottom (a view)")
c.ask("view.attach", tab=dv, width=600, height=400, scale=1)
l = layer_event(dv, 600, 30)
check("the DevTools view, attached, draws a layer (view.layer, non-zero context)", bool(l) and l.get("context", 0) > 0, l)
no_window("attaching the DevTools view")
check("the DevTools view stays out of view.tabs", dv not in [x.get("tab") for x in c.ask("view.tabs", ato=ato).get("tabs", [])])
check("an op for a page on the DevTools view is bad_request (it is only attached)",
      err(c.ask("view.navigate", tab=dv, text=SITE + "/other")) == "bad_request")
r = c.ask("view.inspect", tab=t, x=190, y=100, dock="bottom")
check("view.inspect again (open already) gives the same DevTools view", r.get("ok") and r.get("devtools") == dv, r)
r = c.ask("view.devtools.dock", tab=t, dock="right")
e = devtools_event(t, lambda e: e.get("dock") == "right")
check("view.devtools.dock right keeps the same view (view.devtools dock right)",
      r.get("ok") and r.get("devtools") == dv and (e or {}).get("devtools") == dv, (r, e))
check("view.devtools.dock with a dock that is not bottom, right or window is bad_request",
      err(c.ask("view.devtools.dock", tab=t, dock="top")) == "bad_request")
no_window("moving DevTools to the right")
# DevTools' own menus come to the host as the view's ui.ask (its items); only once its page has loaded.
time.sleep(3)
menus, with_items = [], None
for y in (40, 55, 70, 85, 100, 115, 130):   # down the Elements tree, until a node's menu comes
    for data in events("rightdown", "rightup"):
        c.send_raw({"op": "view.mouse", "tab": dv, "data": data, "x": 90, "y": y})
    m = ui_ask("context_menu", dv, 4)
    if not m: continue
    menus.append(m)
    if ((m.get("context") or {}).get("items")): with_items = m; break
    answer(m, cancel=True)
check("a right click in the DevTools view reaches the host as the view's ui.ask (items, and only editing actions)",
      bool(menus) and all(isinstance((m.get("context") or {}).get("items"), list) and
                          set((m.get("context") or {}).get("actions", [])) <= {"copy", "cut", "paste", "select_all"} for m in menus),
      menus[:1])
if with_items:
    items = with_items["context"]["items"]
    first = next((i for i in items if isinstance(i.get("id"), int) and not i.get("disabled")), None)
    check("DevTools' own entries come with an id and a label", bool(first) and bool(first.get("label")), items[:3])
    check("ui.answer item that DevTools did not offer is bad_request", err(answer(with_items, item=987654)) == "bad_request")
    check(f"ui.answer item {first.get('id') if first else None} ({(first or {}).get('label')}) runs it in DevTools (ok, the engine goes on)",
          bool(first) and err(answer(with_items, item=first["id"])) == "ok" and engine.poll() is None)
else:
    skip("DevTools' own menu entries", "no point tried had a node under it")
no_window("a right click in the DevTools view")
r = c.ask("view.devtools.close", tab=t)
e = devtools_closed(t)
check("view.devtools.close closes it: view.devtools.closed with its view",
      r.get("ok") and (e or {}).get("devtools") == dv, (r, e))
check("view.devtools.close when none is open is not_found", err(c.ask("view.devtools.close", tab=t)) == "not_found")
r = c.ask("view.inspect", tab=t)
dv2 = r.get("devtools", "")
check("view.inspect without dock opens at the side used last (a view)", r.get("ok") and bool(dv2), r)
no_window("DevTools at the side used last")
c.ask("view.close", tab=t)
e = devtools_closed(t)
check("closing the inspected tab closes its DevTools (view.devtools.closed)", (e or {}).get("devtools") == dv2, e)
no_window("closing a tab with DevTools docked")

# Allowing notifications is kept for the site (Chromium has no one-time grant for them), so this goes last.
t = ui_tab("/ui/perm?geo=0")
a = ui_ask("permission", t)
check("permission allow: notifications reach the host", bool(a) and a.get("permission") == "notifications", a)
answer(a, allow=True)
check("permission allow shows in the page title", titled(t, "perm geo=skipped notif=granted"))
c.ask("view.close", tab=t)
check("engine still has no window on screen at the end", on_screen() == "0", f"on screen: {on_screen()}")
check("engine still running", engine.poll() is None)

if os.environ.get("EMBUTIDO_INSPECT") == "1":
    # OPT-IN: this part puts a real DevTools window on screen and it takes the keyboard focus.
    t = ui_tab("/popup"); titled(t, "Popup (test)")
    r = c.ask("view.inspect", tab=t, x=190, y=100, dock="window")
    check("view.inspect dock window answers ok, with no view", r.get("ok") and "devtools" not in r, r)
    e = devtools_event(t, lambda e: e.get("dock") == "window")
    check("view.devtools says dock window", bool(e), e)
    time.sleep(3)
    check("exactly one window of the engine is on screen (DevTools)", on_screen() == "1", f"on screen: {on_screen()}")
    check("view.inspect again (already open: comes to the front) answers ok", c.ask("view.inspect", tab=t, dock="window").get("ok"))
    r = c.ask("view.devtools.dock", tab=t, dock="bottom")
    time.sleep(2)
    check("view.devtools.dock bottom takes it out of its window into a view (no window on screen)",
          r.get("ok") and r.get("devtools") == (e or {}).get("devtools") and on_screen() == "0", (r, on_screen()))
    r = c.ask("view.devtools.dock", tab=t, dock="window")
    time.sleep(3)
    check("view.devtools.dock window puts it back in a window", r.get("ok") and on_screen() == "1", (r, on_screen()))
    c.s.close()   # the host goes away: the DevTools window must go with it
    time.sleep(3)
    check("the DevTools window is gone after the host disconnects", on_screen() == "0", f"on screen: {on_screen()}")
    check("engine still running after the host left", engine.poll() is None)
else:
    print("SKIP: view.inspect opening DevTools (a real window that takes focus; EMBUTIDO_INSPECT=1 runs it)", flush=True)
print("parent: " + ("all passed" if not failed else "failed: " + ", ".join(failed)), flush=True)
open(f"{OUT}/done", "w").write("1" if failed else "0")
time.sleep(3600)   # the gate kills this process: the engine must follow
EOF

python3 "$OUT/parent.py" &
PARENT=$!
for _ in $(seq 700); do [ -f "$OUT/done" ] && break; sleep 0.5; done
ENGINE_PID="$(cat "$OUT/engine.pid" 2>/dev/null)"
PROFILE_E="$(cat "$OUT/profile" 2>/dev/null)"
fail=0
[ "$(cat "$OUT/done" 2>/dev/null)" = "0" ] || fail=1

kill -9 "$PARENT" 2>/dev/null; wait "$PARENT" 2>/dev/null
gone=""
for i in $(seq 50); do kill -0 "$ENGINE_PID" 2>/dev/null || { gone=$i; break; }; sleep 0.1; done
if [ -n "$gone" ]; then echo "PASS: the engine quit $((gone * 100)) ms after its parent was killed"
else echo "FAIL: the engine still runs 5 s after its parent was killed"; fail=1; kill "$ENGINE_PID" 2>/dev/null; fi
sleep 1; [ -n "$PROFILE_E" ] && rm -rf "$PROFILE_E"

if [ "${EMBUTIDO_STANDALONE:-0}" = 1 ]; then
  start --no-startup-window
  out="$(python3 "$REPO/tools/agensctl" raw '{"id":1,"op":"view.tabs"}' 2>&1; python3 "$REPO/tools/agensctl" raw '{"id":2,"op":"host.attach"}' 2>&1)"
  stop
  [ "$(grep -c unknown_op <<<"$out")" = 2 ] && echo "PASS: view.* and host.* are unknown_op without --agens-embedded" \
    || { echo "FAIL: view.*/host.* without --agens-embedded  [$out]"; fail=1; }
else
  echo "SKIP: view.* on a non-embedded engine (that launch is a Dock app and can take focus; EMBUTIDO_STANDALONE=1 runs it)"
fi

[ -n "$SITE_PID" ] && kill "$SITE_PID" 2>/dev/null
echo "output: $OUT"
[ "$fail" = 0 ] && echo "embutido: PASS" || { echo "embutido: FAIL"; exit 1; }
