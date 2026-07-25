#!/bin/bash
# Builds Track in release mode and assembles it into a real Track.app bundle so it can
# be double-clicked, dragged into /Applications, or added to Login Items.
set -euo pipefail

cd "$(dirname "$0")"

echo "Building release binary..."
swift build -c release

APP="Track.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/Track "$APP/Contents/MacOS/Track"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Track</string>
	<key>CFBundleDisplayName</key>
	<string>Track</string>
	<key>CFBundleIdentifier</key>
	<string>io.crafthouse.track</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>Track</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

echo "Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Move it to /Applications and open it, or add to Login Items in System Settings > General."
