#!/usr/bin/env bash
# Manual test of what only a person can check: the cookie switch and its sheets, the control sheet,
# the pill with Assumir, Devolver and the stop bubble. Saved passwords filling in are not covered. Run it in your own terminal and follow the steps it prints.
# Usage: BROWSER_WORK=~/browser-work-2 tools/gates/manual.sh
source "$(dirname "$0")/lib.sh"
unset AGENS_BRIDGE_TEST_ANSWER   # the sheets must show
python3 "$REPO/tools/sites-teste/serve.py" 8765 >/dev/null 2>&1 & site=$!
trap 'kill $site 2>/dev/null; stop 2>/dev/null' EXIT
sleep 1
start
python3 "$REPO/tools/agensctl" atos create "Time B" --cor blue >/dev/null
python3 "$REPO/tools/agensctl" atos create "Time C" --cor teal >/dev/null
python3 "$GATES/manual_controle.py"
