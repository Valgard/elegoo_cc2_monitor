# CC2 Monitor

A small macOS app that shows the camera image and a compact print status of an
Elegoo Centauri Carbon 2 on the local network. Display only — it never controls
the printer.

## Build and run

```sh
scripts/bundle.sh            # builds .build/CC2Monitor.app (release, ad-hoc signed)
open .build/CC2Monitor.app
```

Requires macOS 26 and Xcode 27 / Swift 6.4. On first launch macOS asks for
local-network access, and the keychain asks whether the app may read its
stored access code. The bundle is ad-hoc signed, so the keychain asks again
after every rebuild.

## Credentials

On first launch the app imports host, serial number and access code from
ElegooSlicer's `~/Library/Application Support/ElegooSlicer/user/printer_list.json`
and keeps its own copy (host and serial in the app's defaults, the access code
in the login keychain). If the import fails, or the printer rejects the code,
the settings sheet opens.

## How it talks to the printer

- Camera: MJPEG on `http://<host>:8080/`.
- Status: MQTT on port 1883 (user `elegoo`, password = access code). The app
  registers as one client, holds the slot with a heartbeat, and falls back to
  listen-only ("Eingeschränkter Status") if the printer is full. The slicer is
  never pushed out.

Protocol details, measurements and design decisions: `docs/specs/`.

## Development

```sh
swift test                                    # unit tests
CC2_LIVE=1 swift test --filter LiveSessionTests   # against the real printer
swift format lint --strict --recursive Sources Tests
uv run tools/probe_cc2.py --help              # protocol probe used for the fixtures
uv run tools/make_icon.py                     # Assets/AppIcon-art.jpeg → Assets/AppIcon.png (icon master)
```
