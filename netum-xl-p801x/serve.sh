#!/bin/sh
# Serve the web app on http://localhost:8801 (Web Bluetooth needs localhost or HTTPS)
cd "$(dirname "$0")/web" && echo "Open http://localhost:8801 in Chrome" && exec python3 -m http.server 8801 --bind 127.0.0.1
