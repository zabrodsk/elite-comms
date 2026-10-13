#!/bin/zsh
# Build a signed macOS app. Set ELITE_INSTALL=0 to leave the installed app alone.
set -euo pipefail
cd "$(dirname "$0")"
SCRATCH="${ELITE_BUILD_PATH:-$HOME/Library/Caches/elite-comms-build}"
UPDATE_FLAGS=()
[[ -d "$SCRATCH/checkouts/FluidAudio" ]] && UPDATE_FLAGS+=(--skip-update)
swift build -c release --scratch-path "$SCRATCH" "${UPDATE_FLAGS[@]}"
BIN_DIR=$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)
APP="$SCRATCH/elite-comms.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/EliteComms" "$APP/Contents/MacOS/EliteComms"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp -R Resources/Licenses "$APP/Contents/Resources/Licenses"
# SwiftPM dependencies find Bundle.module resources beside the executable.
for bundle in "$BIN_DIR"/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
IDENTITY="${ELITE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application:[^"]*)"/\1/p' | head -1)
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development:[^"]*)"/\1/p' | head -1)
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --options runtime --entitlements Resources/EliteComms.entitlements --sign "$IDENTITY" "$APP"
else
  codesign --force --entitlements Resources/EliteComms.entitlements --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "${ELITE_INSTALL:-1}" == 1 ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/elite-comms.app"
  ditto "$APP" "$HOME/Applications/elite-comms.app"
  echo "Installed $HOME/Applications/elite-comms.app"
fi
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
