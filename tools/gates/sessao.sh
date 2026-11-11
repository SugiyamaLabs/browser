#!/usr/bin/env bash
# Gate for session, renew and session.lost (docs/protocolo.md; docs/sessao.md). Usage:
#   BROWSER_WORK=~/browser-work-2 tools/gates/sessao.sh
# Like embutido.sh: a Python parent starts the engine with --agens-embedded on a throwaway profile
# and is its host, answering approval.ask itself. No window, no Dock icon, no system input, never
# captures the screen.
# The checks marked "[waits for session_read.cc]" need the real values. SESSAO_STUB=1 runs the gate
# against a build whose session_read.cc is a stub: those lines are then expected to FAIL.
source "$(dirname "$0")/lib.sh"
export APP OUT GATES REPO
export SESSAO_STUB="${SESSAO_STUB:-0}"

SITE_PID=""
if ! curl -sf -o /dev/null http://127.0.0.1:8765/form; then
  python3 "$REPO/tools/sites-teste/serve.py" >"$OUT/site.log" 2>&1 &
  SITE_PID=$!
  for _ in $(seq 20); do curl -sf -o /dev/null http://127.0.0.1:8765/form && break; sleep 0.25; done
fi

cat >"$OUT/parent.py" <<'EOF'
import json, os, select, socket, subprocess, tempfile, time
APP, OUT = os.environ["APP"], os.environ["OUT"]
STUB = os.environ.get("SESSAO_STUB", "0") == "1"
SITE = "http://127.0.0.1:8765"
# The test site's fake values (tools/sites-teste/README.md).
FAKE = {"d": "fake-d-cookie-456", "sid": "sid-fake-123", "token": "fake-local-token-789",
        "Authorization": "Bearer test-bearer-123"}
failed, value_failed, value_passed = [], [], []

def check(name, ok, detail="", value=False):
    label = ("[waits for session_read.cc] " if value else "") + name
    print(("PASS: " if ok else "FAIL: ") + label + ("" if ok or not detail else f"  [{detail}]"), flush=True)
    if value: (value_passed if ok else value_failed).append(name)
    elif not ok: failed.append(name)

profile = tempfile.mkdtemp(prefix="agens-s.", dir="/tmp")   # short: a socket path is limited to 104 bytes
SOCK = profile + "/agens.sock"
log = open(f"{OUT}/engine.log", "w")
engine = subprocess.Popen([APP, f"--user-data-dir={profile}", "--agens-embedded", "--use-mock-keychain", "--no-first-run"],
                          stdout=log, stderr=log)
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
    def send(self, op, **params):
        self.n += 1; self.s.sendall((json.dumps({"id": self.n, "op": op, **params}) + "\n").encode()); return self.n
    def pump(self, timeout):
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
    def wait(self, rid, timeout=40):
        end = time.time() + timeout
        while rid not in self.replies:
            if time.time() > end: return {"ok": False, "error": "timeout"}
            if not self.pump(0.5): return {"ok": False, "error": "closed"}
        return self.replies.pop(rid)
    def ask(self, op, timeout=40, **params):
        return self.wait(self.send(op, **params), timeout)
    def event(self, pred, timeout=20):
        end = time.time() + timeout
        while True:
            for i, e in enumerate(self.events):
                if pred(e): return self.events.pop(i)
            if time.time() > end or not self.pump(0.5): return None

def err(r): return r.get("error") if not r.get("ok") else "ok"
def need(*specs): return [{"type": t, "from": SITE, "name": n} for t, n in specs]

host = Conn()
check("hello", host.ask("hello", client="sessao-gate").get("ok"))
check("host.attach", host.ask("host.attach").get("ok"))
ato = (host.ask("atos.list").get("atos") or [{}])[0].get("id")
print(f"ato: {ato}")

def approval(timeout=20): return host.event(lambda e: e["event"] == "approval.ask", timeout)
def answer(a, how): return host.ask("approval.answer", ask=(a or {}).get("ask", "none"), answer=how)

# Log the ato in on the test site, as a person would (the host's own tab).
t = host.ask("view.open", ato=ato, url=SITE + "/login?auto=1").get("tab")
ok = bool(host.event(lambda e: e["event"] == "view.tab" and e.get("tab") == t and e.get("url", "").startswith(SITE + "/app/")
                     and not e.get("loading"), 20))
check("the ato logs in on the test site", ok)
time.sleep(1)   # the app page stores its localStorage key on load
host.ask("view.close", tab=t)

agent = Conn()
agent.ask("hello", client="sessao-agent")

