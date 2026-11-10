#!/usr/bin/env bash
# Downloads Chromium at the pinned ungoogled-chromium version and applies all patches.
# Patches are not idempotent, so this always starts from a fresh source tree.
source "$(dirname "$0")/env.sh"
arch="${1:-arm64}"

if [ ! -d "$UC_DIR/.git" ]; then
  git clone --recurse-submodules https://github.com/ungoogled-software/ungoogled-chromium-macos.git "$UC_DIR"
fi
git -C "$UC_DIR" fetch --tags --quiet
git -C "$UC_DIR" checkout --quiet "$UC_TAG"
git -C "$UC_DIR" submodule update --init --recursive --quiet

main="$UC_DIR/ungoogled-chromium"
rm -rf "$SRC_DIR"
# -g clones Chromium with the mac PGO profile (the tarball path, -d, only ships the Linux profile)
"$UC_DIR/retrieve_and_unpack_resource.py" -g "$arch"
python3 "$main/utils/prune_binaries.py" "$SRC_DIR" "$main/pruning.list"
python3 "$main/utils/patches.py" apply "$SRC_DIR" "$main/patches" "$UC_DIR/patches"
if [ -f "$CHROMIUM_DIR/patches/series" ]; then   # our patches, applied last
  python3 "$main/utils/patches.py" apply "$SRC_DIR" "$CHROMIUM_DIR/patches"
fi
python3 "$CHROMIUM_DIR/rebrand.py" "$SRC_DIR"   # Agens strings (+ translations) and app icon
python3 "$main/utils/domain_substitution.py" apply -r "$main/domain_regex.list" -f "$main/domain_substitution.list" "$SRC_DIR"

mkdir -p "$SRC_DIR/third_party/llvm-build/Release+Asserts" "$SRC_DIR/third_party/rust-toolchain/bin"
"$UC_DIR/retrieve_and_unpack_resource.py" -p "$arch"   # prebuilt clang and rust toolchains

# devtools-frontend needs an esbuild matching the Homebrew binary (same as upstream build.sh)
ver="$(esbuild --version)"; mod="$BROWSER_WORK/esbuild-node/node_modules/esbuild"
if [ ! -f "$mod/package.json" ] || [ "$(node -p "require('$mod/package.json').version")" != "$ver" ]; then
  npm install --prefix "$BROWSER_WORK/esbuild-node" --no-save --package-lock=false --no-bin-links \
    --ignore-scripts --omit=optional --no-audit --no-fund "esbuild@$ver"
fi
rm -rf "$SRC_DIR/third_party/devtools-frontend/src/node_modules/esbuild"
ln -s "$mod" "$SRC_DIR/third_party/devtools-frontend/src/node_modules/esbuild"

echo "$UC_TAG $arch" > "$SRC_DIR/.browser-fetched"
echo "ok: patched source in $SRC_DIR"
