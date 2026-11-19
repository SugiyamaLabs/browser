#!/usr/bin/env bash
# Official build → signed, notarized and stapled AgensBrowser.app and .dmg, in a fresh folder.
# Usage: BROWSER_WORK=~/browser-work-2 AGENS_SIGN_IDENTITY="Developer ID Application: …" AGENS_NOTARY_PROFILE=agens-notary chromium/release.sh <out dir>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/env.sh"
: "${AGENS_SIGN_IDENTITY:?}" "${AGENS_NOTARY_PROFILE:?}"
dest="${1:?usage: release.sh <out dir>}"
mkdir -p "$dest"
app="$dest/AgensBrowser.app"
rm -rf "$app"
ditto "$SRC_DIR/out/Default/AgensBrowser.app" "$app"
AGENS_APP="$app" "$here/sign.sh"
AGENS_APP="$app" "$here/notarize.sh"
ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="$dest/AgensBrowser-$ver.dmg"
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/AgensBrowser.app"; ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname AgensBrowser -srcfolder "$stage" -fs HFS+ -format ULFO -ov "$dmg" >/dev/null
codesign --sign "$AGENS_SIGN_IDENTITY" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$AGENS_NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
spctl -a -t open --context context:primary-signature -v "$dmg"
echo "ok: $dmg"
