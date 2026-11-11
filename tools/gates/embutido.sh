#!/usr/bin/env bash
# Gate for the embedded engine (docs/protocolo.md, "host e view"). Usage:
#   BROWSER_WORK=~/browser-work-2 tools/gates/embutido.sh
# A small Python parent starts the engine with --agens-embedded on a throwaway profile and acts as
# its host on one connection (the parent always gets in); a second short launch adds
# --agens-accept-unsigned to check that switch. The engine must never put a window on
# screen nor show in the Dock, so this gate should not take focus. It never captures the screen and
# never sends system-wide input. EMBUTIDO_STANDALONE=1 also launches the engine WITHOUT the switch
# to check unknown_op: that one is a normal Dock app and can take focus, so it is opt-in.
source "$(dirname "$0")/lib.sh"
export APP OUT GATES REPO

SITE_PID=""
if ! curl -sf -o /dev/null http://127.0.0.1:8765/form; then
  python3 "$REPO/tools/sites-teste/serve.py" >"$OUT/site.log" 2>&1 &
  SITE_PID=$!
  for _ in $(seq 20); do curl -sf -o /dev/null http://127.0.0.1:8765/form && break; sleep 0.25; done
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

# A right click as the host's view sends it: the events are built and serialized, never posted.
cat >"$OUT/rightclick.swift" <<'EOF'
import CoreGraphics
import Foundation
for type in [CGEventType.rightMouseDown, .rightMouseUp] {
  let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .right)!
  print((event.data! as Data).base64EncodedString())
}
EOF
swiftc -O "$OUT/rightclick.swift" -o "$OUT/rightclick" || { echo "FAIL: could not build the right click"; exit 1; }

cat >"$OUT/parent.py" <<'EOF'
import json, os, re, select, socket, subprocess, sys, tempfile, time
APP, OUT, GATES = os.environ["APP"], os.environ["OUT"], os.environ["GATES"]
SITE = "http://127.0.0.1:8765"
failed = []

def check(name, ok, detail=""):
    print(("PASS: " if ok else "FAIL: ") + name + ("" if ok or not detail else f"  [{detail}]"), flush=True)
    if not ok: failed.append(name)

profile = tempfile.mkdtemp(prefix="agens-e.", dir="/tmp")   # short: a socket path is limited to 104 bytes
# The browser blocks geolocation and notifications by default, so a site never gets to ask. The
# permission checks need "ask" (3) on this throwaway ato.
os.makedirs(f"{profile}/Default")
with open(f"{profile}/Default/Preferences", "w") as f:
    json.dump({"profile": {"default_content_setting_values": {"geolocation": 3, "notifications": 3}}}, f)
SOCK = profile + "/agens.sock"
def launch(profile, *extra):
    log = open(f"{OUT}/engine{'-' + extra[0].strip('-') if extra else ''}.log", "w")
    p = subprocess.Popen([APP, f"--user-data-dir={profile}", "--agens-embedded", *extra,
                          "--use-mock-keychain", "--no-first-run"], stdout=log, stderr=log)
    for _ in range(60):
        if os.path.exists(profile + "/agens.sock"): return p
        time.sleep(0.5)
    print("FAIL: no socket after 30 s"); open(f"{OUT}/done", "w").write("1"); time.sleep(3600)

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
rid = agent.send("control.start", ato=ato, reason="gate")
a = c.event(lambda e: e["event"] == "approval.ask", 20)
check("control.start asks the host (approval.ask)", bool(a) and isinstance(a.get("ask"), str) and a.get("title"), a)
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
# context_menu on a tab without an agent: a right click on the page
t = ui_tab("/form"); titled(t, "Form (test)")
for data in subprocess.run([f"{OUT}/rightclick"], capture_output=True, text=True).stdout.split():
    c.send_raw({"op": "view.mouse", "tab": t, "data": data, "x": 300, "y": 300})
a = ui_ask("context_menu", t, 10)
actions = ((a or {}).get("context") or {}).get("actions", [])
check("context_menu: a right click reaches the host (actions, x, y)",
      "reload" in actions and all(isinstance((a or {}).get(k), (int, float)) for k in ("x", "y")), a)
check("context_menu: an action that was not offered is bad_request", err(answer(a, action="copy_link")) == "bad_request")
drop(t)
check("context_menu: ui.answer reload reloads the page", err(answer(a, action="reload")) == "ok" and titled(t, "Form (test)"))
c.ask("view.close", tab=t)

# Allowing notifications is kept for the site (Chromium has no one-time grant for them), so this goes last.
t = ui_tab("/ui/perm?geo=0")
a = ui_ask("permission", t)
check("permission allow: notifications reach the host", bool(a) and a.get("permission") == "notifications", a)
answer(a, allow=True)
check("permission allow shows in the page title", titled(t, "perm geo=skipped notif=granted"))
c.ask("view.close", tab=t)
check("engine still running", engine.poll() is None)
print("parent: " + ("all passed" if not failed else "failed: " + ", ".join(failed)), flush=True)
open(f"{OUT}/done", "w").write("1" if failed else "0")
time.sleep(3600)   # the gate kills this process: the engine must follow
EOF

python3 "$OUT/parent.py" &
PARENT=$!
for _ in $(seq 400); do [ -f "$OUT/done" ] && break; sleep 0.5; done
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
