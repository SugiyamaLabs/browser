#!/usr/bin/env bash
# Gate for phase 1 (socket, hello, atos). Usage: BROWSER_WORK=~/browser-work-2 tools/gates/fase1.sh
source "$(dirname "$0")/lib.sh"
start
echo "socket: $(stat -f '%Sp' "$AGENS_SOCK") (expect srw-------)"
ctl hello
ctl atos create "Cliente A" --cor blue --tag t1
ctl atos rename "Profile 1" "Cliente B"
ctl atos color "Profile 1" teal
ctl atos color "Profile 1" nope            # expect bad_request, exit 1
ctl atos rename "../x" "y"                 # expect not_found, exit 1
ctl raw '{"id":9,"op":"nope"}'             # expect unknown_op
ctl atos list
python3 "$GATES/fase1_limits.py"
shot sidebar                               # look: the new ato in the foot of the sidebar, teal
ctl atos open "Profile 1" "http://127.0.0.1:8765/form"
sleep 2; shot open                         # look: a second window, ato "Cliente B"
sock="$AGENS_SOCK"; stop
[ -e "$sock" ] && echo "FAIL: socket still there after quit" || echo "socket removed on quit"
echo "output: $OUT"
