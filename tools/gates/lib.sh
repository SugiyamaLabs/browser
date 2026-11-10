# Sourced by the gate scripts. Starts the dev build on a throwaway profile with the socket open to
# unsigned clients, and gives helpers to drive it. A gate opens a browser window: it can take focus.
# Never captures the screen, only the browser's own windows; never sends system-wide input.
set -uo pipefail
GATES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$GATES/../.." && pwd)"
BROWSER_WORK="${BROWSER_WORK:-$HOME/browser-work}"
APP="$BROWSER_WORK/ungoogled-chromium-macos/build/src/out/Dev/AgensBrowser.app/Contents/MacOS/AgensBrowser"
OUT="${OUT:-$(mktemp -d /tmp/agens-gate-out.XXXXXX)}"
mkdir -p "$OUT"
[ -x "$GATES/winids" ] || swiftc -O "$GATES/winids.swift" -o "$GATES/winids"

# start [extra browser args...]: env vars set by the caller (e.g. AGENS_BRIDGE_TEST_ANSWER=allow) reach the browser.
start() {
  PROFILE="$(mktemp -d /tmp/agens-g.XXXXXX)"   # short: a socket path is limited to 104 bytes
  echo '{"agens":{"bridge":{"accept_unsigned":true}}}' > "$PROFILE/Local State"
  export AGENS_SOCK="$PROFILE/agens.sock"
  "$APP" --user-data-dir="$PROFILE" --no-first-run --use-mock-keychain "$@" about:blank >"$OUT/browser.log" 2>&1 &
  BROWSER_PID=$!
  for _ in $(seq 60); do [ -S "$AGENS_SOCK" ] && return 0; sleep 0.5; done
  echo "FAIL: no socket after 30 s"; stop; exit 1
}
stop() { kill "$BROWSER_PID" 2>/dev/null; wait "$BROWSER_PID" 2>/dev/null; sleep 1; rm -rf "$PROFILE"; }   # by PID only
ctl() { echo "\$ agensctl $*"; python3 "$REPO/tools/agensctl" "$@"; echo "exit=$?"; }
shot() { local i=0 w; for w in $("$GATES/winids" "$BROWSER_PID"); do i=$((i+1)); screencapture -x -l "$w" "$OUT/$1-$i.png"; done; echo "captured $i window(s): $OUT/$1-*.png"; }
