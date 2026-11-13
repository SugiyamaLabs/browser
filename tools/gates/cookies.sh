#!/usr/bin/env bash
# Gate for "Compartilhar cookies" per ato: B and C share, A does not. Four launches on the same
# profile, because no socket op sets the flag: it is edited in Local State while the browser is
# closed. Atos log in and out by opening the test site with `atos open`, and the site itself says
# whether a request carried the login cookie (/whoami, /seen).
# Usage: BROWSER_WORK=~/browser-work-4 tools/gates/cookies.sh
source "$(dirname "$0")/lib.sh"
SITE=http://127.0.0.1:8765
python3 "$REPO/tools/sites-teste/serve.py" 8765 >/dev/null 2>&1 & site=$!
trap 'kill $site 2>/dev/null' EXIT
sleep 1
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails+1)); }

# lib.sh's start/stop throw the profile away; these keep it between launches.
relaunch() {
  rm -f "$AGENS_SOCK"
  "$APP" --user-data-dir="$PROFILE" --no-first-run --use-mock-keychain about:blank >>"$OUT/browser.log" 2>&1 &
  BROWSER_PID=$!
  for _ in $(seq 60); do [ -S "$AGENS_SOCK" ] && return 0; sleep 0.5; done
  echo "FAIL: no socket after 30 s"; stop; exit 1
}
quit() { kill "$BROWSER_PID" 2>/dev/null; wait "$BROWSER_PID" 2>/dev/null; sleep 1; }   # by PID; Local State is written on exit
# With the browser closed: state shared FOLDER true|false, or state reopen FOLDER (the only ato
# whose windows come back at the next launch, so the others start asleep).
state() {
  python3 - "$PROFILE/Local State" "$@" <<'EOF'
import json, sys
path, what, ato = sys.argv[1], sys.argv[2], sys.argv[3]
state = json.load(open(path))
if what == "shared":
    extras = state.setdefault("agens", {}).setdefault("atos", {}).setdefault(ato, {})
    if sys.argv[4] == "true":
        extras["shared"] = True
    else:
        extras.pop("shared", None)
else:
    profile = state.setdefault("profile", {})
    profile["last_active_profiles"] = [ato]
    profile["last_used"] = ato
json.dump(state, open(path, "w"))
EOF
}
ctl() { python3 "$REPO/tools/agensctl" --timeout 20 "$@"; }
open_in() { ctl atos open "$1" "$2" >/dev/null || fail "atos open $1 $2"; }
# true|false: whether ATO sends the login cookie (sid, httpOnly) to the site right now.
logged() {
  local tag="t$SECONDS-$RANDOM$RANDOM"   # runs in $(...): no counter survives, so a random tag
  open_in "$1" "$SITE/whoami?tag=$tag" >&2
  for _ in $(seq 40); do
    local seen; seen="$(curl -s "$SITE/seen?tag=$tag")"
    case "$seen" in *'"seen": true, "logged_in": true'*) echo true; return;; *'"seen": true'*) echo false; return;; esac
    sleep 0.25
  done
  echo none
}
# eventually ATO true|false "what": polls up to ~15 s (a mirrored change or a merge takes a moment).
eventually() {
  local got
  for _ in $(seq 10); do got="$(logged "$1")"; [ "$got" = "$2" ] && { pass "$3"; return; }; sleep 1; done
  fail "$3 (wanted logged in=$2, got $got)"
}
# still ATO true|false "what": after a settle time, so a wrong mirror would have arrived.
still() { sleep 3; local got; got="$(logged "$1")"; [ "$got" = "$2" ] && pass "$3" || fail "$3 (wanted logged in=$2, got $got)"; }
login_on() { open_in "$1" "$SITE/login?auto=1"; eventually "$1" true "$2"; }
logout_on() { open_in "$1" "$SITE/logout"; eventually "$1" false "$2"; }
new_ato() { ctl atos create "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ato"])'; }
# check_list "A=false B=true C=true" [asleep_letter]: shared per ato, and that one ato is asleep.
check_list() {
  local got
  got="$(ctl atos list | python3 -c '
import json, sys
ids = dict(zip(sys.argv[1:4], "ABC"))
atos = [a for a in json.load(sys.stdin)["atos"] if a["id"] in ids]
print(" ".join("%s=%s" % (ids[a["id"]], str(a.get("shared")).lower()) for a in atos), end="")
print("".join(" %s:asleep" % ids[a["id"]] for a in atos if a.get("asleep") and ids[a["id"]] == sys.argv[4]))' "$A" "$B" "$C" "${2:-}")"
  local want="$1"; [ -n "${2:-}" ] && want="$want $2:asleep"
  [ "$got" = "$want" ] && pass "atos list: $got" || fail "atos list: wanted '$want', got '$got'"
}

# Launch 1: the three atos, none shared.
start
A="$(new_ato "Time A")"; B="$(new_ato "Time B")"; C="$(new_ato "Time C")"
echo "atos: A=$A B=$B C=$C"
[ -n "$A" ] && [ -n "$B" ] && [ -n "$C" ] || { echo "FAIL could not create the atos"; stop; exit 1; }
check_list "A=false B=false C=false"
quit

# Launch 2: B and C share. B logs in while C sleeps, then both loaded.
state shared "$B" true; state shared "$C" true; state reopen Default
relaunch
check_list "A=false B=true C=true" C
open_in "$A" "$SITE/other"   # A loaded while B logs in
login_on "$B" "login on B"
eventually "$C" true "C logged in after the login on B (C loaded afterwards)"
still "$A" false "A still logged out"
logout_on "$C" "logout on C"
eventually "$B" false "B logged out by the logout on C"
login_on "$B" "login on B again (C loaded now)"
eventually "$C" true "C logged in by the login on B (both loaded)"
still "$A" false "A still logged out"
shot shared
quit

# Launch 3: B logs out while C sleeps; when C loads, the logout must not come back.
state reopen "$B"
relaunch
check_list "A=false B=true C=true" C
logout_on "$B" "logout on B while C sleeps"
eventually "$C" false "C logged out too once it loads"
still "$B" false "B stays logged out"
login_on "$B" "login on B (both loaded)"
eventually "$C" true "C logged in by it"
quit

# Launch 4: C leaves the pool (keeps what it has).
state shared "$C" false
relaunch
check_list "A=false B=true C=false"
still "$C" true "C kept its login after leaving"
logout_on "$C" "logout on C (outside the pool)"
still "$B" true "B still logged in"
logout_on "$B" "logout on B"
login_on "$B" "new login on B"
still "$C" false "C not reached by the new login on B"
stop
grep -q -e "sid-fake-123" -e "fake-d-cookie-456" "$OUT/browser.log" && fail "a cookie value is in the browser log" || pass "no cookie value in the browser log"
[ "$fails" = 0 ] && echo "PASS cookies gate" || echo "FAIL cookies gate: $fails check(s)"
echo "output: $OUT"
