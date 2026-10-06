#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="dist/ControlTapIME.app"
mkdir -p "$app/Contents/MacOS"
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
    -mmacosx-version-min=13.0 -arch arm64 -arch x86_64 \
    Sources/Core.m Sources/main.m -framework AppKit -framework Carbon \
    -o "$app/Contents/MacOS/controltap-ime"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.tario-you.controltap-ime</string>
<key>CFBundleName</key><string>ControlTapIME</string>
<key>CFBundleExecutable</key><string>controltap-ime</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier io.github.tario-you.controltap-ime "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$PWD/$app"
