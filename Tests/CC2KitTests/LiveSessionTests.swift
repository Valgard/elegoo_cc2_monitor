import Foundation
import Testing

@testable import CC2Kit

/// Runs against the real printer: `CC2_LIVE=1 swift test --filter LiveSessionTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CC2_LIVE"] == "1"))
struct LiveSessionTests {
    @Test func liveSession() async throws {
        let connection = try SlicerImport.importConnection(from: SlicerImport.defaultURL)
        let client = MQTTStatusClient(connection: connection, clientId: CC2Protocol.newClientId(), mode: .stay)
        var channels: [StatusChannelState] = []
        var snapshot: StatusDelta?
        let deadline = ContinuousClock.now + .seconds(15)
        for try await event in client.session() {
            switch event {
            case .channel(let state): channels.append(state)
            case .snapshot(let delta): snapshot = delta
            case .report: break
            }
            if ContinuousClock.now > deadline || snapshot != nil { break }
        }
        #expect(channels.first == .connecting)
        #expect(channels.contains(.online))
        #expect(snapshot?.machineStatus?.status != nil)
    }

    @Test func cameraDeliversFrames() async throws {
        let connection = try SlicerImport.importConnection(from: SlicerImport.defaultURL)
        let url = try #require(URL(string: "http://\(connection.host):8080/"))
        var count = 0
        let deadline = ContinuousClock.now + .seconds(3)
        do {
            for try await _ in MJPEGStream.frames(from: url) {
                count += 1
                if ContinuousClock.now > deadline { break }
            }
        } catch {
            Issue.record("stream ended with \(error) after \(count) frames")
        }
        #expect(count >= 5)
    }

    @Test func wrongCodeFailsAuth() async {
        var connection = try! SlicerImport.importConnection(from: SlicerImport.defaultURL)
        connection.accessCode = "000000"
        let client = MQTTStatusClient(connection: connection, clientId: CC2Protocol.newClientId(), mode: .never)
        await #expect(throws: MQTTStatusClient.SessionError.authFailed) {
            for try await _ in client.session() {}
        }
    }
}
