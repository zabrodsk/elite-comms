#!/bin/zsh
# Create a Developer ID signed DMG. Notarize by default; --signed-only is explicit.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-notarize}"
[[ "$MODE" == notarize || "$MODE" == --signed-only ]] || { echo 'Usage: scripts/release.sh [--signed-only]' >&2; exit 1; }
IDENTITY="${ELITE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application:[^"]*)"/\1/p' | head -1)}"
[[ "$IDENTITY" == 'Developer ID Application:'* ]] || { echo 'A Developer ID Application certificate is required.' >&2; exit 1; }
if [[ "$MODE" == notarize && -z "${ELITE_NOTARY_PROFILE:-}" ]]; then
  echo 'Set ELITE_NOTARY_PROFILE to a saved notarytool Keychain profile, or pass --signed-only.' >&2
  exit 1
fi
ELITE_SIGN_IDENTITY="$IDENTITY" ELITE_INSTALL=0 ./build.sh
SCRATCH="${ELITE_BUILD_PATH:-$HOME/Library/Caches/elite-comms-build}"
APP="$SCRATCH/elite-comms.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(uname -m)
mkdir -p dist
STAGE=$(mktemp -d "$SCRATCH/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
if [[ "$MODE" == notarize ]]; then
  ditto -c -k --keepParent "$APP" "dist/elite-comms-$VERSION-notary.zip"
  xcrun notarytool submit "dist/elite-comms-$VERSION-notary.zip" --keychain-profile "$ELITE_NOTARY_PROFILE" --wait --output-format json > "dist/app-notarization.json"
  python3 -c 'import json; assert json.load(open("dist/app-notarization.json"))["status"] == "Accepted", "App notarization failed"'
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi
ditto "$APP" "$STAGE/elite-comms.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/Install.txt "$STAGE/Read me.txt"
DMG="dist/elite-comms-$VERSION-macos-$ARCH.dmg"
[[ ! -e "$DMG" ]] || { echo "Refusing to overwrite $DMG" >&2; exit 1; }
hdiutil create -volname elite-comms -srcfolder "$STAGE" -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
if [[ "$MODE" == notarize ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$ELITE_NOTARY_PROFILE" --wait --output-format json > "dist/dmg-notarization.json"
  python3 -c 'import json; assert json.load(open("dist/dmg-notarization.json"))["status"] == "Accepted", "DMG notarization failed"'
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  echo 'Developer ID signed. Apple notarization has not been performed.'
fi
hdiutil verify "$DMG"
shasum -a 256 "$DMG" | sed 's|  dist/|  |' > "$DMG.sha256"
echo "Release ready: $DMG"