# Bad requests and unknown ato: answered at once, no sheet.
D, SID, TOKEN, AUTH = ("cookie", "d"), ("cookie", "sid"), ("localStorage", "token"), ("header", "Authorization")
for name, op, params, want in [
        ("session without need", "session", dict(ato=ato, reason="x"), "bad_request"),
        ("session without reason", "session", dict(ato=ato, need=need(D)), "bad_request"),
        ("session with a control character in reason", "session", dict(ato=ato, reason="a\nb", need=need(D)), "bad_request"),
        ("session with a reason past 1024 characters", "session", dict(ato=ato, reason="r" * 1025, need=need(D)), "bad_request"),
        ("session with a bidi control in a name", "session", dict(ato=ato, reason="x", need=need(("cookie", "a\u202eb"))), "bad_request"),
        ("session with an unknown type", "session", dict(ato=ato, reason="x", need=[{"type": "password", "from": SITE, "name": "p"}]), "bad_request"),
        ("session with a path in from", "session", dict(ato=ato, reason="x", need=[{"type": "cookie", "from": SITE + "/app", "name": "d"}]), "bad_request"),
        ("session asking for the Cookie header", "session", dict(ato=ato, reason="x", need=[{"type": "header", "from": SITE, "name": "Cookie"}]), "bad_request"),
        ("session with page items of 5 origins", "session",
         dict(ato=ato, reason="x", need=[{"type": "localStorage", "from": f"https://o{i}.invalid", "name": "k"} for i in range(5)]), "bad_request"),
        ("renew without need", "renew", dict(ato=ato), "bad_request"),
        ("session for an unknown ato", "session", dict(ato="Profile 999", reason="x", need=need(D)), "not_found"),
        ("renew for an unknown ato", "renew", dict(ato="Profile 999", need=need(D)), "not_found"),
        ("renew never approved is unauthorized", "renew", dict(ato=ato, need=need(D)), "unauthorized")]:
    r = agent.ask(op, **params)
    check(f"{name}: {want}", err(r) == want, r)
check("none of those showed a sheet", approval(1) is None)

# The sheet: title, reason, ato, one line per item; deny.
rid = agent.send("session", ato=ato, reason="Gate sessao", need=need(D, TOKEN))
a = approval()
title, detail = (a or {}).get("title", ""), (a or {}).get("detail", "")
check("session asks the host (approval.ask)", bool(a), a)
check("the title is 'Entregar ao <app>: <first item>…'",
      title.startswith("Entregar ao ") and title.endswith(": cookie d de http://127.0.0.1:8765…"), title)
check("the detail has the reason, the ato and one line per item",
      detail.startswith("Gate sessao\n\nDo ato ") and "\ncookie d de http://127.0.0.1:8765" in detail
      and "\nlocalStorage token de http://127.0.0.1:8765" in detail, detail)
check("no 'Permitir sempre' for an unsigned client", bool(a) and a.get("offer_always") is False, a)
check("the session approval carries its parts (kind, ato, ato_name, reason, items; no shares_with)",
      bool(a) and a.get("kind") == "session" and a.get("ato") == ato and bool(a.get("ato_name"))
      and a.get("reason") == "Gate sessao" and "shares_with" not in a
      and a.get("items") == [{"type": "cookie", "from": SITE, "name": "d"}, {"type": "localStorage", "from": SITE, "name": "token"}], a)
answer(a, "deny")
check("deny: denied", err(agent.wait(rid)) == "denied")

# An approved item that does not exist: not_found, naming it.
rid = agent.send("session", ato=ato, reason="x", need=need(("cookie", "never-set-gate")))
answer(approval(), "allow")
r = agent.wait(rid)
check("an approved cookie that does not exist: not_found naming it",
      err(r) == "not_found" and "never-set-gate" in r.get("message", ""), r)

# "always" from an unsigned client counts as allow, and is not remembered.
rid = agent.send("session", ato=ato, reason="x", need=need(D))
answer(approval(), "always")
agent.wait(rid)
other = Conn()
rid = other.send("session", ato=ato, reason="x", need=need(D))
a = approval(10)
check("'always' from an unsigned client is not remembered (the sheet comes again)", bool(a))
answer(a, "deny"); other.wait(rid)
check("renew of items approved on another connection is unauthorized", err(other.ask("renew", ato=ato, need=need(D))) == "unauthorized")

# renew on the connection that got the approval: no sheet.
r = agent.ask("renew", ato=ato, need=need(D))
check("renew after session on the same connection shows no sheet", approval(2) is None and err(r) in ("ok", "needs_login"), r)
check("renew of another set of items is unauthorized", err(agent.ask("renew", ato=ato, need=need(D, SID))) == "unauthorized")

