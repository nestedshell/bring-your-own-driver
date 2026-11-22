#!/bin/sh
# Regenerates Resources/AppIcon.icns from tools/make_icon.swift.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/AppIcon.iconset"
swiftc -o "$TMP/make_icon" tools/make_icon.swift
"$TMP/make_icon" "$TMP/AppIcon.iconset"
iconutil -c icns -o Resources/AppIcon.icns "$TMP/AppIcon.iconset"
echo "Resources/AppIcon.icns"
