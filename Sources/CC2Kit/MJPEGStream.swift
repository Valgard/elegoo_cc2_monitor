import CoreGraphics
import Foundation
import ImageIO

/// The printer's MJPEG camera feed as a stream of decoded images.
public enum MJPEGStream {
    public enum StreamError: Error {
        case badResponse
    }

    /// Emits frames until the connection drops; the stream then throws or finishes.
    public static func frames(from url: URL, session: URLSession = .shared) -> AsyncThrowingStream<CGImage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 10
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw StreamError.badResponse
                    }
                    var parser = MJPEGParser(boundary: boundary(from: http.value(forHTTPHeaderField: "Content-Type")))
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        guard chunk.count >= 4096 else { continue }
                        for frame in parser.append(chunk) {
                            if let image = decode(frame) { continuation.yield(image) }
                        }
                        chunk.removeAll(keepingCapacity: true)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads `boundary=` from a Content-Type header; the CC2 uses `frame`.
    static func boundary(from contentType: String?) -> String {
        guard let contentType, let range = contentType.range(of: "boundary=") else { return "frame" }
        return contentType[range.upperBound...]
            .split(separator: ";").first.map { $0.trimmingCharacters(in: .init(charactersIn: " \"")) } ?? "frame"
    }

    private static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
