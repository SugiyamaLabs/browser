#!/usr/bin/env bash
# Gate for "Compartilhar cookies" per ato: B and C share, A does not. Three launches on the same
# profile, because no socket op sets the flag: it is edited in Local State while the browser is
# closed. Usage: BROWSER_WORK=~/browser-work-2 tools/gates/cookies.sh
source "$(dirname "$0")/lib.sh"
SITE=http://127.0.0.1:8765
python3 "$REPO/tools/sites-teste/serve.py" 8765 >/dev/null 2>&1 & site=$!
trap 'kill $site 2>/dev/null' EXIT
sleep 1
fails=0

# lib.sh's start/stop throw the profile away; these keep it between launches.
relaunch() {
  rm -f "$AGENS_SOCK"
  "$APP" --user-data-dir="$PROFILE" --no-first-run --use-mock-keychain about:blank >>"$OUT/browser.log" 2>&1 &
  BROWSER_PID=$!
  for _ in $(seq 60); do [ -S "$AGENS_SOCK" ] && return 0; sleep 0.5; done
  echo "FAIL: no socket after 30 s"; stop; exit 1
}
quit() { kill "$BROWSER_PID" 2>/dev/null; wait "$BROWSER_PID" 2>/dev/null; sleep 1; }   # by PID; Local State is written on exit
# shared FOLDER true|false, with the browser closed.
shared() {
  python3 - "$PROFILE/Local State" "$1" "$2" <<'EOF'
import json, sys
path, ato, on = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
state = json.load(open(path))
extras = state.setdefault("agens", {}).setdefault("atos", {}).setdefault(ato, {})
if on:
    extras["shared"] = True
else:
    extras.pop("shared", None)
json.dump(state, open(path, "w"))
EOF
}
# expect ok|timeout "what it shows" agensctl args...
expect() {
  local want=$1 what=$2; shift 2
  local out got
  out="$(python3 "$REPO/tools/agensctl" "$@" 2>&1)"
  if echo "$out" | grep -q '"ok": true'; then got=ok; elif echo "$out" | grep -q "timed out"; then got=timeout; else got=error; fi
  if [ "$got" = "$want" ]; then echo "PASS $what"; else echo "FAIL $what (wanted $want, got $got): agensctl $*"; echo "$out" | head -5; fails=$((fails+1)); fi
}
logged_in() { expect "$1" "$2" --timeout "${3:-5}" login --ato "$4" --url "$SITE/login" --done "cookie:$SITE:sid"; }   # sid is httpOnly
login() { expect ok "$2" --timeout 20 login --ato "$1" --url "$SITE/login?auto=1" --done "url_prefix:$SITE/app/"; }
logout() { expect ok "$2" --timeout 20 login --ato "$1" --url "$SITE/logout" --done "url_prefix:$SITE/login"; }
new_ato() { python3 "$REPO/tools/agensctl" --timeout 20 atos create "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ato"])'; }
list_shared() {   # prints "A=false B=true C=true"
  python3 "$REPO/tools/agensctl" --timeout 10 atos list | python3 -c '
import json, sys
ids = dict(zip(sys.argv[1:4], "ABC"))
print(" ".join("%s=%s" % (ids[a["id"]], str(a.get("shared")).lower()) for a in json.load(sys.stdin)["atos"] if a["id"] in ids))' "$A" "$B" "$C"
}
check_list() { local got; got="$(list_shared)"; [ "$got" = "$1" ] && echo "PASS atos list: $got" || { echo "FAIL atos list: wanted '$1', got '$got'"; fails=$((fails+1)); }; }

# Launch 1: the three atos, none shared.
start
A="$(new_ato "Time A")"; B="$(new_ato "Time B")"; C="$(new_ato "Time C")"
echo "atos: A=$A B=$B C=$C"
[ -n "$A" ] && [ -n "$B" ] && [ -n "$C" ] || { echo "FAIL could not create the atos"; stop; exit 1; }
check_list "A=false B=false C=false"
quit

# Launch 2: B and C share.
shared "$B" true; shared "$C" true
relaunch
check_list "A=false B=true C=true"
expect ok "A open (loaded while B logs in)" --timeout 20 atos open "$A"
login "$B" "login on B"
logged_in ok "C logged in after the login on B (C loaded afterwards)" 20 "$C"
logged_in timeout "A still logged out" 5 "$A"
logout "$C" "logout on C"
sleep 1
logged_in timeout "B logged out by the logout on C" 5 "$B"
login "$B" "login on B again (C loaded now)"
sleep 1
logged_in ok "C logged in by the login on B (both loaded)" 5 "$C"
logged_in timeout "A still logged out" 5 "$A"
shot shared
quit

# Launch 3: C leaves the pool (keeps what it has).
shared "$C" false
relaunch
check_list "A=false B=true C=false"
expect ok "C open" --timeout 20 atos open "$C"
logged_in ok "C kept its login after leaving" 20 "$C"
logout "$C" "logout on C (outside the pool)"
sleep 1
logged_in ok "B still logged in" 20 "$B"
logout "$B" "logout on B"
login "$B" "new login on B"
sleep 1
logged_in timeout "C not reached by the new login on B" 5 "$C"
stop
[ "$fails" = 0 ] && echo "PASS cookies gate" || echo "FAIL cookies gate: $fails check(s)"
echo "output: $OUT"
