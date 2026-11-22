#!/bin/sh
# Serve the S1 web driver on http://localhost:8802 (Web Bluetooth needs localhost or HTTPS)
cd "$(dirname "$0")/web" && echo "Open http://localhost:8802 in Chrome" && exec python3 -m http.server 8802 --bind 127.0.0.1
