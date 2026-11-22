# XL-P801X Print for macOS — install guide

**XL-P801X Print** lets you print from your Mac on the **NETUM XL-P801X** A4 thermal printer over Bluetooth.
You do not need the phone app, a kernel driver or an administrator password.

You can print in two ways:

- **Drag and drop.** Drop PDFs, images or text files on the app window or on its Dock icon, check the preview and press **Print**.
- **From any app.** Open the print dialog, then choose **PDF ▾ › Print on XL-P801X**.

Requirements: macOS 13 Ventura or later, and a Mac with Bluetooth.

## Install

1. Unzip `XL-P801X-macOS.zip`. You get a folder with the app, this guide and two scripts.
2. Double-click `Install.command`. The scripts are not notarised by Apple, so macOS says it cannot verify them: click **Done**. Then open **System Settings › Privacy & Security**, scroll to the message about `Install.command`, click **Open Anyway** and confirm. This allows only this file: never turn Gatekeeper off for the whole Mac. Alternatively, open Terminal, type `bash ` (with a space), drag `Install.command` onto the window and press Return.
3. A Terminal window shows what was installed, and the app opens.
4. When macOS asks to allow Bluetooth for *XL-P801X Print*, click **Allow**.

The installer changes only two things, both in your user folder:

| What | Where |
|---|---|
| The app | `~/Applications/XL-P801X Print.app` |
| The print-dialog entry (a link to the app) | `~/Library/PDF Services/Print on XL-P801X.app` |

## Use

1. Switch the printer on. If the phone app is connected to the printer, close it first, because the printer
   accepts only one connection at a time. The first time, the top left of the window lists the printers found:
   press **Connect** next to yours. The app remembers it and connects only to that printer; **Change printer**
   chooses again. The dot turns green when the printer is connected. The printer does not need to be paired in
   System Settings, and the link is not encrypted.
2. Drop files on the window or on the Dock icon, check the preview and press **Print** (⌘P). With **Print files at
   once when dropped or sent from the print dialog** on (off by default), they print right away.
3. To print from Word, Safari, Preview or any other app, choose **File › Print…**. Open the **PDF** menu at the bottom
   left of the dialog and choose **Print on XL-P801X**. The file opens in the window; check it and press **Print**.

Tips:

- **Paper** sets the output size: A4 (default), US Letter, A5, A6, or an 80/57 mm roll. The page is scaled to that
  width and centred, so on an A4 roll an A5 page comes out smaller and centred. Narrower paper must sit in the middle of the guide.
- **Darkness** goes from 0 to 31. If the print is too faint, raise it. If it smudges, lower it.
- **Dithering → Auto** keeps text sharp and renders greys with dots. **Atkinson** gives better results for photos.
- Uncheck a page in the preview to skip it.
- A full A4 page takes about 50 seconds. That is the speed of the printer's Bluetooth link.

## Uninstall

Run `Uninstall.command` the same way as the installer (double-click, then **Open Anyway**, or `bash` in Terminal). It removes:

- the app from `~/Applications` (and from `/Applications`, if you moved it there)
- the **Print on XL-P801X** entry in the print dialog
- the app's settings and its Bluetooth permission

To uninstall by hand, delete those two items from the table above.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Looking for the printer…" never ends | Switch the printer off and on. Make sure the phone app is closed. |
| "Bluetooth not allowed" | Open System Settings › Privacy & Security › Bluetooth and turn on *XL-P801X Print*. |
| "Print on XL-P801X" is missing from the PDF menu | Run `Install.command` again, then reopen the app you are printing from. |
| "XL-P801X Print is damaged / can't be opened" | The download kept Apple's quarantine flag. Run `Install.command`, which clears it, or run `xattr -dr com.apple.quarantine "XL-P801X Print.app"`. |
| The left or right edge is cut | An A4 sheet covers 210 mm of the 216 mm print head. Keep about 3 mm of margin. |

## Build from source

You need only the Xcode Command Line Tools (`xcode-select --install`). A full Xcode is not required.

```sh
mac/build.sh          # → dist/XL-P801X/ and dist/XL-P801X-macOS.zip
```

The app is signed ad hoc (`codesign -s -`), so building and sharing it needs no Apple Developer account.
