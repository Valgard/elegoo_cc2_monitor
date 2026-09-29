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
file name and temperatures — with no setup on first launch, provided
ElegooSlicer is installed with the CC2 added. In limited mode (see
"Behaviour") only the fields the printer pushes on its own are guaranteed;
file name, total layers and state may stay `–` until they change.

## Acceptance criteria

Taken from the user's request and the decisions made in the design
conversation (2026-09-29/30):

1. A small app that connects to the CC2 and shows the camera and a small
   status — display only, LAN only.
2. Native macOS app.
3. A window now (optionally always on top); a menu-bar app later as stage 2.
4. MQTT via the `mqtt-nio` library.
5. Register with the printer to fetch a full status; if registration is
   refused, fall back silently to listen-only and show "limited status".
   **A slicer started while the app is running must still be able to
   connect** (verified against the printer, see "Client slot").
6. Credentials imported from ElegooSlicer on first launch, access code kept in
   the Keychain, settings dialog as fallback.
7. The project lives in `~/Projects/private/3d_printing/cc2-monitor/`, its own
   git repository inside the (non-git) 3D-printing collection folder.

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

- `elegoo/<sn>/api_status` — pushed by the printer about once per second
  (16 messages in a 15 s capture), `method: 6000`, with a consecutive `id`.
  **Payloads are deltas**: a field is present only when it changed (in the
  capture, `heater_bed` appeared only when it went 59 → 60 °C, `progress` only
  when it reached 23). Example:
  `{"id":26580,"method":6000,"result":{"extruder":{"temperature":224},"print_status":{"current_layer":68,"remaining_time_sec":2385}}}`
- `elegoo/<sn>/api_register` and `elegoo/<sn>/<request_id>/register_response`
  — client registration. Success is `error` = `"ok"` **or**
  `"already registered"`; refusal because of the client limit is
  `"too many clients"`.
- `elegoo/<sn>/<client_id>/api_request` and `…/api_response` — request/response
  after registration.

From the ElegooSlicer LAN plugin
(`ElegooSlicer.app/Contents/Resources/plugins/elegoolink/web/lan_service_web/index.html`,
not yet exercised by us):

- **Snapshot:** `GetBasicInfo` (method 1002). The plugin treats its response as
  the full status and re-requests it whenever the `api_status` `id` skips a
  value. (`GetMachineStatus` 1003 exists in the method enum but is never
  called.)
