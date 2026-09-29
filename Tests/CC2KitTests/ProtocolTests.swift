import Foundation
import Testing

@testable import CC2Kit

struct ProtocolTests {
    @Test func decodesSystemReportIdWithoutFields() throws {
        let decoded = try report(#"{"id":42,"method":6008,"result":{"anything":[1,2]}}"#)
        #expect(decoded.id == 42)
        #expect(decoded.method == 6008)
        var status = PrinterStatus()
        status.fileName = "a.gcode"
        status.nozzleTemp = 225
        var expected = status
        expected.lastReportId = 42
        #expect(StatusMerger.merge(status, report: decoded) == expected)
    }

    @Test func decodesReportWithMistypedSection() throws {
        let decoded = try report(#"{"id":43,"method":6000,"result":{"extruder":"hot"}}"#)
        #expect(decoded.id == 43)
        #expect(decoded.result == nil)
    }

    @Test func decodeRejectsNonJSON() {
        #expect(CC2Protocol.decodeAutoReport(Data("garbage".utf8)) == nil)
    }
}
