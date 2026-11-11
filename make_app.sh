#!/bin/zsh
# Builds a release binary, wraps it in "Fretboard Modeller.app" and installs it to ~/Applications
# so Spotlight can find it. Usage: ./make_app.sh [destination-dir]
set -euo pipefail
cd "$(dirname "$0")"
DEST="${1:-$HOME/Applications}"
APP="$DEST/Fretboard Modeller.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FretboardApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FretboardApp"
[ -f Resources/AppIcon.icns ] || swift tools/make_icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/atmosphere-bar.jpg "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Fretboard Modeller</string>
  <key>CFBundleDisplayName</key><string>Fretboard Modeller</string>
  <key>CFBundleIdentifier</key><string>local.fretboard.modeller</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>FretboardApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>local.fretboard.project</string>
    <key>UTTypeDescription</key><string>Fretboard Modeller Project</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>fretboard</string></array></dict>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Fretboard Modeller Project</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>local.fretboard.project</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
touch "$APP"
mdimport "$APP" 2>/dev/null || true
echo "Installed: $APP"
