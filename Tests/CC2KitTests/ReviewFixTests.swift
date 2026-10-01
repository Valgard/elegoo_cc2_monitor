import Foundation
import Testing

@testable import CC2Kit

/// Robustness rules found in review: host input, report types, job switches, liveness, registration.
struct ReviewFixTests {
    // a malformed host must not crash the app.
    @Test(arguments: ["192.168.130.97", "printer.fritz.box", "tyr"])
    func validHostGivesCameraURL(host: String) {
        let connection = PrinterConnection(host: host, serialNumber: "SN", accessCode: "123456")
        #expect(connection.cameraURL?.absoluteString == "http://\(host):8080/")
    }

    @Test(arguments: ["192.168.1.5:1883", "my printer", "[::1", "100%", "http://x", ""])
    func invalidHostGivesNoCameraURL(host: String) {
        #expect(PrinterConnection(host: host, serialNumber: "SN", accessCode: "123456").cameraURL == nil)
    }

    @MainActor
    @Test func monitorWithInvalidHostDoesNotTrap() {
        let bad = PrinterConnection(host: "192.168.1.5:1883", serialNumber: "SN", accessCode: "123456")
        let monitor = PrinterMonitor(connection: bad, clientId: "cc2mon00000000")
        #expect(monitor.camera == .connecting)
    }

