#!/bin/bash
# Removes XL-P801X Print completely: app, print-dialog entry, settings and Bluetooth permission.

ID="io.github.nestedshell.xlp801print"
OLD_ID="io.github.xlp801.print"   # identifier of builds before 22 November 2026
APP="XL-P801X Print.app"

osascript -e 'quit app "XL-P801X Print"' 2>/dev/null || true

for dir in "$HOME/Applications" "/Applications"; do
  if [ -d "$dir/$APP" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$dir/$APP" 2>/dev/null
    rm -rf "${dir:?}/${APP:?}" && echo "Removed $dir/$APP"
  fi
done

rm -f "$HOME/Library/PDF Services/Print on XL-P801X.app" && echo "Removed print-dialog entry"
for id in "$ID" "$OLD_ID"; do
  defaults delete "$id" 2>/dev/null && echo "Removed settings ($id)"
  rm -rf "$HOME/Library/Saved Application State/$id.savedState"
  tccutil reset BluetoothAlways "$id" >/dev/null 2>&1 && echo "Reset Bluetooth permission ($id)"
done

echo ""
echo "XL-P801X Print has been uninstalled."