# Caps: 4 in flight per connection (waiting on the sheet counts).
busy = Conn()
rids = [busy.send("session", ato=ato, reason="cap", need=need(D)) for _ in range(4)]
time.sleep(0.5)
check("a 5th session in flight on one connection is bad_request", err(busy.ask("session", ato=ato, reason="cap", need=need(D), timeout=5)) == "bad_request")
results = []
for rid in rids:
    while rid not in busy.replies:
        if (x := approval(1)): answer(x, "deny")
        if not busy.pump(0.2): break
    results.append(err(busy.replies.pop(rid, {})))
check("the 4 waiting get denied", results == ["denied"] * 4, results)

# A connection that closes with its sheet up: the answer goes nowhere, the engine is fine.
gone = Conn()
gone.send("session", ato=ato, reason="gone", need=need(D))
a = approval()
gone.s.close(); time.sleep(0.5)
check("answering the sheet of a closed connection", err(answer(a, "allow")) in ("ok", "not_found"))

# --- The real values: these wait for session_read.cc.
ITEMS = need(D, SID, TOKEN, AUTH)
def values(r): return {i.get("name"): i.get("value") for i in r.get("items", [])} if r.get("ok") else {}
def shaped(r): return r.get("ok") and [(i.get("type"), i.get("from"), i.get("name")) for i in r["items"]] == [(i["type"], i["from"], i["name"]) for i in ITEMS]
rid = agent.send("session", ato=ato, reason="valores", need=ITEMS)
answer(approval(), "allow")
r = agent.wait(rid)
v = values(r)
check("session answers ok with type, from, name, value per item, in order", bool(shaped(r)), err(r), value=True)
check("session: cookie d", v.get("d") == FAKE["d"], err(r), value=True)
check("session: httpOnly cookie sid", v.get("sid") == FAKE["sid"], err(r), value=True)
check("session: localStorage token", v.get("token") == FAKE["token"], err(r), value=True)
check("session: header Authorization from the page's own request", v.get("Authorization") == FAKE["Authorization"], err(r), value=True)
r = agent.ask("renew", ato=ato, need=ITEMS)
renewed = values(r) == FAKE
check("renew gives the same four values again, no sheet", renewed and approval(1) is None, err(r), value=True)

# The site logs out: the cookies handed out are lost.
t = host.ask("view.open", ato=ato, url=SITE + "/logout").get("tab")
host.event(lambda e: e["event"] == "view.tab" and e.get("tab") == t and e.get("url", "").startswith(SITE + "/login") and not e.get("loading"), 20)
host.ask("view.close", tab=t)
lost = []
for _ in range(2):
    e = agent.event(lambda e: e["event"] == "session.lost", 3 if STUB else 10)
    if e: lost.append(e)
check("session.lost {ato, from, name} for d and sid after the site's logout",
      sorted((e.get("ato"), e.get("from"), e.get("name")) for e in lost) == [(ato, SITE, "d"), (ato, SITE, "sid")], lost, value=True)
check("session.lost carries no value", all(set(e) == {"event", "ato", "from", "name"} for e in lost), lost)
r = agent.ask("renew", ato=ato, need=ITEMS)
check("renew after the logout is needs_login (and was ok before it)", renewed and err(r) == "needs_login", err(r), value=True)

host.pump(0.5); agent.pump(0.5)
engine_log = open(f"{OUT}/engine.log", errors="replace").read()
leaks = sum(s in engine_log for s in FAKE.values())   # a count: never print them
check("the engine log has none of the values", leaks == 0, f"{leaks} found")
check("engine still running", engine.poll() is None)

print()
if STUB:
    print("SESSAO_STUB=1: session_read.cc is the stub. Expected failures while it is in place:")
    for name in value_failed: print("  expected: " + name)
    if value_passed:
        print("note: these value checks passed; if session_read.cc is written, run with SESSAO_STUB=0:")
        for name in value_passed: print("  passed: " + name)
    bad = failed
else:
    bad = failed + value_failed
print("parent: " + ("all passed" if not bad else "failed: " + ", ".join(bad)), flush=True)
open(f"{OUT}/done", "w").write("1" if bad else "0")
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
for _ in $(seq 50); do kill -0 "$ENGINE_PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$ENGINE_PID" 2>/dev/null && { echo "FAIL: the engine still runs 5 s after its parent was killed"; fail=1; kill "$ENGINE_PID"; }
sleep 1; [ -n "$PROFILE_E" ] && rm -rf "$PROFILE_E"
[ -n "$SITE_PID" ] && kill "$SITE_PID" 2>/dev/null
echo "output: $OUT"
[ "$fail" = 0 ] && echo "sessao: PASS${SESSAO_STUB:+ (SESSAO_STUB=$SESSAO_STUB)}" || { echo "sessao: FAIL"; exit 1; }
