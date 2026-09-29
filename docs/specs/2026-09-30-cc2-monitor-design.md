# CC2 Monitor — Design

Date: 2026-09-30
Status: draft, awaiting review

## Goal

A small native macOS app that connects to an Elegoo Centauri Carbon 2 on the
local network and shows the live camera image plus a compact print status.
Purpose: keep an eye on a running print from the desk without opening
ElegooSlicer or the Elegoo phone app.

Success looks like: launch the app, and within a few seconds the window shows
the camera feed and a status line with state, progress, layer, remaining time,
file name and temperatures — with no setup on first launch.

### In scope

- One window: camera image filling the window, status bar below it.
- "Always on top" toggle for the window.
- Credentials imported from ElegooSlicer on first launch, stored by the app.
- Settings dialog as fallback (IP, serial number, access code).
- Automatic reconnect for both camera and status.

### Out of scope

- Any printer control (pause, cancel, light, fans, temperatures).
- Access from outside the LAN, Elegoo cloud.
- Multiple printers.
- Menu-bar extra (planned as stage 2; the architecture must allow adding it
  without restructuring, see "Structure").
- Notifications.

## Printer protocol (measured 2026-09-29, firmware 02.01.00.00)

The CC2 does **not** speak SDCP like the first Centauri Carbon: ports
3030/3031 are closed and UDP discovery on 3000 gets no answer.

| Channel | Endpoint | Auth | Verified |
|---|---|---|---|
| Camera | `http://<ip>:8080/`, MJPEG, `multipart/x-mixed-replace; boundary=frame` | none | yes |
| Status | MQTT 3.1.1 on TCP `1883` | user `elegoo`, password = access code | yes |

MQTT topics (`<sn>` = printer serial number):

- `elegoo/<sn>/api_status` — pushed by the printer about once per second,
  `method: 6000`. **Payloads are deltas**: a field is present only when it
  changed. Example:
  `{"id":26580,"method":6000,"result":{"extruder":{"temperature":224},"print_status":{"current_layer":68,"remaining_time_sec":2385}}}`
- `elegoo/<sn>/api_register` and `elegoo/<sn>/<request_id>/register_response`
  — client registration.
- `elegoo/<sn>/<client_id>/api_request` and `…/api_response` — request/response
  after registration.

Request methods relevant here (read from the ElegooSlicer LAN plugin, not yet
exercised): `GetMachineStatus` 1003, `GetPrintsInfo` 1005, `GetBasicInfo` 1002,
`Heartbeat` 1052. Registration can fail with the error string
`"too many clients"` — the printer limits concurrent registered clients.

**Open point, resolved as the first implementation step:** the exact payloads of
`api_register`, of the requests, and of their responses. They are read from the
plugin source (`ElegooSlicer.app/Contents/Resources/plugins/elegoolink/web/lan_service_web/index.html`)
and confirmed against the real printer before any UI work depends on them.

## Structure

Swift package, two targets:

- `CC2Kit` — library with all logic, no SwiftUI. Tested with `swift test`.
- `CC2Monitor` — executable SwiftUI app, a thin shell over `CC2Kit`.

The stage-2 menu-bar extra becomes a second scene in `CC2Monitor` that reads
the same `CC2Kit` model; nothing in `CC2Kit` changes for it.

Toolchain: Xcode 27 / Swift 6.4 with strict concurrency, macOS 26 deployment
target. Dependency: `mqtt-nio` (swift-server) via SwiftPM.

### Units

| Unit | Responsibility | Depends on |
|---|---|---|
| `PrinterConfig` | Host, serial number, access code. Imports from ElegooSlicer's `~/Library/Application Support/ElegooSlicer/user/printer_list.json` (first entry with `printerModel` containing "Centauri Carbon 2"); persists host and serial in `UserDefaults`, the access code in the Keychain. | Foundation, Security |
| `MJPEGParser` | Pure byte-stream parser: feed chunks, get complete JPEG frames out. Handles frames split across chunks and several frames in one chunk. | nothing |
| `MJPEGStream` | Opens the camera URL with `URLSession` bytes, feeds `MJPEGParser`, exposes `AsyncStream<CGImage>`. | `URLSession`, `MJPEGParser` |
| `PrinterStatus` | Value type: machine state, progress %, current/total layer, remaining seconds, file name, nozzle and bed temperature, connection state (`online`, `limited`, `offline`, `authFailed`). All print fields optional ("unknown until seen"). | nothing |
| `StatusMerger` | Pure function `merge(PrinterStatus, delta JSON) -> PrinterStatus`. Absent field = unchanged, never "cleared". Also maps snapshot responses (1003/1005) into the same type. | nothing |
| `MQTTStatusClient` | Connects via `mqtt-nio`, subscribes to `api_status`, registers, requests the snapshot; on `too many clients` or registration timeout falls back to listen-only and reports `limited`. Emits decoded messages as an `AsyncStream`. | `mqtt-nio` |
| `PrinterMonitor` | `@Observable` model owned by the app: wires `MQTTStatusClient` → `StatusMerger` → `status`, and `MJPEGStream` → `latestFrame`. Owns reconnect timing. | the units above |
| `MonitorWindow` | SwiftUI view: camera image (aspect-fit), status bar, always-on-top toggle, settings sheet. | `PrinterMonitor` |

## Data flow

```
MQTT api_status / api_response ──► MQTTStatusClient ──► StatusMerger.merge ──► PrinterMonitor.status ──► status bar
HTTP :8080 MJPEG ─────────────────► MJPEGStream ─────────────────────────────► PrinterMonitor.latestFrame ──► image
```

Camera and status are independent: either channel may fail while the other
keeps working.

## Behaviour

- **Status bar content:** state · progress % · layer `x / y` (just `x` when the
  total is unknown) · remaining time `h:mm` · file name · nozzle °C · bed °C.
  Unknown fields show `–`.
- **Limited mode:** when registration is refused, a small "limited status"
  indicator appears; everything that arrives via `api_status` is still shown.
  No error dialog.
- **Printer unreachable:** status shows "offline"; both channels retry every
  5 s.
- **Camera stream drops:** the last frame stays visible, dimmed, with a
  "reconnecting" overlay until frames arrive again.
- **Wrong access code** (MQTT "Not authorized"): status `authFailed`, the
  settings sheet opens once; no retry loop until the settings change.
- **No config and no ElegooSlicer file:** settings sheet opens on launch.
- **Access code is a secret:** never logged, never shown in plain text in the
  UI (secure field).
- **Window:** remembers size and position; always-on-top persists across
  launches.

## Testing

- `StatusMerger`: unit tests using the real messages recorded on 2026-09-29 as
  fixtures — deltas that omit fields, deltas that change one nested field,
  snapshot responses once their format is confirmed.
- `MJPEGParser`: unit tests for one frame per chunk, frame split across two
  chunks, two frames in one chunk, garbage before the first boundary.
- `PrinterConfig`: import from a fixture copy of `printer_list.json` (with a
  dummy access code), missing file, file without a CC2 entry.
- Registration/snapshot: verified empirically against the printer as the first
  plan step; the recorded responses become fixtures.
- UI: manual check against the running printer (camera visible, status updates,
  pull network cable → offline → reconnect).
