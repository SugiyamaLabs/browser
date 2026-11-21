#!/usr/bin/env bash
# Configures and compiles Chromium. Incremental: out/ is kept between runs; ccache covers re-fetches.
# Usage: build.sh [official|dev] [arm64|x86_64]   (official = release flags, out/Default; dev = fast, out/Dev)
source "$(dirname "$0")/env.sh"
mode="${1:-official}"; arch="${2:-arm64}"
case "$mode" in
  official) out=out/Default; extra=/dev/null ;;
  dev) out=out/Dev; extra="$CHROMIUM_DIR/args.dev.gn" ;;
  *) echo "usage: build.sh [official|dev] [arm64|x86_64]" >&2; exit 1 ;;
esac
OUT_DIR="$SRC_DIR/$out"
[ -f "$SRC_DIR/.browser-fetched" ] || { echo "run chromium/fetch.sh first" >&2; exit 1; }

main="$UC_DIR/ungoogled-chromium"
mkdir -p "$OUT_DIR"
{
  cat "$main/flags.gn" "$UC_DIR/flags.macos.gn" "$CHROMIUM_DIR/args.gn" "$extra"
  [ "$arch" = arm64 ] && echo 'target_cpu = "arm64"' || echo 'target_cpu = "x64"'
  echo "mac_sdk_path = \"//$out/sdk/selected_macos_sdk\""   # Chromium wants the SDK inside the build dir
} > "$OUT_DIR/args.gn"
mkdir -p "$OUT_DIR/sdk" && ln -sfn "$MAC_SDK" "$OUT_DIR/sdk/selected_macos_sdk"

cd "$SRC_DIR"
[ -x out/gn ] || ./tools/gn/bootstrap/bootstrap.py -o out/gn --skip-generate-buildfiles
[ -x third_party/rust-toolchain/bin/bindgen ] || ./tools/rust/build_bindgen.py --skip-test
./out/gn gen "$out" --fail-on-unused-args
# ninja only compares mtimes: a file committed since this out/ was last built but older than that build
# (backdated with touch -t, or copied with cp -p) would leave stale objects behind; with LTO that
# was a wrong-slot virtual call and a SIGSEGV at start (official build, 18/11/2026). Fresh mtime.
built="$out/.agens-built-head"
if [ -f "$built" ]; then
  git diff --name-only "$(cat "$built")" HEAD | while read -r f; do
    if [ -f "$f" ] && [ "$f" -ot "$built" ]; then touch "$f"; fi
  done || echo "warning: could not compare with the last built commit; mtimes left as they are" >&2
fi
ninja -C "$out" chrome
git rev-parse HEAD > "$built"
ccache --show-stats | grep -iE "hits|misses" || true
echo "ok: $OUT_DIR/AgensBrowser.app"
