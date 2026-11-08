# Sourced by the other scripts. The Chromium tree lives outside this repo.
set -euo pipefail
CHROMIUM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_WORK="${BROWSER_WORK:-$HOME/browser-work}"
UC_TAG="$(cat "$CHROMIUM_DIR/VERSION")"
UC_DIR="$BROWSER_WORK/ungoogled-chromium-macos"   # upstream macOS packaging, pinned to UC_TAG
SRC_DIR="$UC_DIR/build/src"
OUT_DIR="$SRC_DIR/out/Default"
VENV="$BROWSER_WORK/venv"                          # Python 3.13: depot_tools does not support newer
export PATH="$VENV/bin:/opt/homebrew/bin:$PATH"
export CCACHE_DIR="${CCACHE_DIR:-$BROWSER_WORK/ccache}"
export CCACHE_BASEDIR="$SRC_DIR"
export CCACHE_SLOPPINESS="include_file_mtime,include_file_ctime,time_macros,modules"
# Chromium's bundled lld can't parse the macOS 27 SDK (.tbd target arm64e.x1), so pin the 26.5 SDK from the Command Line Tools.
# shortcut: fixed SDK path; revisit when the pinned Chromium's lld understands the macOS 27 SDK.
MAC_SDK="${MAC_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[ -f "$MAC_SDK/SDKSettings.json" ] || { echo "macOS SDK not found: $MAC_SDK (install Command Line Tools or set MAC_SDK)" >&2; exit 1; }
export SDKROOT="$MAC_SDK"   # bindgen asks xcrun for the SDK
