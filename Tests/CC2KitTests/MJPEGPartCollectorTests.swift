import Foundation
import Testing

@testable import CC2Kit

struct MJPEGPartCollectorTests {
    @Test func emitsWhenAnnouncedLengthIsReached() {
        var collector = MJPEGPartCollector()
        #expect(collector.beginPart(expectedLength: 6) == nil)
        #expect(collector.append(Data([0xFF, 0xD8, 1])) == nil)
        #expect(collector.append(Data([2, 0xFF, 0xD9])) == Data([0xFF, 0xD8, 1, 2, 0xFF, 0xD9]))
    }

    @Test func unknownLengthEmitsAtNextPart() {
        var collector = MJPEGPartCollector()
        _ = collector.beginPart(expectedLength: -1)
        #expect(collector.append(Data([0xFF, 0xD8, 0xFF, 0xD9])) == nil)
        #expect(collector.beginPart(expectedLength: -1) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    }

    @Test func incompletePartIsDroppedAtNextPart() {
        var collector = MJPEGPartCollector()
        _ = collector.beginPart(expectedLength: 10)
        _ = collector.append(Data([0xFF, 0xD8]))
        #expect(collector.beginPart(expectedLength: 4) == nil)
        #expect(collector.append(Data([0xFF, 0xD8, 0xFF, 0xD9])) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    }

    @Test func emptyPartEmitsNothing() {
        var collector = MJPEGPartCollector()
        _ = collector.beginPart(expectedLength: -1)
        #expect(collector.beginPart(expectedLength: -1) == nil)
    }
}
