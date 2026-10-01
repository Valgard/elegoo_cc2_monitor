import CoreGraphics
import Foundation
import ImageIO

/// Assembles the parts URLSession delivers for a `multipart/x-mixed-replace` response.
///
/// URLSession splits such a stream itself: every part arrives as a new response followed by its
/// body, boundary lines already removed. A part is a frame once its announced length is reached,
/// or — without a length — once the next part begins. Incomplete parts are dropped.
struct MJPEGPartCollector {
    private var buffer = Data()
    private var expectedLength: Int64 = -1

    /// Starts a new part; returns the previous part if it had no announced length.
    mutating func beginPart(expectedLength: Int64) -> Data? {
        let previous = self.expectedLength < 0 && !buffer.isEmpty ? buffer : nil
        buffer = Data()
        self.expectedLength = expectedLength
        return previous
    }

    /// Adds body bytes; returns the frame when the announced length is complete.
    mutating func append(_ data: Data) -> Data? {
        buffer.append(data)
        guard expectedLength >= 0, buffer.count >= expectedLength else { return nil }
        let frame = buffer
        buffer = Data()
        expectedLength = -1
        return frame
    }
}

/// The printer's MJPEG camera feed as a stream of decoded images.
public enum MJPEGStream {
    /// Emits frames until the connection drops; the stream then throws or finishes.
    public static func frames(from url: URL) -> AsyncThrowingStream<CGImage, Error> {
        AsyncThrowingStream { continuation in
            let session = URLSession(
                configuration: .ephemeral, delegate: Delegate(continuation), delegateQueue: nil)
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    /// Callbacks arrive on the session's serial delegate queue, so the collector needs no lock.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<CGImage, Error>.Continuation
        private var collector = MJPEGPartCollector()

        init(_ continuation: AsyncThrowingStream<CGImage, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
        ) async -> URLSession.ResponseDisposition {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .cancel
            }
            emit(collector.beginPart(expectedLength: response.expectedContentLength))
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            emit(collector.append(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            continuation.finish(throwing: error)
        }

        private func emit(_ jpeg: Data?) {
            guard let jpeg, let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return }
            continuation.yield(image)
        }
    }
}
