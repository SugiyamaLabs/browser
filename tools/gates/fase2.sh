#!/usr/bin/env bash
# Gate for phase 2, the part that exists: login. Usage: BROWSER_WORK=~/browser-work-2 tools/gates/fase2.sh
source "$(dirname "$0")/lib.sh"
SITE=http://127.0.0.1:8765
python3 "$REPO/tools/sites-teste/serve.py" 8765 >/dev/null 2>&1 & site=$!
trap 'kill $site 2>/dev/null' EXIT
sleep 1
start
check() { local want=$1; shift; out="$(python3 "$REPO/tools/agensctl" --timeout 20 "$@" 2>&1)"; echo "$out" | grep -q "$want" && echo "PASS $want: agensctl $*" || { echo "FAIL wanted $want: agensctl $*"; echo "$out" | head -5; }; }
check '"ok": true' login --ato Default --url "$SITE/login?auto=1" --done "url_prefix:$SITE/app/"
check '"ok": true' login --ato Default --url "$SITE/login" --done "cookie:$SITE:d"          # already logged in: ends at once
check '"ok": true' login --ato Default --url "$SITE/logout" --done "url_prefix:$SITE/login"   # logs out again
check bad_request login --ato Default --url "file:///etc/hosts" --done "url_prefix:file:///"
check not_found login --ato Nope --url "$SITE/login" --done "url_prefix:$SITE/app/"
# The done rule must be about the site it opens (else it tells whether the person is logged in elsewhere).
check bad_request login --ato Default --url "$SITE/login" --done "cookie:http://localhost:8765:d"
check bad_request login --ato Default --url "$SITE/login" --done "url_prefix:http://localhost:8765/app/"
# session and renew are in tools/gates/sessao.sh (hidden engine): here they would open the approval sheet and wait.
sleep 1; shot after-login      # look: no login tab left open
stop
echo "output: $OUT"
