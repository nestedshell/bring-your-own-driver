#!/bin/sh
# Runs the tests that need no printer. An optional folder also receives pictures of the window.
set -e
cd "$(dirname "$0")"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -o "$OUT/core" Sources/Job.swift Sources/Raster.swift Tests/main.swift
"$OUT/core"
swiftc -swift-version 5 -parse-as-library -o "$OUT/app" Sources/Job.swift Sources/Raster.swift Sources/PrinterLink.swift Sources/SerialLink.swift Sources/AppModel.swift Sources/Views.swift Tests/app/main.swift
"$OUT/app" "$@"
