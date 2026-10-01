import Foundation
import Testing

@testable import CC2Kit

/// Findings of the final branch review, each pinned by a test.
struct ReviewFixTests {
    // C1: a malformed host must not crash the app.
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

    // I3: only MessageAutoReport (6000) carries status fields; 6008 only advances the id.
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

    // M5 (re-graded Important): a new job must not keep the previous job's layer counts.
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

    // I1: a registered app that stops getting PONGs must notice the dead link.
    @Test func pongOverdueAfterThreeIntervals() {
        let start = ContinuousClock.now
        #expect(!Liveness.pongOverdue(lastPong: start, now: start + .seconds(29), interval: .seconds(10)))
        #expect(Liveness.pongOverdue(lastPong: start, now: start + .seconds(31), interval: .seconds(10)))
    }

    // M4 (re-graded Important): refused or failed registrations are retried; a late "ok" counts.
    @Test func lateOkAfterTimeoutRegisters() {
        var tracker = RegistrationTracker()
        tracker.sent()
        #expect(tracker.timedOut() == .init(channel: .registrationFailed, retry: true))
        #expect(tracker.received(.registered) == .init(channel: .online, retry: false, firstRegistration: true))
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

    @Test func reRegistrationIsNotFirst() {
        var tracker = RegistrationTracker()
        tracker.sent()
        _ = tracker.received(.registered)
        tracker.sent()
        #expect(tracker.received(.registered) == .init(channel: .online, retry: false, firstRegistration: false))
    }
}

// I2: "Drucker nicht erreichbar" must not flicker away while a reconnect attempt is running.
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
