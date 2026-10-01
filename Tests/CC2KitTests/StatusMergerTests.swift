import Foundation
import Testing

@testable import CC2Kit

func fixtureURL(_ name: String, _ ext: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
}

func delta(_ json: String) throws -> StatusDelta {
    try JSONDecoder().decode(StatusDelta.self, from: Data(json.utf8))
}

func report(_ json: String) throws -> AutoReport {
    try #require(CC2Protocol.decodeAutoReport(Data(json.utf8)))
}

struct StatusMergerTests {
    @Test func mergeKeepsAbsentFields() throws {
        var status = PrinterStatus()
        status.nozzleTemp = 225
        let merged = StatusMerger.merge(status, try delta(#"{"print_status":{"current_layer":68}}"#))
        #expect(merged.nozzleTemp == 225)
        #expect(merged.currentLayer == 68)
    }

    @Test func mergeFixtureSequence() throws {
        let text = try String(contentsOf: fixtureURL("api_status_2026-09-29", "jsonl"), encoding: .utf8)
        var status = PrinterStatus()
        for line in text.split(separator: "\n") {
            status = StatusMerger.merge(status, report: try report(String(line)))
        }
        #expect(status.nozzleTemp == 224)
        #expect(status.bedTemp == 60)
        #expect(status.progress == 23)
        #expect(status.currentLayer == 69)
        #expect(status.remainingSeconds == 2372)
        #expect(status.lastReportId == 26592)
    }

    @Test func newJobReplacesFileName() throws {
        var status = PrinterStatus()
        status.fileName = "a.gcode"
        status.totalLayers = 120
        let merged = StatusMerger.merge(
            status, try delta(#"{"print_status":{"filename":"b.gcode","total_layer":200}}"#))
        #expect(merged.fileName == "b.gcode")
        #expect(merged.totalLayers == 200)
    }

    @Test func resetClearsPrintFieldsOnly() {
        var status = PrinterStatus()
        status.machineState = 2
        status.progress = 23
        status.currentLayer = 68
        status.totalLayers = 120
        status.remainingSeconds = 100
        status.fileName = "a.gcode"
        status.nozzleTemp = 225
        status.bedTemp = 60
        status.lastReportId = 7
        status.channel = .online
        var expected = PrinterStatus()
        expected.lastReportId = 7
        expected.channel = .online
        #expect(StatusMerger.resetPrintFields(status) == expected)
    }

    @Test func applySnapshotResetsMissing() throws {
        var status = PrinterStatus()
        status.fileName = "old.gcode"
        status.nozzleTemp = 200
        let applied = StatusMerger.apply(
            status,
            snapshot: try delta(#"{"extruder":{"temperature":225},"machine_status":{"status":2,"progress":40}}"#))
        #expect(applied.fileName == nil)
        #expect(applied.nozzleTemp == 225)
        #expect(applied.machineState == 2)
        #expect(applied.progress == 40)
    }

    @Test func idleSnapshotFixture() throws {
        let snapshot = try #require(
            CC2Protocol.decodeSnapshot(Data(contentsOf: fixtureURL("get_basic_info_response", "json"))))
        var status = PrinterStatus()
        status.fileName = "old.gcode"
        let applied = StatusMerger.apply(status, snapshot: snapshot)
        #expect(applied.machineState == 1)
        #expect(applied.progress == 0)
        #expect(applied.nozzleTemp == 24)
        #expect(applied.bedTemp == 24)
        #expect(applied.fileName == nil)  // idle printer reports "" — no file, not an empty name
        #expect(applied.totalLayers == nil)
    }

    @Test(arguments: [(nil, 5, false), (4, 5, false), (4, 7, true), (7, 7, false)] as [(Int?, Int, Bool)])
    func hasGap(lastId: Int?, newId: Int, expected: Bool) {
        #expect(StatusMerger.hasGap(lastId: lastId, newId: newId) == expected)
    }
}
