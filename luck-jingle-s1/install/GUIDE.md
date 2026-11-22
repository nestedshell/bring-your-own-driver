# S1 Driver for macOS: install guide

**S1 Driver** prints from your Mac on the S1 mini thermal printer over Bluetooth, with no phone, no app account and no administrator password.

Requirements: a Mac with Bluetooth and macOS 13 Ventura or later. It has been tested only on macOS 27.

## Install

1. Unzip `S1-Driver-macOS.zip`. You get a folder with the app, this guide and two scripts.
2. Double-click `Install.command`. The scripts are not notarised by Apple, so macOS says it cannot verify them: click **Done**. Then open **System Settings › Privacy & Security**, scroll to the message about `Install.command`, click **Open Anyway** and confirm. This allows only this file: never turn Gatekeeper off for the whole Mac. Alternatively, open Terminal, type `bash ` (with a space), drag `Install.command` onto the window and press Return.
3. A Terminal window shows what was installed, and the app opens.
4. When macOS asks to allow Bluetooth for *S1 Driver*, click **Allow**.

The installer changes only two things, both in your user folder:

| What | Where |
|---|---|
| The app | `~/Applications/S1 Driver.app` |
| The print-dialog entry (a link to the app) | `~/Library/PDF Services/Print on S1.app` |

## Use

1. Switch the printer on and unplug its USB cable. The first time, choose the printer: the top left lists the printers found, and **Connect** next to one connects to it. The app remembers it and connects only to that printer from then on; **Change printer** chooses again. The dot turns green when the printer is connected.
   - **Paired link (encrypted), recommended.** Pair the printer once in **System Settings › Bluetooth**: choose `PPS1_…` (not `PPS1_…_BLE`). It then appears first in the list.
   - **Bluetooth LE (not encrypted).** Works without pairing. The link is not encrypted.

   The line under the printer's name says which link is in use.
2. Add something to print:
   - drop a PDF, an image or a text file in the dashed area, or click it to choose one;
   - **Write by hand** opens a note you can write on with the mouse, trackpad or a pen tablet;
   - **Type text** opens a text box;
   - **⇧⌘V** adds what is on the clipboard.
3. Check the preview and press **Print** (⌘P). **Stop printing** ends the job: over Bluetooth LE within a second or two; over the paired link it first finishes the page being printed (*Finishing this page…*), so a long page can take a while.

To print from any other app, choose **File › Print…**, open the **PDF** menu at the bottom left of the dialog and choose **Print on S1**. The same works by dropping a file on the Dock icon. The file opens in the window with its preview; check it and press **Print**. To print such files without pressing Print, turn on **Print files from the print dialog at once** under **More settings**. A document with a small-text warning still waits, so you can read the warning first.

Tips:

- **Best for** changes how greys become dots. **Documents** keeps text crisp, **Photos** shades pictures, **Line art** uses only black and white.
- **Tone** corrects a print that comes out too dark or too light. Shaded areas usually print darker than the preview.
- **Trim blank edges** enlarges the content to fill the 48 mm width. A full A4 page still comes out about 7 cm long.
- **Small text warning.** On a shrunk PDF page, digits can change and decimal points can disappear. The sheet warns you when that can happen. Check numbers against the original. **Print as text** prints the page's words at a safe size, on a much longer strip, but loses the layout, so check that too.
- The round bin on a sheet deletes it. On a longer PDF it deletes one page.
- **Disconnect** frees the printer for a browser or another app, because it accepts one connection at a time.

## Uninstall

Run `Uninstall.command` the same way as the installer (double-click, then **Open Anyway**, or `bash` in Terminal). It removes the app, the print-dialog entry, the settings and the Bluetooth permission.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Looking for the printer…" never ends | Switch the printer off and on. Close any phone app or browser page connected to it. On the paired link, check that `PPS1_…` is still listed in System Settings › Bluetooth. |
| The list of printers stays empty | Switch the printer on. For the paired link, pair it first in System Settings › Bluetooth. |
| "The printer does not answer" | Unplug the USB cable. In the one case seen, the printer stopped answering over Bluetooth while the cable was connected. |
| "Bluetooth not allowed" | Open System Settings › Privacy & Security › Bluetooth and turn on *S1 Driver*. |
| "The printer stopped accepting data" | Check the paper and the lid. |
| "Print on S1" is missing from the PDF menu | Run `Install.command` again, then reopen the app you are printing from. |
| The app "is damaged" or "can't be opened" | The download kept Apple's quarantine flag. Run `Install.command`, which clears it. |

## Build from source

You need only the Xcode Command Line Tools (`xcode-select --install`). A full Xcode is not required.

```sh
mac/build.sh    # → dist/S1-Driver/ and dist/S1-Driver-macOS.zip
```

The app is signed ad hoc, so building and sharing it needs no Apple Developer account.
