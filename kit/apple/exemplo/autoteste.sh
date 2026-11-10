#!/usr/bin/env bash
# Runs the embed test (docs/poc/embed.md): starts the engine hidden with a throwaway profile, runs
# the sample app's --autotest against teste.html, measures memory and kills what it started (by
# PID). The sample window stays behind the others and is never activated. Output goes to $OUT.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${ENGINE:-$HOME/browser-work-3/ungoogled-chromium-macos/build/src/out/Dev/AgensBrowser.app}"
OUT="${OUT:-$(mktemp -d /tmp/embed-out.XXXX)}"
DATA="$(mktemp -d /tmp/ae.XXXX)"
SOCK="$DATA/s"
mkdir -p "$OUT"

engine_pids() { pgrep -f -- "--user-data-dir=$DATA" || true; }
cleanup() {
  [ -n "${sample:-}" ] && kill "$sample" 2>/dev/null
  pids="$(engine_pids)"; [ -n "$pids" ] && kill $pids 2>/dev/null
  sleep 1
  pids="$(engine_pids)"; [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  rm -rf "$DATA"
}
trap cleanup EXIT

# -g -j: in the background and hidden. -n: its own instance, whatever else is running.
open -n -g -j -a "$ENGINE" --args --user-data-dir="$DATA" --agens-embed-socket="$SOCK" \
  --use-mock-keychain --no-first-run --enable-logging --log-file="$OUT/motor.log" ${ENGINE_ARGS:-} about:blank
for _ in $(seq 100); do [ -S "$SOCK" ] && break; sleep 0.2; done
[ -S "$SOCK" ] || { echo "FAIL the engine did not open the socket (see $OUT/motor.log)"; exit 1; }

"$here/build/exemplo" --autotest "$SOCK" "file://$here/teste.html" "$OUT" > "$OUT/exemplo.log" 2>&1 &
sample=$!
for _ in $(seq 240); do
  grep -q '^MEASURE' "$OUT/exemplo.log" 2>/dev/null && break
  kill -0 "$sample" 2>/dev/null || break
  sleep 0.25
done
if grep -q '^MEASURE' "$OUT/exemplo.log"; then
  {
    echo "sample app (RSS KB):"; ps -o pid=,rss=,comm= -p "$sample"
    echo "engine processes (RSS KB):"; ps -o pid=,rss=,command= -p "$(engine_pids | paste -sd, -)" | cut -c1-150
    echo "sample footprint:"; footprint "$sample" 2>/dev/null | grep -iE "phys_footprint|Footprint:" | head -3
    echo "engine footprint:"; footprint $(engine_pids) 2>/dev/null | grep -E "Footprint:"
    [ -x "$here/build/janelas" ] && { echo "windows on screen (ours only):"; "$here/build/janelas" "$sample" $(engine_pids); }
  } > "$OUT/memoria.txt" 2>&1
fi
wait "$sample" 2>/dev/null
sleep 1
main="$(engine_pids | head -1)"
if [ -n "$main" ] && kill -0 "$main" 2>/dev/null; then echo "PASS engine alive after the client left"; else echo "FAIL engine died when the client left"; fi | tee -a "$OUT/exemplo.log"
cat "$OUT/exemplo.log"
grep "agens embed" "$OUT/motor.log" 2>/dev/null
echo "output: $OUT"
grep -q '^DONE' "$OUT/exemplo.log" && ! grep -q '^FAIL' "$OUT/exemplo.log"
