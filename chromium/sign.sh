#!/usr/bin/env bash
# Signs AgensBrowser.app inside out (dylibs, helper tools, helper apps, framework, app) with the
# hardened runtime and Chromium's own entitlements and options (chrome/installer/mac/signing/parts.py,
# same order as ungoogled-chromium-macos' sign_and_package_app.sh).
# Usage: AGENS_SIGN_IDENTITY="Developer ID Application: <name> (<team id>)" AGENS_APP=<path>/AgensBrowser.app chromium/sign.sh
#        AGENS_SIGN_IDENTITY=- signs ad hoc, for testing only (no Team ID, no timestamp, can't be notarized).
source "$(dirname "$0")/env.sh"
: "${AGENS_SIGN_IDENTITY:?set AGENS_SIGN_IDENTITY to the certificate name in the Keychain (or - for ad hoc)}"
: "${AGENS_APP:?set AGENS_APP to the AgensBrowser.app to sign, e.g. $SRC_DIR/out/Default/AgensBrowser.app}"
app="${AGENS_APP%/}"
name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
framework="$app/Contents/Frameworks/$name Framework.framework"
[ -d "$framework" ] || { echo "not an AgensBrowser build: $framework is missing" >&2; exit 1; }
entitlements="$SRC_DIR/chrome/app"   # Chromium's plists, the same ones ungoogled ships
[ -f "$entitlements/app-entitlements.plist" ] || { echo "Chromium tree not found: $entitlements (set BROWSER_WORK)" >&2; exit 1; }

if [ "$AGENS_SIGN_IDENTITY" = - ]; then
  timestamp=--timestamp=none
else
  security find-identity -v -p codesigning | grep -qF "\"$AGENS_SIGN_IDENTITY\"" ||
    { echo "no valid signing identity named \"$AGENS_SIGN_IDENTITY\" in the Keychain (security find-identity -v -p codesigning)" >&2; exit 1; }
  timestamp=--timestamp   # notarization requires a secure timestamp
fi
full=restrict,library,runtime,kill
# Renderer and GPU run JIT code; Chromium leaves library validation off for them.
jit=restrict,kill,runtime

sign() { codesign --force --sign "$AGENS_SIGN_IDENTITY" "$timestamp" "$@"; }
bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1"; }

xattr -cr "$app"   # Finder info and resource forks break the signature
for lib in "$framework"/Libraries/*.dylib; do
  sign --identifier "$(basename "$lib" .dylib)" "$lib"
done
for tool in chrome_crashpad_handler app_mode_loader web_app_shortcut_copier; do
  sign --identifier "$tool" --options "$full" "$framework/Helpers/$tool"
done
# Each helper signs with its own bundle id, or macOS privacy permissions (Local Network) ignore it.
for helper in "$framework"/Helpers/*.app; do
  id="$(bundle_id "$helper/Contents/Info.plist")"
  case "$helper" in
    *"Renderer).app") sign --identifier "$id" --options "$jit" --entitlements "$entitlements/helper-renderer-entitlements.plist" "$helper" ;;
    *"GPU).app") sign --identifier "$id" --options "$jit" --entitlements "$entitlements/helper-gpu-entitlements.plist" "$helper" ;;
    *) sign --identifier "$id" --options "$full" "$helper" ;;
  esac
done
sign --identifier "$(bundle_id "$framework/Resources/Info.plist")" "$framework"
sign --identifier "$(bundle_id "$app/Contents/Info.plist")" --options "$full" --entitlements "$entitlements/app-entitlements.plist" "$app"

codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv "$app" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|Timestamp|CodeDirectory)' || true
echo "ok: signed $app"
