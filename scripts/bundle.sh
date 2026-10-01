#!/bin/sh
# Builds .build/CC2Monitor.app from the SwiftPM executable (release, ad-hoc signed).
set -eu
cd "$(dirname "$0")/.."

swift build -c release
app=.build/CC2Monitor.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/CC2Monitor" "$app/Contents/MacOS/CC2Monitor"

# App icon: every size iconutil expects, scaled from the 1024 px master (tools/make_icon.py).
iconset=.build/AppIcon.iconset
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil --convert icns "$iconset" --output "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CC2Monitor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>de.svenpoeche.cc2monitor</string>
    <key>CFBundleName</key><string>CC2 Monitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Verbindet sich im Heimnetz mit dem Centauri Carbon 2.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
