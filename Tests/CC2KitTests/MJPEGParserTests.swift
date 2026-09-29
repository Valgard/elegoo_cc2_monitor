import Foundation
import Testing

@testable import CC2Kit

private func jpeg(_ filler: UInt8, count: Int = 40) -> Data {
    Data([0xFF, 0xD8] + [UInt8](repeating: filler, count: count) + [0xFF, 0xD9])
}

private func part(_ body: Data, contentLength: Bool = true) -> Data {
    var header = "--frame\r\nContent-Type: image/jpeg\r\n"
    if contentLength { header += "Content-Length: \(body.count)\r\n" }
    header += "\r\n"
    return Data(header.utf8) + body + Data("\r\n".utf8)
}

struct MJPEGParserTests {
    @Test func oneFramePerChunk() {
        var parser = MJPEGParser(boundary: "frame")
        #expect(parser.append(part(jpeg(1))) == [jpeg(1)])
        #expect(parser.append(part(jpeg(2))) == [jpeg(2)])
    }

    @Test(arguments: [10, 60, 101])  // inside header, inside body, before trailing CRLF
    func frameSplitAcrossChunks(cut: Int) {
        let whole = part(jpeg(3))
        var parser = MJPEGParser(boundary: "frame")
        let first = parser.append(whole.prefix(cut))
        let second = parser.append(whole.dropFirst(cut))
        #expect(first + second == [jpeg(3)])
    }

    @Test func twoFramesInOneChunk() {
        var parser = MJPEGParser(boundary: "frame")
        #expect(parser.append(part(jpeg(4)) + part(jpeg(5))) == [jpeg(4), jpeg(5)])
    }

    @Test func garbageBeforeFirstBoundary() {
        var parser = MJPEGParser(boundary: "frame")
        #expect(parser.append(Data("HTTP junk\r\n".utf8) + part(jpeg(6))) == [jpeg(6)])
    }

    @Test func incompleteFrameIsNotEmitted() {
        let whole = part(jpeg(7))
        var parser = MJPEGParser(boundary: "frame")
        #expect(parser.append(whole.prefix(whole.count - 25)) == [])
    }

    @Test func partWithoutContentLength() {
        var parser = MJPEGParser(boundary: "frame")
        let frames = parser.append(part(jpeg(8), contentLength: false) + part(jpeg(9), contentLength: false))
        #expect(frames == [jpeg(8)])
    }
}

struct MJPEGStreamTests {
    @Test(
        arguments: [
            ("multipart/x-mixed-replace; boundary=frame", "frame"),
            ("multipart/x-mixed-replace; boundary=\"abc\"; charset=x", "abc"),
            (nil, "frame"),
        ] as [(String?, String)])
    func boundaryFromContentType(header: String?, expected: String) {
        #expect(MJPEGStream.boundary(from: header) == expected)
    }
}
