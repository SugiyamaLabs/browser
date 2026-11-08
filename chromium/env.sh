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
