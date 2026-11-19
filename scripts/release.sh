#!/bin/zsh
# Builds, signs, notarizes and packages Fretboard Modeller for distribution (a Developer ID release).
#
# One-time setup, once you have your Apple Developer account:
#   1. Install your "Developer ID Application" certificate in the login keychain (Xcode > Settings > Accounts >
#      Manage Certificates, or developer.apple.com). Find its name with:  security find-identity -v -p codesigning
#   2. Store notarization credentials in the keychain (an app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials "gm-notary" --apple-id YOU@EXAMPLE.COM --team-id TEAMID --password APP-SPECIFIC-PASSWORD
#
# Then:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/release.sh 1.1
#
# Optional environment: NOTARY_PROFILE (default gm-notary), BUNDLE_ID (default local.fretboard.modeller; set the
# reverse-DNS id you want to ship under), OUT (default ./release).
# Output: release/Fretboard-Modeller-<version>.zip, a notarized, stapled app ready to publish.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: SIGN_IDENTITY=... scripts/release.sh <version>}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application certificate name}"
PROFILE="${NOTARY_PROFILE:-gm-notary}"
OUT="${OUT:-release}"
APP="$OUT/Fretboard Modeller.app"
ZIP="$OUT/Fretboard-Modeller-$VERSION.zip"

rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> Tests"
swift test 2>&1 | tail -3

echo "==> Universal build, signed with the hardened runtime"
UNIVERSAL=1 VERSION="$VERSION" BUILD_NUMBER="$(date +%Y%m%d%H%M)" ./make_app.sh "$OUT"

echo "==> Notarizing (this waits for Apple, usually a few minutes)"
SUBMIT="$OUT/submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait
rm "$SUBMIT"

echo "==> Stapling and checking"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Packaging"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Done: $ZIP"
