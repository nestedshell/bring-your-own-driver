#!/bin/sh
# Prints on the real printer. It uses a few centimetres of paper, and needs the printer free.
#   real_print.sh         the link and job code alone: receipt, stop, next job, note
#   real_print.sh model   the model the window uses: report as text, note, stop during copies
#   real_print.sh stop    the same model: only the stop during copies
#   real_print.sh text    the same model: the fake report as text at 11 pt, and its table at 8 pt
# The link is the printer chosen in this tool's own settings; with none, the first paired serial port of an S1,
# or with the extra argument "ble", the first S1 seen over Bluetooth LE.
set -e
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
if [ "$1" = model ] || [ "$1" = stop ] || [ "$1" = text ]; then
  swiftc -swift-version 5 -parse-as-library -o "$OUT/real" Sources/Job.swift Sources/Raster.swift Sources/PrinterLink.swift Sources/SerialLink.swift Sources/AppModel.swift Tests/real_model/main.swift
else
  swiftc -swift-version 5 -o "$OUT/real" Sources/Job.swift Sources/Raster.swift Sources/PrinterLink.swift Sources/SerialLink.swift Tests/real/main.swift
fi
"$OUT/real" "$@"
