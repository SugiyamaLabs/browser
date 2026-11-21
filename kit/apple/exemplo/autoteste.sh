#!/usr/bin/env bash
# Runs the embed test (docs/kit.md): the sample app starts the engine through BrowserKit (hidden,
# embedded, throwaway profile), runs its --autotest against teste.html, and this script measures
# memory and kills what is left (by PID). The sample window stays behind the others and is never
# activated. Output goes to $OUT. ENGINE is the engine's .app or its executable; ENGINE_ARGS adds
# engine arguments.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${ENGINE:-$HOME/browser-work-3/ungoogled-chromium-macos/build/src/out/Dev/AgensBrowser.app}"
OUT="${OUT:-$(mktemp -d /tmp/embed-out.XXXX)}"
DATA="$(mktemp -d /tmp/ae.XXXX)"  # short on purpose: the socket path must fit in 104 bytes
mkdir -p "$OUT"
if [ -d "$ENGINE" ]; then
  executable="$ENGINE/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ENGINE/Contents/Info.plist")"
else
  executable="$ENGINE"
fi
[ -x "$executable" ] || { echo "FAIL no engine executable at $executable"; exit 1; }

engine_pids() { pgrep -f -- "--user-data-dir=$DATA" || true; }
cleanup() {
  [ -n "${sample:-}" ] && kill "$sample" 2>/dev/null
  pids="$(engine_pids)"; [ -n "$pids" ] && kill $pids 2>/dev/null
  sleep 1
  pids="$(engine_pids)"; [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  rm -rf "$DATA"
}
trap cleanup EXIT

"$here/build/exemplo" --autotest "$executable" "$DATA" "file://$here/teste.html" "$OUT" \
  --agens-accept-unsigned --use-mock-keychain --no-first-run --enable-logging --log-file="$OUT/motor.log" \
  ${ENGINE_ARGS:-} > "$OUT/exemplo.log" 2>&1 &
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
sleep 2
# The kit stops the engine when its app quits: nothing of it should be left.
if [ -z "$(engine_pids)" ]; then echo "PASS engine stopped with the app"; else echo "FAIL engine still running after the app quit"; fi | tee -a "$OUT/exemplo.log"
cat "$OUT/exemplo.log"
grep "agens embed" "$OUT/motor.log" 2>/dev/null
echo "output: $OUT"
grep -q '^DONE' "$OUT/exemplo.log" && ! grep -q '^FAIL' "$OUT/exemplo.log"
