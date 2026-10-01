import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import CC2Kit

/// A status source whose n-th session replays the n-th script (the last one repeats).
final class ScriptedSource: StatusSource {
    struct Script: Sendable {
        var events: [StatusEvent]
        var ending: (any Error)?
    }

    let scripts: [Script]
    let sessions = Mutex(0)
    let resyncs = Mutex(0)

    init(_ events: [StatusEvent], ending: (any Error)? = nil) {
        scripts = [Script(events: events, ending: ending)]
    }

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    func session() -> AsyncThrowingStream<StatusEvent, Error> {
        let n = sessions.withLock {
            $0 += 1
            return $0
        }
        let script = scripts[min(n, scripts.count) - 1]
        return AsyncThrowingStream { continuation in
            for event in script.events { continuation.yield(event) }
            continuation.finish(throwing: script.ending)
        }
    }

    func requestResync() { resyncs.withLock { $0 += 1 } }
}

private let noCamera: @Sendable () -> AsyncThrowingStream<CGImage, Error> = {
    AsyncThrowingStream { $0.finish() }
}

@MainActor
private func monitor(_ source: ScriptedSource, mode: RegistrationMode = .stay) -> PrinterMonitor {
    PrinterMonitor(mode: mode, retryInterval: .milliseconds(10), source: source, frames: noCamera)
}

private func report(id: Int, _ result: String = "{}") throws -> StatusEvent {
    .report(try #require(CC2Protocol.decodeAutoReport(Data(#"{"id":\#(id),"method":6000,"result":\#(result)}"#.utf8))))
}

@MainActor
struct PrinterMonitorTests {
    @Test func reportsAreMergedAndIdTracked() throws {
        let m = monitor(ScriptedSource([]))
        m.handle(try report(id: 10, #"{"extruder":{"temperature":225}}"#))
        m.handle(try report(id: 11, #"{"print_status":{"current_layer":3}}"#))
        #expect(m.status.lastReportId == 11)
        #expect(m.status.nozzleTemp == 225)
        #expect(m.status.currentLayer == 3)
    }

    @Test func gapResetsPrintFieldsInLimitedMode() throws {
        let m = monitor(ScriptedSource([]))
        m.handle(.channel(.limited))
        m.handle(try report(id: 10, #"{"print_status":{"filename":"x.gcode"}}"#))
        m.handle(try report(id: 13, #"{"extruder":{"temperature":225}}"#))
        #expect(m.status.fileName == nil)
        #expect(m.status.nozzleTemp == 225)  // the report that revealed the gap still counts
    }

    @Test func gapRequestsSnapshotWhenRegistered() throws {
        let source = ScriptedSource([])
        let m = monitor(source)
        m.handle(.channel(.online))
        m.handle(try report(id: 10))
        m.handle(try report(id: 12))
        #expect(source.resyncs.withLock { $0 } == 1)
    }

    @Test func snapshotApplied() throws {
        let m = monitor(ScriptedSource([]))
        m.handle(try report(id: 1, #"{"print_status":{"filename":"old.gcode"}}"#))
        let snapshot = try JSONDecoder().decode(StatusDelta.self, from: Data(#"{"machine_status":{"status":2}}"#.utf8))
        m.handle(.snapshot(snapshot))
        #expect(m.status.fileName == nil)
        #expect(m.status.machineState == 2)
    }

    @Test func headlineWhenBothChannelsDown() {
        let m = monitor(ScriptedSource([]))
        m.handle(.channel(.offline))
        #expect(m.camera != .live)
        #expect(m.headline == "Drucker nicht erreichbar")
    }

    @Test func headlineLimited() {
        let m = monitor(ScriptedSource([]))
        m.handle(.channel(.limited))
        #expect(m.headline == "Eingeschränkter Status")
        m.handle(.channel(.registrationFailed))
        #expect(m.headline == "Eingeschränkter Status")
    }

    @Test func headlineOnlineIsNil() {
        let m = monitor(ScriptedSource([]))
        m.handle(.channel(.online))
        #expect(m.headline == nil)
    }

    @Test func authFailedStopsRetry() async throws {
        let source = ScriptedSource([.channel(.connecting)], ending: MQTTStatusClient.SessionError.authFailed)
        let m = monitor(source)
        m.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(m.status.channel == .authFailed)
        #expect(m.headline == "Zugangscode falsch")
        #expect(source.sessions.withLock { $0 } == 1)
        m.stop()
    }

    @Test func disconnectRetriesAndResetsOnLimitedReconnect() async throws {
        let source = ScriptedSource(scripts: [
            .init(
                events: [.channel(.limited), try report(id: 1, #"{"print_status":{"filename":"x.gcode"}}"#)],
                ending: MQTTStatusClient.SessionError.disconnected),
            .init(events: [.channel(.limited)], ending: MQTTStatusClient.SessionError.disconnected),
        ])
        let m = monitor(source)
        m.start()
        try await Task.sleep(for: .milliseconds(200))
        m.stop()
        #expect(source.sessions.withLock { $0 } >= 2)
        #expect(m.status.fileName == nil)
    }
}
