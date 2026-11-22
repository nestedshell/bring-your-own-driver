#!/bin/bash
# Installs S1 Driver for the current user. No administrator password is needed.
#   - copies the app to ~/Applications
#   - adds "Print on S1" to the PDF menu of every print dialog (~/Library/PDF Services)
# Run Uninstall.command to remove everything.
set -e
cd "$(dirname "$0")"

APP="S1 Driver.app"
SRC="$PWD/$APP"
[ -d "$SRC" ] || SRC="$PWD/../dist/S1-Driver/$APP"  # running from the source tree
if [ ! -d "$SRC" ]; then
  echo "Cannot find \"$APP\" next to this script. Build it first with mac/build.sh."
  exit 1
fi

DEST="$HOME/Applications"
SERVICES="$HOME/Library/PDF Services"
mkdir -p "$DEST" "$SERVICES"

osascript -e 'quit app "S1 Driver"' 2>/dev/null || true
rm -rf "${DEST:?}/${APP:?}"
ditto "$SRC" "$DEST/$APP"
# Downloaded apps carry a quarantine flag; the app is ad-hoc signed, not notarised.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

ln -sfn "$DEST/$APP" "$SERVICES/Print on S1.app"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$APP" || true

echo ""
echo "Installed:"
echo "  App:         $DEST/$APP"
echo "  Print menu:  $SERVICES/Print on S1.app"
echo ""
echo "In any app: File › Print… › PDF ▾ › Print on S1"
open "$DEST/$APP"
