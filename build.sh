#!/bin/zsh
# Builds ProxyBar.app and installs it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --arch arm64

APP=build/ProxyBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ProxyBar "$APP/Contents/MacOS/ProxyBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.killian.proxybar</string>
    <key>CFBundleName</key><string>ProxyBar</string>
    <key>CFBundleExecutable</key><string>ProxyBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

DEST="$HOME/Applications/ProxyBar.app"
pkill -x ProxyBar 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
