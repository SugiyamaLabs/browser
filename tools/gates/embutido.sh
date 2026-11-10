#!/usr/bin/env bash
# Gate for the embedded engine (docs/protocolo.md, "host e view"). Usage:
#   BROWSER_WORK=~/browser-work-2 tools/gates/embutido.sh
# A small Python parent starts the engine with --agens-embedded --agens-accept-unsigned on a
# throwaway profile and acts as its host on one connection. The engine must never put a window on
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

cat >"$OUT/parent.py" <<'EOF'
import json, os, re, select, socket, subprocess, sys, tempfile, time
APP, OUT, GATES = os.environ["APP"], os.environ["OUT"], os.environ["GATES"]
SITE = "http://127.0.0.1:8765"
failed = []

def check(name, ok, detail=""):
    print(("PASS: " if ok else "FAIL: ") + name + ("" if ok or not detail else f"  [{detail}]"), flush=True)
    if not ok: failed.append(name)

profile = tempfile.mkdtemp(prefix="agens-e.", dir="/tmp")   # short: a socket path is limited to 104 bytes
SOCK = profile + "/agens.sock"
log = open(f"{OUT}/engine.log", "w")
engine = subprocess.Popen([APP, f"--user-data-dir={profile}", "--agens-embedded", "--agens-accept-unsigned",
                           "--use-mock-keychain", "--no-first-run"], stdout=log, stderr=log)
open(f"{OUT}/engine.pid", "w").write(str(engine.pid))
open(f"{OUT}/profile", "w").write(profile)
for _ in range(60):
    if os.path.exists(SOCK): break
    time.sleep(0.5)
else:
    print("FAIL: no socket after 30 s"); open(f"{OUT}/done", "w").write("1"); time.sleep(3600)

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

# host.attach from a process that is not the parent.
other = subprocess.run([sys.executable, "-c", f"""
import json, socket
s = socket.socket(socket.AF_UNIX); s.connect({SOCK!r})
s.sendall(b'{{"id":1,"op":"host.attach"}}\\n'); print(s.makefile().readline())"""], capture_output=True, text=True)
try: r = json.loads(other.stdout)
except ValueError: r = {"ok": False, "error": other.stdout + other.stderr}
check("host.attach from another process is unauthorized", err(r) == "unauthorized", r)

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
            {"op": "view.mouse.leave", "tab": "nope"}]:
    c.send_raw(bad)
c.send_raw({"op": "view.focus", "tab": t1, "on": True})
r = c.ask("hello")
check("garbage input is ignored and the connection survives", r.get("ok") and None not in c.replies, c.replies.get(None))

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
