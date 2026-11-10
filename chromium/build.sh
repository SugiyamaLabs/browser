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
ninja -C "$out" chrome
ccache --show-stats | grep -iE "hits|misses" || true
echo "ok: $OUT_DIR/Agens.app"
