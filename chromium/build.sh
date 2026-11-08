#!/usr/bin/env bash
# Configures and compiles Chromium. Incremental: out/ is kept between runs; ccache covers re-fetches.
source "$(dirname "$0")/env.sh"
arch="${1:-arm64}"
[ -f "$SRC_DIR/.browser-fetched" ] || { echo "run chromium/fetch.sh first" >&2; exit 1; }

main="$UC_DIR/ungoogled-chromium"
mkdir -p "$OUT_DIR"
{
  cat "$main/flags.gn" "$UC_DIR/flags.macos.gn" "$CHROMIUM_DIR/args.gn"
  [ "$arch" = arm64 ] && echo 'target_cpu = "arm64"' || echo 'target_cpu = "x64"'
  echo 'mac_sdk_path = "//out/Default/sdk/selected_macos_sdk"'   # Chromium wants the SDK inside the build dir
} > "$OUT_DIR/args.gn"
mkdir -p "$OUT_DIR/sdk" && ln -sfn "$MAC_SDK" "$OUT_DIR/sdk/selected_macos_sdk"

cd "$SRC_DIR"
[ -x out/Default/gn ] || ./tools/gn/bootstrap/bootstrap.py -o out/Default/gn --skip-generate-buildfiles
[ -x third_party/rust-toolchain/bin/bindgen ] || ./tools/rust/build_bindgen.py --skip-test
./out/Default/gn gen out/Default --fail-on-unused-args
ninja -C out/Default chrome
ccache --show-stats | grep -iE "hits|misses" || true
echo "ok: $OUT_DIR/Chromium.app"
