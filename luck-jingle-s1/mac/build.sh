#!/bin/sh
# Builds "S1 Driver.app" (universal, ad-hoc signed) and the release folder and zip in luck-jingle-s1/dist/.
# Needs only the Xcode Command Line Tools:  xcode-select --install
set -e
cd "$(dirname "$0")/.."

APP="S1 Driver"
OUT="dist/S1-Driver"
BUNDLE="$OUT/$APP.app"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

rm -rf "dist/S1-Driver" "dist/S1-Driver-macOS.zip"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

for arch in arm64 x86_64; do
  echo "Compiling $arch…"
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -o "$BUILD/$arch" mac/Sources/*.swift
done
lipo -create "$BUILD/arm64" "$BUILD/x86_64" -output "$BUNDLE/Contents/MacOS/$APP"

cp mac/Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp mac/Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: no Apple Developer account needed.
codesign --force --deep --sign - "$BUNDLE"

cp install/*.command install/GUIDE.md "$OUT/"
chmod +x "$OUT"/*.command
(cd dist && ditto -c -k --keepParent S1-Driver S1-Driver-macOS.zip)

echo "Built $BUNDLE"
echo "Release zip: dist/S1-Driver-macOS.zip"