    // only MessageAutoReport (6000) carries status fields; 6008 only advances the id.
    @Test func systemReportDoesNotChangeFields() throws {
        let decoded = try #require(
            CC2Protocol.decodeAutoReport(
                Data(#"{"id":50,"method":6008,"result":{"machine_status":{"status":5}}}"#.utf8)))
        var status = PrinterStatus()
        status.machineState = 2
        let merged = StatusMerger.merge(status, report: decoded)
        #expect(merged.machineState == 2)
        #expect(merged.lastReportId == 50)
    }

    // a new job must not keep the previous job's layer counts.
    @Test func newFileResetsLayers() throws {
        var status = PrinterStatus()
        status.fileName = "a.gcode"
        status.currentLayer = 80
        status.totalLayers = 120
        let delta = try JSONDecoder().decode(
            StatusDelta.self, from: Data(#"{"print_status":{"filename":"b.gcode"}}"#.utf8))
        let merged = StatusMerger.merge(status, delta)
        #expect(merged.fileName == "b.gcode")
        #expect(merged.totalLayers == nil)
        #expect(merged.currentLayer == nil)
    }

    @Test func sameFileKeepsLayers() throws {
        var status = PrinterStatus()
        status.fileName = "a.gcode"
        status.totalLayers = 120
        let delta = try JSONDecoder().decode(
            StatusDelta.self, from: Data(#"{"print_status":{"filename":"a.gcode"}}"#.utf8))
        #expect(StatusMerger.merge(status, delta).totalLayers == 120)
    }

    // a registered app that stops getting PONGs must notice the dead link.
    @Test func pongOverdueAfterThreeIntervals() {
        let start = ContinuousClock.now
        #expect(!Liveness.pongOverdue(lastPong: start, now: start + .seconds(29), interval: .seconds(10)))
        #expect(Liveness.pongOverdue(lastPong: start, now: start + .seconds(31), interval: .seconds(10)))
    }

    // refused or failed registrations are retried; a late "ok" counts.
    @Test func lateOkAfterTimeoutRegisters() {
        var tracker = RegistrationTracker()
        tracker.sent()
        #expect(tracker.timedOut() == .init(channel: .registrationFailed, retry: true))
        #expect(tracker.received(.registered) == .init(channel: .online, retry: false))
        #expect(tracker.isRegistered)
    }

    @Test func refusalSchedulesRetry() {
        var tracker = RegistrationTracker()
        tracker.sent()
        #expect(tracker.received(.tooManyClients) == .init(channel: .limited, retry: true))
        #expect(!tracker.isRegistered)
    }

    @Test func failureSchedulesRetry() {
        var tracker = RegistrationTracker()
        tracker.sent()
        #expect(tracker.received(.failed(raw: "x")) == .init(channel: .registrationFailed, retry: true))
    }

    @Test func timeoutAfterAnswerIsIgnored() {
        var tracker = RegistrationTracker()
        tracker.sent()
        _ = tracker.received(.registered)
        #expect(tracker.timedOut() == nil)
    }

    @Test func lateRefusalAfterTimeoutDoesNotScheduleASecondRetry() {
        var tracker = RegistrationTracker()
        tracker.sent()
        #expect(tracker.timedOut() == .init(channel: .registrationFailed, retry: true))
        #expect(tracker.received(.tooManyClients) == .init(channel: .limited, retry: false))
        tracker.retryFired()
        tracker.sent()
        #expect(tracker.received(.tooManyClients) == .init(channel: .limited, retry: true))
    }

    @Test(arguments: [
        (RegistrationMode.stay, true, false, KeepAlive.appPing),
        (.stay, true, true, .dropSession),
        (.stay, false, false, .mqttPing),
        (.brief, true, false, .mqttPing),
        (.never, false, false, .mqttPing),
    ])
    func keepAlivePerMode(mode: RegistrationMode, registered: Bool, overdue: Bool, expected: KeepAlive) {
        #expect(Liveness.keepAlive(mode: mode, registered: registered, pongOverdue: overdue) == expected)
    }

    @Test func snapshotErrorAnswerIsNotASnapshot() {
        let error = #"{"id":2,"method":1002,"result":{"error_code":1}}"#
        #expect(CC2Protocol.decodeSnapshot(Data(error.utf8)) == nil)
        let otherMethod = #"{"id":2,"method":1005,"result":{"error_code":0,"machine_status":{"status":1}}}"#
        #expect(CC2Protocol.decodeSnapshot(Data(otherMethod.utf8)) == nil)
    }

    @Test func importRejectsInvalidHost() throws {
        let data = try Data(contentsOf: fixtureURL("printer_list", "json"))
        var list = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        for key in list.keys { list[key]?["host"] = "192.168.1.5:1883" }
        let url = FileManager.default.temporaryDirectory.appending(path: "printer_list-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: list).write(to: url)
        #expect(throws: ImportError.incompleteEntry) { try SlicerImport.importConnection(from: url) }
    }

    @Test func importIgnoresFirstGenerationCentauri() throws {
        let data = try Data(contentsOf: fixtureURL("printer_list", "json"))
        var list = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        for key in list.keys { list[key]?["printerModel"] = "Elegoo Centauri Carbon" }
        let url = FileManager.default.temporaryDirectory.appending(path: "printer_list-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: list).write(to: url)
        #expect(throws: ImportError.noCC2Entry) { try SlicerImport.importConnection(from: url) }
    }

    @Test func descriptionHidesAccessCode() {
        let connection = PrinterConnection(host: "192.168.130.97", serialNumber: "SN", accessCode: "987654")
        #expect(!"\(connection)".contains("987654"))
        #expect(!String(reflecting: connection).contains("987654"))
    }

    @Test func finishedJobClearsLayers() throws {
        var status = PrinterStatus()
        status.fileName = "a.gcode"
        status.currentLayer = 80
        status.totalLayers = 120
        let delta = try JSONDecoder().decode(StatusDelta.self, from: Data(#"{"print_status":{"filename":""}}"#.utf8))
        let merged = StatusMerger.merge(status, delta)
        #expect(merged.fileName == nil)
        #expect(merged.currentLayer == nil)
        #expect(merged.totalLayers == nil)
    }

    @Test func printingSnapshotFixture() throws {
        let snapshot = try #require(
            CC2Protocol.decodeSnapshot(Data(contentsOf: fixtureURL("get_basic_info_printing", "json"))))
        let status = StatusMerger.apply(PrinterStatus(), snapshot: snapshot)
        #expect(status.machineState == 2)
        #expect(status.remainingSeconds == 12290)
        #expect(status.fileName?.hasPrefix("ECC2_0.4_helm_gesicht") == true)
    }

    @Test func printingCaptureHasNoGaps() throws {
        let text = try String(
            contentsOf: fixtureURL("api_status_2026-10-01_printing", "jsonl"), encoding: .utf8)
        var status = PrinterStatus()
        var gaps = 0
        for line in text.split(separator: "\n") {
            let report = try #require(CC2Protocol.decodeAutoReport(Data(line.utf8)))
            if StatusMerger.hasGap(lastId: status.lastReportId, newId: report.id) { gaps += 1 }
            status = StatusMerger.merge(status, report: report)
        }
        #expect(gaps == 0)
        #expect(status.lastReportId == 710)
        #expect(status.nozzleTemp != nil)
    }
}

// "Drucker nicht erreichbar" must not flicker away while a reconnect attempt is running.
@MainActor
struct ReconnectHeadlineTests {
    @Test func connectingDuringReconnectKeepsOffline() {
        let monitor = PrinterMonitor(
            mode: .stay, retryInterval: .seconds(5), source: ScriptedSource([]),
            frames: { AsyncThrowingStream { $0.finish() } })
        monitor.handle(.channel(.offline))
        monitor.handle(.channel(.connecting))
        #expect(monitor.status.channel == .offline)
        #expect(monitor.headline == "Drucker nicht erreichbar")
        monitor.handle(.channel(.online))
        #expect(monitor.headline == nil)
    }
}
