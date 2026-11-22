#!/bin/bash
# Removes S1 Driver completely: app, print-dialog entry, settings and Bluetooth permission.

ID="io.github.nestedshell.s1driver"
OLD_ID="io.github.s1driver.app"   # identifier of builds before 22 November 2026
APP="S1 Driver.app"

osascript -e 'quit app "S1 Driver"' 2>/dev/null || true

for dir in "$HOME/Applications" "/Applications"; do
  if [ -d "$dir/$APP" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$dir/$APP" 2>/dev/null
    rm -rf "${dir:?}/${APP:?}" && echo "Removed $dir/$APP"
  fi
done

rm -f "$HOME/Library/PDF Services/Print on S1.app" && echo "Removed print-dialog entry"
for id in "$ID" "$OLD_ID"; do
  defaults delete "$id" 2>/dev/null && echo "Removed settings ($id)"
  rm -rf "$HOME/Library/Saved Application State/$id.savedState"
  tccutil reset BluetoothAlways "$id" >/dev/null 2>&1 && echo "Reset Bluetooth permission ($id)"
done

echo ""
echo "S1 Driver has been uninstalled."
