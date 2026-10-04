# Imprima - IPP Everywhere virtual printer for Android and iOS

[![Android](https://github.com/tmyt/imprima/actions/workflows/android.yml/badge.svg)](https://github.com/tmyt/imprima/actions/workflows/android.yml)
[![iOS](https://github.com/tmyt/imprima/actions/workflows/ios.yml/badge.svg)](https://github.com/tmyt/imprima/actions/workflows/ios.yml)

Turns an Android device into a driverless network printer. Anything "printed" to it
(from macOS, Windows, Linux/CUPS, iOS AirPrint, Android) is stored on the device as a
PDF / PWG-Raster / Apple URF / JPEG / PNG file and listed in the app, where it can be
opened, shared or deleted.

## How it works

Repository layout: `android/` (Gradle project) and `ios/` (Swift package + Xcode app).

| Component | Path | Role |
|---|---|---|
| IPP codec | `android/app/src/main/java/dev/utatane/imprima/ipp/` | RFC 8010 binary encode/decode (collections included) |
| HTTP server | `.../http/` | Minimal HTTP/1.1 (chunked bodies, `Expect: 100-continue`, keep-alive) |
| IPP handler | `.../printer/` | IPP Everywhere (PWG 5100.14) operations and printer attributes |
| Service layer | `.../service/` | Foreground service, file-backed job store, DNS-SD advertising (`_ipp._tcp`, `_universal`/`_print` subtypes) |
| UI | `.../ui/` | Jetpack Compose: start/stop, addresses, job list, settings |

The printer listens on a **non-privileged port (default 8631)** because the app runs
without root; port 631 is never used. The port is advertised via mDNS so clients
discover it automatically; it can be changed in Settings (1024–65535).

Printer URI: `ipp://<device-ip>:8631/ipp/print`

Supported operations: Print-Job, Validate-Job, Create-Job, Send-Document, Close-Job,
Cancel-Job, Cancel-My-Jobs, Get-Job-Attributes, Get-Jobs, Get-Printer-Attributes,
Identify-Printer.

## Build / test

```sh
cd android
./gradlew assembleDebug            # APK in app/build/outputs/apk/debug/
./gradlew testDebugUnitTest        # unit tests; also runs CUPS `ipptool` conformance
                                   # suites end-to-end if ipptool is installed (macOS has it)
```

## Installing Imprima

- **Android**: download the signed APK from the latest [GitHub Release](https://github.com/tmyt/imprima/releases),
  allow installs from your browser/file manager when asked, and open it. For automatic updates,
  add this repository to [Obtainium](https://github.com/ImranR98/Obtainium). Releases are built by
  the `Android release` workflow from `v*` tags; the signing certificate's SHA-256 fingerprint is
  `EB:A7:B6:69:2C:CF:AF:CD:41:A9:51:43:EE:22:4D:C0:CF:67:8A:C6:E5:62:6C:3B:F2:43:AD:CC:03:71:E6:F3`
  (printed in every release build log, verifiable with `apksigner verify --print-certs`).
- **iOS**: distributed through TestFlight (built by Xcode Cloud).

## Adding the printer on a computer

- **macOS**: System Settings → Printers → Add; the printer appears via Bonjour, or add
  `ipp://<ip>:8631/ipp/print` manually (driver: "AirPrint"/"Secure AirPrint" or generic).
- **CUPS (Linux)**: `lpadmin -p imprima -E -v ipp://<ip>:8631/ipp/print -m everywhere`
- **Windows 10/11**: Add printer → the device is discovered as an IPP printer, or
  add by URL `http://<ip>:8631/ipp/print`.
- **iOS**: Share → Print (requires Android 13+ on the printer side for the `_universal`
  subtype that AirPrint discovery relies on).

## Modes

| Mode | Accepts | Advertises | Who can print |
|---|---|---|---|
| **PDF only** (default) | `application/pdf` (octet-stream must sniff as PDF; anything else → `client-error-document-format-not-supported`) | `pdl=application/pdf`, no `URF`, subtype `_print` | macOS, Linux/CUPS, anything that sends PDF. Text stays selectable. Not listed by iOS AirPrint. |
| **High compatibility** | PDF, URF, PWG Raster, JPEG, PNG | full `pdl`, `URF=…`, subtypes `_universal,_print` | Everything incl. iPhone/iPad AirPrint; raster pages are converted to image-only PDFs. |

The mode is switched in Settings and takes effect immediately (the advertisement is re-registered).

## Where documents go

Finished documents are written to shared storage through MediaStore as
`Documents/Imprima/<yyyyMMdd-HHmmss>_<job name>.<ext>`, so they show up in the
Files app and can be opened by any viewer. Deleting a job in the app removes that file.
Internal copies are kept only if the export fails.

## Raster → PDF conversion

AirPrint clients (iOS, macOS) usually send pages pre-rendered as Apple URF or PWG Raster.
Those are unreadable on their own, so the app decodes them on the device (`raster/`
package: RLE decoder for both formats, dependency-free PDF writer) and stores a PDF
instead: colour/grey pages are embedded as JPEG, monochrome pages as 1-bit Flate images.
The page size follows the raster resolution (e.g. 2479×3508 px @ 300 dpi → A4).

## Limitations

- PDF, JPEG and PNG documents are stored as received (no re-rendering); raster
  documents are converted to image-only PDFs (no text layer).
- One document per job (`multiple-document-jobs-supported = false`).
- No TLS (`ipps://`); use on trusted networks only.

## iOS version (`ios/`)

A Swift port with the same protocol stack lives in `ios/`: the Swift package
`ImprimaCore` (IPP codec, POSIX HTTP/1.1 server, IPP Everywhere handler, URF/PWG
raster → PDF, Bonjour via dnssd) and a SwiftUI app in `ios/App` (project generated with
xcodegen). Received documents are saved in the app's Documents folder, visible in the
Files app under "On My iPhone > Imprima".

```sh
cd ios && swift test                      # core tests incl. ipptool conformance (macOS)
cd ios/App && xcodegen generate && \
xcodebuild -project Imprima.xcodeproj -scheme Imprima \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

iOS limitation: there is no equivalent of an Android foreground service, so the printer
only runs while the app is in the foreground (the app disables the idle timer while
running). Launch argument `--autostart` starts the printer immediately (used for testing).
