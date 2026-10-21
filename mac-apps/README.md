# Two apps for the AI already inside your Mac

macOS 27 ships a language model at `/usr/bin/fm`. These two apps let you use it without
ever opening the Terminal. Everything runs on your own Mac — nothing is uploaded, and
both work with the Wi-Fi switched off.

| App | What you do | What happens |
|---|---|---|
| **Read Text** | Drag a picture onto it | Pulls the text out, offers to copy or save it |
| **Ask the Mac AI** | Double-click it | A box appears; type a question, get an answer |

Works on screenshots, photos of documents, receipts, scanned pages and forms.

## Before the first use: one setup command

Apple requires you to accept its terms once per Mac, and only the Terminal can do it.
It is a single line, you do it once, and never again. The apps will remind you and copy
the command to your clipboard if you forget.

1. Press **Cmd + Space**, type **Terminal**, press Return.
2. Paste this and press Return:

   ```
   sudo fm license
   ```

3. It asks for your Mac password. **The typing stays invisible — no dots, no stars.**
   That is normal, not a frozen screen. Type it and press Return.
4. Read the terms and accept. Done forever.

## Opening the apps the first time

These apps are not signed by a paid Apple developer account, so macOS will refuse to open
them on the first double-click. This is expected and takes one extra step:

- **Right-click** (or Control-click) the app → choose **Open** → click **Open** in the dialog.

You only do this once per app. Afterwards they open normally.

### Prefer to build them yourself?

If you would rather not run an app a stranger compiled — reasonable — you can build them
from the plain-text source in `source/`, with no Terminal:

1. Double-click `source/ReadText.applescript`. It opens in **Script Editor**, which is
   already on your Mac. You can read every line; it is short.
2. **File → Export…**
3. Set **File Format** to **Application**, pick where to save, click Save.

The app you get is identical, built on your own machine, and macOS will not complain.

## Handy afterwards

- **Drag the app to your Dock.** Then you can drop images straight onto the Dock icon.
- Dropping several images at once works; you get one result per image.

## What to expect

**It works most of the time, not all of the time.** Tested against seven real screenshots
from my own Desktop:

| What happened | How many |
|---|---|
| Read correctly in 1–3 seconds | 4 of 7 |
| Read correctly, but took 185 seconds | 1 of 7 |
| Refused by Apple's safety check | 2 of 7 |

The refusals say *"The model's safety guardrails were triggered"* and come back in under a
second. Nothing sensitive was in either image, and every other OCR tool on the Mac reads
them fine. There is no way around it from the app — the check runs inside the model. The
app explains this in plain words when it happens.

**If an image is refused, try cropping to just the part you need.** That often goes through.

Accuracy is good but not perfect — on the test invoice it once read "Washers" as "Wasters".
Check anything that matters.

**Do not use this to read QR codes or barcodes.** The model only decodes them correctly
about 6 times out of 10, and when it fails it invents a plausible-looking answer rather
than admitting it. Point the Camera app at the code instead; that uses the real decoder
and is right every time.
