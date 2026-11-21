#!/usr/bin/env bash
# Official build → signed, notarized and stapled AgensBrowser.app and .dmg, with Sparkle and its
# appcast.xml (docs/build.md, "Atualizações"), in a fresh folder. Publishing is a printed command.
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
"$here/sparkle.sh" embed "$app"
# Widevine VMP: Castlabs EVS only signs its own Electron builds ("Binary signature denied" for ours, 21/11/2026);
# a VMP signature for a Chromium fork needs a license from Google. No step here (docs/build.md).
AGENS_APP="$app" "$here/sign.sh"
AGENS_APP="$app" "$here/notarize.sh"
ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
release="$ver-$build"   # Chromium's version and our build: one tag per release
dmg="$dest/AgensBrowser-$release.dmg"
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/AgensBrowser.app"; ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname AgensBrowser -srcfolder "$stage" -fs HFS+ -format ULFO -ov "$dmg" >/dev/null
codesign --sign "$AGENS_SIGN_IDENTITY" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$AGENS_NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
spctl -a -t open --context context:primary-signature -v "$dmg"
"$here/sparkle.sh" appcast "$dmg" "v$release" "$dest/appcast.xml"
echo "ok: $dmg"
echo "publish (the appcast goes on the release that becomes latest):"
echo "  GH_TOKEN=\$(gh auth token --user WillianSugiyama) gh release create v$release '$dmg' '$dest/appcast.xml' --repo SugiyamaLabs/browser --title 'AgensBrowser $release' --notes ''"
