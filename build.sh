#!/bin/zsh
# ./build.sh                  builds SubPacer.app for this Mac and installs it to ~/Applications.
# ./build.sh --release 0.1.0  builds a universal (Apple silicon + Intel) app into dist/ and zips it.
set -euo pipefail
cd "${0:A:h}"

VERSION=""
if [[ "${1:-}" == "--release" ]]; then
  VERSION="${2:?usage: ./build.sh --release <version>}"
fi

if [[ -n "$VERSION" ]]; then
  ARCHS=(--arch arm64 --arch x86_64)
  swift build -c release "${ARCHS[@]}"
  BINARY="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/SubPacer"
  APP=dist/SubPacer.app
else
  swift build -c release --arch "$(uname -m)"
  BINARY=.build/release/SubPacer
  APP=build/SubPacer.app
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/SubPacer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.killian.subpacer</string>
    <key>CFBundleName</key><string>SubPacer</string>
    <key>CFBundleExecutable</key><string>SubPacer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION:-0.0.0-dev}</string>
    <key>CFBundleVersion</key><string>${VERSION:-0}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Killian Cazin. MIT License.</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

if [[ -n "$VERSION" ]]; then
  ZIP="dist/SubPacer-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP"
  echo "Built $ZIP"
  exit 0
fi

DEST="$HOME/Applications/SubPacer.app"
pkill -x SubPacer 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
