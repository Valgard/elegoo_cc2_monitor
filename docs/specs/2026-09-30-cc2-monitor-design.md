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
"Behaviour") nothing is guaranteed beyond what the printer happens to push:
every field appears only once it changes. Fast-moving values (nozzle
temperature, remaining time, layer) show up within seconds during a print;
file name, total layers, state and a steady bed temperature may stay `–` for a
long time.

## Acceptance criteria

Taken from the user's request and the decisions made in the design
conversation (2026-09-29/30):

1. A small app that connects to the CC2 and shows the camera and a small
   status — display only, LAN only. Status = state, progress %, layer,
   remaining time, file name, nozzle and bed temperature.
2. Native macOS app.
3. A window now (optionally always on top); a menu-bar app later as stage 2.
4. MQTT via the `mqtt-nio` library.
5. Register with the printer at startup to fetch a full status; if
   registration is refused, fall back silently to listen-only and show
   "limited status". **The slicer is never displaced:** a slicer that is
   already connected keeps working when the app starts, and a slicer started
   while the app is running can still connect. (To be verified against the
   printer as the first implementation step, see open point 2.)
6. Zero setup on first launch by importing the credentials from ElegooSlicer;
   afterwards the app is independent of the slicer (own copy, access code in
   the Keychain); settings dialog as fallback.
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
  (16 messages in a 15 s capture, ids 26577–26592 without gaps), `method: 6000`.
  **Payloads are deltas**: a field is present only when it changed. In the
  capture, `heater_bed` appeared in only 2 of 16 messages (59, then 60 °C) and
  `machine_status.progress` in 1 (23); `print_status.print_duration` and
  `total_duration`, which tick every second, appeared in every message. A
  trimmed excerpt (the real message also carried `gcode_move`,
  `print_duration` and `total_duration`; fixtures use the untrimmed
  messages):
  `{"id":26580,"method":6000,"result":{"extruder":{"temperature":224},"print_status":{"current_layer":68,"remaining_time_sec":2385}}}`

Everything below comes from the ElegooSlicer LAN plugin
(`ElegooSlicer.app/Contents/Resources/plugins/elegoolink/web/lan_service_web/index.html`)
and has **not** been observed on the wire by us:

- `elegoo/<sn>/api_register` with `{"request_id":"<client_id>"}`, answered on
  `elegoo/<sn>/<request_id>/register_response`. The plugin counts `error` =
  `"ok"` **or** `"already registered"` as success; `"too many clients"` is the
  refusal because of the client limit.
- `elegoo/<sn>/<client_id>/api_request` and `…/api_response` — request/response
  after registration.
- **Snapshot:** `GetBasicInfo` (method 1002). The plugin treats its response as
  the full status and re-requests it whenever the auto-report `id` skips a
  value. (`GetMachineStatus` 1003 exists in the method enum but is never
  called.)
- **One id sequence for two report types:** besides `MessageAutoReport` (6000)
  the plugin handles `SystemAutoReport` (6008) and tracks both with the same
  counter. Gap detection must therefore follow the id across both methods,
  not across 6000 alone, or it fires falsely.
