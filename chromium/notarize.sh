#!/usr/bin/env bash
# Notarizes a Developer ID signed app (AgensBrowser.app alone, or Agens.app with the engine inside),
# staples the ticket to the .app and checks it with Gatekeeper.
# Usage: AGENS_NOTARY_PROFILE=<notarytool keychain profile> AGENS_APP=<path>/App.app chromium/notarize.sh
set -euo pipefail
: "${AGENS_NOTARY_PROFILE:?set AGENS_NOTARY_PROFILE to the profile name saved with xcrun notarytool store-credentials}"
: "${AGENS_APP:?set AGENS_APP to the signed .app to notarize}"
app="${AGENS_APP%/}"
[ -d "$app/Contents" ] || { echo "not an app bundle: $app" >&2; exit 1; }
codesign --verify --deep --strict "$app"
codesign -dv "$app" 2>&1 | grep -q '^Authority=Developer ID Application:' ||
  { echo "$app is not signed with a Developer ID Application certificate (run chromium/sign.sh first)" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# notarytool takes a zip, dmg or pkg; a zip of the .app is enough, and the ticket is stapled to the .app.
zip="$tmp/$(basename "$app" .app).zip"
ditto -c -k --keepParent "$app" "$zip"
echo "submitting $(du -h "$zip" | cut -f1) to Apple; --wait usually takes minutes, sometimes longer"
xcrun notarytool submit "$zip" --keychain-profile "$AGENS_NOTARY_PROFILE" --wait --output-format json > "$tmp/result.json" || true
status="$(plutil -extract status raw -o - "$tmp/result.json" 2>/dev/null || true)"
id="$(plutil -extract id raw -o - "$tmp/result.json" 2>/dev/null || true)"
if [ "$status" != Accepted ]; then
  cat "$tmp/result.json" >&2
  [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$AGENS_NOTARY_PROFILE" >&2 || true
  echo "notarization failed: status \"${status:-none}\"${id:+, submission $id}" >&2
  exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
echo "ok: notarized and stapled $app (submission $id)"
