#!/usr/bin/env bash
# Opens the built Chromium on a page, with a throwaway profile and a mock keychain (never prompts for the login keychain).
source "$(dirname "$0")/env.sh"
# Usage: run.sh [official|dev] [url]
case "${1:-}" in dev) OUT_DIR="$SRC_DIR/out/Dev"; shift ;; official) shift ;; esac
url="${1:-https://example.com}"
profile="$(mktemp -d)"
exec "$OUT_DIR/Chromium.app/Contents/MacOS/Chromium" --user-data-dir="$profile" --no-first-run --use-mock-keychain "$url"
