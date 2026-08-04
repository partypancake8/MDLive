#!/usr/bin/env bash
# MDLive: build, (ad-hoc) sign, and notarize helper. PRD Step 11.
#
# Tiers (DEC-2):
#   • LOCAL : ad-hoc signing, runs on your own Mac, no Apple Developer ID needed.
#   • SHIP  : Developer ID signing + notarization, opens cleanly on other Macs.
#
# Usage:
#   scripts/build-and-sign.sh local       # build Release + ad-hoc sign + install to /Applications
#   scripts/build-and-sign.sh ship        # Developer ID sign + notarize + staple (needs setup below)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-local}"
SCHEME=MDLive
DD=build/dd
APP="$DD/Build/Products/Release/MDLive.app"

xcodegen generate

if [[ "$MODE" == "local" ]]; then
  xcodebuild -project MDLive.xcodeproj -scheme "$SCHEME" -configuration Release \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath "$DD" build
  # Ad-hoc signature (identity "-"): satisfies macOS to run locally, not distributable.
  codesign --force --deep --sign - "$APP"
  codesign --verify --verbose=2 "$APP"
  rm -rf /Applications/MDLive.app
  cp -R "$APP" /Applications/MDLive.app
  /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f /Applications/MDLive.app
  echo "Installed (ad-hoc signed) to /Applications/MDLive.app"
  exit 0
fi

if [[ "$MODE" == "ship" ]]; then
  # ── One-time setup (requires an Apple Developer account, ~$99/yr) ──
  #   DEV_ID="Developer ID Application: Your Name (TEAMID)"
  #   xcrun notarytool store-credentials mdlive-notary \
  #       --apple-id "you@example.com" --team-id TEAMID --password <app-specific-password>
  : "${DEV_ID:?set DEV_ID to your 'Developer ID Application: ...' identity}"
  xcodebuild -project MDLive.xcodeproj -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$DD" \
    CODE_SIGN_IDENTITY="$DEV_ID" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" build
  ZIP="$DD/MDLive.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile mdlive-notary --wait
  xcrun stapler staple "$APP"
  spctl -a -t exec -vv "$APP"
  echo "Notarized + stapled: $APP"
  # Package a drag-to-Applications DMG from the notarized app.
  STAGE="$DD/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  DMG="$DD/MDLive.dmg"; rm -f "$DMG"
  hdiutil create -volname "MDLive" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  xcrun stapler staple "$DMG" || true   # staple the DMG too (best practice)
  echo "DMG: $DMG"
  exit 0
fi

echo "unknown mode: $MODE (use 'local' or 'ship')" >&2
exit 1
