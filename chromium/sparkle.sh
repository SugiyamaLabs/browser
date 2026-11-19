#!/usr/bin/env bash
# Sparkle updates for the standalone AgensBrowser (docs/build.md, "Atualizações"). Two steps of release.sh:
#   chromium/sparkle.sh embed <AgensBrowser.app>          before sign.sh: copies Sparkle.framework in and sets
#       the feed, the public key, daily automatic checks and installs, and CFBundleVersion (AGENS_BUILD,
#       default the UTC time as yyyymmdd.HHMM, so every release is higher than the one before).
#   chromium/sparkle.sh appcast <dmg> <tag> <appcast.xml>  after the dmg is notarized and stapled: signs it
#       with the EdDSA key and writes the appcast, the download pointing at the GitHub release <tag>.
# SPARKLE_DIR: Sparkle's release folder. AGENS_ED_KEY_FILE: a private key file in place of the
# Keychain's (account agensbrowser), for testing with a throwaway key.
set -euo pipefail
SPARKLE_DIR="${SPARKLE_DIR:-$HOME/Library/Caches/Agens-dev/sparkle-2.9.6}"
repo=https://github.com/SugiyamaLabs/browser
case "${1:-}" in
  embed)
    app="${2%/}"
    plist="$app/Contents/Info.plist"
    fw="$app/Contents/Frameworks/Sparkle.framework"
    [ -f "$plist" ] || { echo "not an app bundle: $app" >&2; exit 1; }
    rm -rf "$fw"
    ditto "$SPARKLE_DIR/Sparkle.framework" "$fw"
    # The XPC services are only for sandboxed apps (Sparkle's "Sandboxing" docs); ours isn't.
    rm -rf "$fw/XPCServices" "$fw/Versions/B/XPCServices"
    set_key() {
      /usr/libexec/PlistBuddy -c "Delete :$1" "$plist" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$plist"
    }
    set_key SUFeedURL string "$repo/releases/latest/download/appcast.xml"
    set_key SUPublicEDKey string dNEpaiaZ9uTzmaGdvNLa/L4iiFj4dgxMWHo2BbPtUes=
    set_key SUEnableAutomaticChecks bool true
    set_key SUAutomaticallyUpdate bool true
    set_key SUScheduledCheckInterval integer 86400
    set_key CFBundleVersion string "${AGENS_BUILD:-$(date -u +%Y%m%d.%H%M)}"
    echo "ok: Sparkle in $app, build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
    ;;
  appcast)
    dmg="${2:?}" tag="${3:?}" xml="${4:?}"
    archives="$(mktemp -d)"; trap 'rm -rf "$archives"' EXIT
    cp -c "$dmg" "$archives/"   # generate_appcast writes into the archives folder; keep the release folder clean
    if [ -n "${AGENS_ED_KEY_FILE:-}" ]; then key=(--ed-key-file "$AGENS_ED_KEY_FILE"); else key=(--account agensbrowser); fi
    # One item, the newest: the feed URL is always the latest release's appcast.xml.
    "$SPARKLE_DIR/bin/generate_appcast" "${key[@]}" --maximum-deltas 0 --link "$repo" \
      --download-url-prefix "$repo/releases/download/$tag/" -o "$archives/appcast.xml" "$archives"
    # generate_appcast only warns, and leaves the item unsigned, when the key isn't the app's SUPublicEDKey.
    grep -q 'sparkle:edSignature=' "$archives/appcast.xml" || { echo "appcast not signed: the EdDSA key does not match SUPublicEDKey" >&2; exit 1; }
    mv "$archives/appcast.xml" "$xml"
    echo "ok: $xml"
    ;;
  *) echo "usage: sparkle.sh embed <app> | appcast <dmg> <tag> <appcast.xml>" >&2; exit 1 ;;
esac
