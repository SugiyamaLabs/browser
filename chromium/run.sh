#!/usr/bin/env bash
# Opens the built Chromium on a page, with a throwaway profile.
source "$(dirname "$0")/env.sh"
url="${1:-https://example.com}"
profile="$(mktemp -d)"
exec "$OUT_DIR/Chromium.app/Contents/MacOS/Chromium" --user-data-dir="$profile" --no-first-run "$url"
