import Foundation

/// Splits a `multipart/x-mixed-replace` byte stream into JPEG payloads.
///
/// Feed it chunks as they arrive; it returns every frame completed so far and keeps the rest.
/// Parts are delimited by `Content-Length` when present, otherwise by the next boundary.
public struct MJPEGParser: Sendable {
    private let marker: Data
    private var buffer = Data()

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let crlf = Data("\r\n".utf8)

    public init(boundary: String) {
        marker = Data("--\(boundary)".utf8)
    }

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while let frame = nextFrame() {
            frames.append(frame)
        }
        return frames
    }

    /// Extracts one complete frame and drops the bytes it consumed, or returns nil when more data is needed.
    private mutating func nextFrame() -> Data? {
        guard let start = buffer.range(of: marker) else {
            // Keep a tail that could be the beginning of a marker split across chunks.
            buffer = Data(buffer.suffix(marker.count - 1))
            return nil
        }
        buffer = Data(buffer[start.lowerBound...])
        guard let headers = buffer.range(of: Self.headerEnd, in: marker.count..<buffer.count) else { return nil }
        let bodyStart = headers.upperBound
        let headerText = String(decoding: buffer[marker.count..<headers.lowerBound], as: UTF8.self)

        if let length = Self.contentLength(in: headerText) {
            guard buffer.count >= bodyStart + length else { return nil }
            let frame = Data(buffer[bodyStart..<bodyStart + length])
            buffer = Data(buffer[(bodyStart + length)...])
            return frame
        }
        guard let next = buffer.range(of: marker, in: bodyStart..<buffer.count) else { return nil }
        var frame = Data(buffer[bodyStart..<next.lowerBound])
        if frame.suffix(2) == Self.crlf { frame.removeLast(2) }
        buffer = Data(buffer[next.lowerBound...])
        return frame
    }

    private static func contentLength(in headers: String) -> Int? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
