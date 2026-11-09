#!/usr/bin/env bash
# Installs the build prerequisites on an Apple silicon Mac. Safe to re-run.
source "$(dirname "$0")/env.sh"
brew install python@3.13 ninja coreutils readline node esbuild typescript ccache
brew list binutils >/dev/null 2>&1 && brew unlink binutils   # use Xcode's
xcrun metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain
mkdir -p "$BROWSER_WORK"
[ -x "$VENV/bin/python3" ] || /opt/homebrew/bin/python3.13 -m venv "$VENV"
"$VENV/bin/pip" install -q PySocks httplib2
ccache --max-size=50G >/dev/null
echo "ok: prerequisites ready in $BROWSER_WORK"
