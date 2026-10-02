# Rasa Printer — IPP Everywhere virtual printer for Android

Turns an Android device into a driverless network printer. Anything "printed" to it
(from macOS, Windows, Linux/CUPS, iOS AirPrint, Android) is stored on the device as a
PDF / PWG-Raster / Apple URF / JPEG / PNG file and listed in the app, where it can be
opened, shared or deleted.

## How it works

| Component | Path | Role |
|---|---|---|
| IPP codec | `app/src/main/java/com/rasa/printer/ipp/` | RFC 8010 binary encode/decode (collections included) |
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
./gradlew assembleDebug            # APK in app/build/outputs/apk/debug/
./gradlew testDebugUnitTest        # unit tests; also runs CUPS `ipptool` conformance
                                   # suites end-to-end if ipptool is installed (macOS has it)
```

## Adding the printer on a computer

- **macOS**: System Settings → Printers → Add; the printer appears via Bonjour, or add
  `ipp://<ip>:8631/ipp/print` manually (driver: "AirPrint"/"Secure AirPrint" or generic).
- **CUPS (Linux)**: `lpadmin -p rasa -E -v ipp://<ip>:8631/ipp/print -m everywhere`
- **Windows 10/11**: Add printer → the device is discovered as an IPP printer, or
  add by URL `http://<ip>:8631/ipp/print`.
- **iOS**: Share → Print (requires Android 13+ on the printer side for the `_universal`
  subtype that AirPrint discovery relies on).

## Where documents go

Finished documents are written to shared storage through MediaStore as
`Documents/Rasa Printer/<yyyyMMdd-HHmmss>_<job name>.<ext>`, so they show up in the
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