- **Heartbeat:** `{"type":"PING"}` on `api_request`, answered with
  `{"type":"PONG"}`. (The enum's `Heartbeat` 1052 is never sent.)

Caveat: that plugin connects via MQTT-over-WebSocket on port 9001; the slicer's
actual CC2 connection is its native client on TCP 1883. Payloads are expected
to match but are confirmed against the printer, not assumed.

**Open points, resolved as the first implementation step (against the running
printer, before any UI work depends on them):**

1. The exact payloads of `api_register`, `GetBasicInfo` and `PING`, and their
   responses — recorded as test fixtures.
2. **Client slot:** how many clients may register, and whether a slot is freed
   when a client disconnects or stops sending `PING`. Acceptance test: with the
   app registered, start ElegooSlicer and check that it still connects. If it
   does, the app stays registered (heartbeat via `PING`). If it does not, the
   app registers only long enough to fetch a snapshot and releases the slot
   (by the mechanism the measurement finds); the spec is updated with the
   result.
3. The MQTT return code for a **wrong** access code (only a missing username
   was tried: "Not authorized").

## Structure

Swift package, two targets:

- `CC2Kit` — library with all logic, no SwiftUI. Tested with `swift test`.
- `CC2Monitor` — executable SwiftUI app, a thin shell over `CC2Kit`.

The stage-2 menu-bar extra becomes a second scene in `CC2Monitor` that reads
the same `CC2Kit` model; nothing in `CC2Kit` changes for it.

Toolchain: Xcode 27 / Swift 6.4 with strict concurrency, macOS 26 deployment
target. Dependency: `mqtt-nio` (`swift-server-community/mqtt-nio`) via
SwiftPM, pinned to the stable 2.x line (`from: "2.13.0"`), not the
`3.0.0-rc.1` release candidate.

### Units

| Unit | Responsibility | Depends on |
|---|---|---|
| `PrinterConfig` | Host, serial number, access code. Imports from ElegooSlicer's `~/Library/Application Support/ElegooSlicer/user/printer_list.json` (a JSON object keyed by printer UUID; the entry whose `printerModel` contains "Centauri Carbon 2", and among several such entries the one with the latest `lastActiveTime`); persists host and serial in `UserDefaults`, the access code in the Keychain. | Foundation, Security |
| `MJPEGParser` | Pure byte-stream parser: feed chunks, get complete JPEG frames out. Handles frames split across chunks and several frames in one chunk. | nothing |
| `MJPEGStream` | Opens the camera URL with `URLSession` bytes, feeds `MJPEGParser`, exposes `AsyncStream<CGImage>`. | `URLSession`, `MJPEGParser` |
| `PrinterStatus` | Value type: machine state, progress %, current/total layer, remaining seconds, file name, nozzle and bed temperature, last seen `api_status` id, status-channel state (`connecting`, `online`, `limited`, `registrationFailed`, `offline`, `authFailed`). All print fields optional ("unknown until seen"). | nothing |
| `StatusMerger` | Pure functions: `merge(PrinterStatus, delta) -> PrinterStatus` (absent field = unchanged), `apply(PrinterStatus, snapshot) -> PrinterStatus` for the `GetBasicInfo` response, `resetPrintFields(PrinterStatus)`, and `hasGap(lastId, newId) -> Bool` (`newId - lastId > 1`). | nothing |
| `MQTTStatusClient` | Connects via `mqtt-nio`, subscribes to `api_status`, registers, requests the `GetBasicInfo` snapshot, sends `PING` while registered. `"ok"`/`"already registered"` = registered; `"too many clients"` → `limited`; registration timeout or an unexpected response → `registrationFailed` (also listen-only, but logged with the raw response, so a wrong payload is not mistaken for a full printer). Emits decoded messages as an `AsyncStream`. | `mqtt-nio` |
| `PrinterMonitor` | `@Observable` model owned by the app: wires `MQTTStatusClient` → `StatusMerger` → `status`, and `MJPEGStream` → `latestFrame` plus a separate camera state (`live`, `reconnecting`). Owns reconnect timing and resync (see "Behaviour"). | the units above |
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
- **Limited mode:** when registration is refused (`limited`) or fails
  (`registrationFailed`), a small "limited status" indicator appears;
  everything that arrives via `api_status` is still shown. No error dialog.
- **Resync, so stale values never pass as current:** because deltas omit
  unchanged fields, a change sent while disconnected would otherwise be lost.
  After every status reconnect, and whenever `hasGap` is true, a registered app
  requests a fresh `GetBasicInfo` snapshot; an app in limited mode instead
  resets the print fields to unknown (`–`).
- **Channels fail independently:** the status channel shows "offline" when
  MQTT is unreachable; the camera shows its own "reconnecting" state. Each
  retries every 5 s. When both are down, the window reads "printer
  unreachable".
- **Camera stream drops:** the last frame stays visible, dimmed, with a
  "reconnecting" overlay until frames arrive again.
- **Wrong access code** (MQTT connect refused with "bad username or password"
  or "not authorized" — both are treated alike until the measurement settles
  which one the printer sends): status `authFailed`, the settings sheet opens
  once. This is the one exception to automatic reconnect: no retry until the
  settings change.
- **No config and no ElegooSlicer file:** settings sheet opens on launch.
- **Access code is a secret:** never logged, never shown in plain text in the
  UI (secure field).
- **Window:** remembers size and position; always-on-top persists across
  launches.

## Testing

- `StatusMerger`: unit tests using the real `api_status` messages captured on
  2026-09-29 (committed as fixtures) — deltas that omit fields, deltas that
  change one nested field, `hasGap` on consecutive and skipped ids,
  `resetPrintFields`, and the `GetBasicInfo` snapshot once its format is
  recorded.
- `MJPEGParser`: unit tests for one frame per chunk, frame split across two
  chunks, two frames in one chunk, garbage before the first boundary.
- `PrinterConfig`: import from a fixture copy of `printer_list.json` (with a
  dummy access code), missing file, file without a CC2 entry, two CC2 entries
  (latest `lastActiveTime` wins).
- Registration, snapshot, `PING`, client slot and wrong-code return code:
  verified empirically against the printer as the first plan step (see "Open
  points"); the recorded responses become fixtures, including one for
  `"already registered"`.
- UI: manual check against the running printer (camera visible, status updates,
  pull network cable → offline → reconnect).