- **Heartbeat:** `{"type":"PING"}` on `api_request`, answered with
  `{"type":"PONG"}`. (The enum's `Heartbeat` 1052 is never sent.)

Caveat: that plugin connects via MQTT-over-WebSocket on port 9001; the slicer's
actual CC2 connection is its native client on TCP 1883. Payloads are expected
to match but are confirmed against the printer, not assumed.

**Open points, resolved as the first implementation step (against the running
printer, before any UI work depends on them):**

1. The exact payloads of `api_register`, `GetBasicInfo` and `PING`, and their
   responses — recorded as test fixtures. In particular: does the
   `GetBasicInfo` response carry every status-bar field? The resync rule below
   relies on it; any field it lacks is marked as not resyncable.
2. **Client slot:** how many clients may register, and whether a slot is freed
   when a client disconnects or stops sending `PING`. Count every client the
   slicer brings: its native client (`1_PC_…`) and, when its device page is
   open, the LAN web plugin, which opens its own MQTT connection on port 9001.
   Acceptance tests, both required: (a) slicer already connected, then start
   the app — the slicer keeps working; (b) app registered, then start the
   slicer — the slicer connects. Outcome, in this order:
   - both pass while the app stays registered → **stay registered** (`PING`
     heartbeat);
   - otherwise, if a slot is released by a mechanism the measurement finds →
     **register briefly**: register, fetch the snapshot, release; repeat only
     for a resync. Re-run (a) and (b) in this mode;
   - otherwise → **never register**: the app runs permanently in
     listen-only mode (`limited`). The slicer's priority wins over the full
     status.

   The spec is updated with the result.
3. **Listen-only without any registered client:** does the printer publish
   `api_status` when no client is registered at all? (The 2026-09-29 capture
   ran while the slicer was connected.) If not, limited mode has no data
   source and must say so ("no status").
4. The MQTT return code for a **wrong** access code (only a missing username
   was tried: "Not authorized").

## Structure

Swift package at the root of the repository
`~/Projects/private/3d_printing/cc2-monitor/`, two targets:

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
| `PrinterConfig` | Host, serial number, access code. Imports from ElegooSlicer's `~/Library/Application Support/ElegooSlicer/user/printer_list.json` (a JSON object keyed by printer UUID; the entry whose `printerModel` contains "Centauri Carbon 2", and among several such entries the one with the latest `lastActiveTime`; `isAdded` is ignored — it is `false` on the real CC2 entry); the import fails if the file is missing or unparseable, has no CC2 entry, or that entry lacks `host`, `serialNumber` or a non-empty `accessCode`; persists host and serial in `UserDefaults`, the access code in the Keychain. | Foundation, Security |
| `MJPEGParser` | Pure byte-stream parser: feed chunks, get complete JPEG frames out. Handles frames split across chunks and several frames in one chunk. | nothing |
| `MJPEGStream` | Opens the camera URL with `URLSession` bytes, feeds `MJPEGParser`, exposes `AsyncStream<CGImage>`. | `URLSession`, `MJPEGParser` |
| `PrinterStatus` | Value type: machine state, progress %, current/total layer, remaining seconds, file name, nozzle and bed temperature, last seen `api_status` id, status-channel state (`connecting`, `online`, `limited`, `registrationFailed`, `offline`, `authFailed`). All print fields optional ("unknown until seen"). | nothing |
| `StatusMerger` | Pure functions: `merge(PrinterStatus, delta) -> PrinterStatus` (absent field = unchanged), `apply(PrinterStatus, snapshot) -> PrinterStatus` for the `GetBasicInfo` response, `resetPrintFields(PrinterStatus)` (sets every print field — state, progress, layers, remaining time, file name, both temperatures — to unknown; connection states untouched), and `hasGap(lastId, newId) -> Bool` (`newId - lastId > 1`, over the ids of all auto-report methods, 6000 and 6008). | nothing |
| `MQTTStatusClient` | Connects via `mqtt-nio`, subscribes to `api_status`, registers, requests the `GetBasicInfo` snapshot, sends `PING` while registered. Registration mode (stay / brief / never) is a setting fixed by open point 2. `"ok"`/`"already registered"` = registered; `"too many clients"` → `limited`; registration timeout or an unexpected response → `registrationFailed` (also listen-only, but logged with the raw response, so a wrong payload is not mistaken for a full printer). Emits decoded messages as an `AsyncStream`. | `mqtt-nio` |
| `PrinterMonitor` | `@Observable` model owned by the app: wires `MQTTStatusClient` → `StatusMerger` → `status`, and `MJPEGStream` → `latestFrame` plus a separate camera state (`live`, `reconnecting`). Owns reconnect timing and resync (see "Behaviour"). | the units above |
| `MonitorWindow` | SwiftUI view: camera image (aspect-fit), status bar, always-on-top toggle, settings sheet. | `PrinterMonitor` |

## Data flow

```
MQTT api_status ──────────────────► MQTTStatusClient ──► StatusMerger.merge ──► PrinterMonitor.status ──► status bar
MQTT api_response (GetBasicInfo) ─► MQTTStatusClient ──► StatusMerger.apply ──┘
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
- **Resync, so stale values do not pass as current:** because deltas omit
  unchanged fields, a change sent while disconnected would otherwise be lost.
  After every status reconnect, and whenever `hasGap` is true:
  - registration mode *stay*: request a fresh `GetBasicInfo` snapshot;
  - registration mode *brief*: register, fetch the snapshot, release;
  - listen-only (`limited`, `registrationFailed`, or mode *never*): reset the
    print fields to unknown (`–`).

  A field the snapshot does not carry (open point 1) is reset instead of kept.
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
- **No stored config and the import fails** (any failure listed under
  `PrinterConfig`): settings sheet opens on launch, stating why the import
  failed.
- **Access code is a secret:** never logged, never shown in plain text in the
  UI (secure field).
- **Window:** remembers size and position; always-on-top persists across
  launches.

## Testing

- `StatusMerger`: unit tests using the real `api_status` messages captured on
  2026-09-29 (committed as fixtures) — deltas that omit fields, deltas that
  change one nested field, `hasGap` on consecutive and skipped ids and on
  interleaved 6000/6008 ids, `resetPrintFields`, and the `GetBasicInfo`
  snapshot once its format is recorded.
- `MJPEGParser`: unit tests for one frame per chunk, frame split across two
  chunks, two frames in one chunk, garbage before the first boundary.
- `PrinterConfig`: import from a fixture copy of `printer_list.json` (with a
  dummy access code), missing file, unparseable file, file without a CC2
  entry, CC2 entry with empty `accessCode`, `isAdded: false` still imported,
  two CC2 entries (latest `lastActiveTime` wins).
- Registration, snapshot, `PING`, client slot (tests a and b), listen-only
  without any registered client, and wrong-code return code:
  verified empirically against the printer as the first plan step (see "Open
  points"); the recorded responses become fixtures, including one for
  `"already registered"`.
- UI: manual check against the running printer (camera visible, status updates,
  pull network cable → offline → reconnect).
