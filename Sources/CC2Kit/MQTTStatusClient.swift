import Foundation
import MQTTNIO
import NIOCore
import NIOPosix
import Synchronization
import os

public enum StatusEvent: Sendable {
    case channel(StatusChannelState)
    case report(AutoReport)
    case snapshot(StatusDelta)
}

/// One MQTT session with the printer: subscribe, register, fetch snapshots, keep the slot with PING.
///
/// `session()` ends (throws) when the connection drops; reconnecting is the caller's job.
public final class MQTTStatusClient: Sendable {
    public enum SessionError: Error, Equatable {
        case authFailed
        case disconnected
    }

    private enum Input: Sendable {
        case message(topic: String, payload: Data)
        case registrationTimeout
        case pingTick
        case resync
        case closed
    }

    private static let log = Logger(subsystem: "cc2-monitor", category: "mqtt")
    private static let pingInterval = Duration.seconds(10)
    private static let registrationTimeout = Duration.seconds(5)

    private let connection: PrinterConnection
    private let clientId: String
    private let mode: RegistrationMode
    private let inputs = Mutex<AsyncStream<Input>.Continuation?>(nil)

    public init(connection: PrinterConnection, clientId: String, mode: RegistrationMode) {
        self.connection = connection
        self.clientId = clientId
        self.mode = mode
    }

    public func session() -> AsyncThrowingStream<StatusEvent, Error> {
        AsyncThrowingStream { events in
            let task = Task { await self.run(events) }
            events.onTermination = { _ in task.cancel() }
        }
    }

    /// Asks the running session to resync (snapshot or brief registration, depending on the mode).
    public func requestResync() {
        _ = inputs.withLock { $0?.yield(.resync) }
    }

    private func run(_ events: AsyncThrowingStream<StatusEvent, Error>.Continuation) async {
        let topics = CC2Protocol.Topics(serial: connection.serialNumber, clientId: clientId)
        let client = MQTTClient(
            host: connection.host, port: 1883, identifier: clientId,
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: .init(version: .v3_1_1, userName: "elegoo", password: connection.accessCode))
        let (stream, input) = AsyncStream<Input>.makeStream()
        inputs.withLock { $0 = input }
        var timers: [Task<Void, Never>] = []
        defer {
            inputs.withLock { $0 = nil }
            for timer in timers { timer.cancel() }
        }

        events.yield(.channel(.connecting))
        do {
            try await client.connect(cleanSession: true)
            let listener = client.createPublishListener()
            timers.append(
                Task {
                    for await result in listener {
                        if case .success(let info) = result {
                            input.yield(.message(topic: info.topicName, payload: Data(info.payload.readableBytesView)))
                        }
                    }
                    input.yield(.closed)
                })
            client.addCloseListener(named: "session") { _ in input.yield(.closed) }
            _ = try await client.subscribe(
                to: [topics.status, topics.registerResponse, topics.response].map {
                    MQTTSubscribeInfo(topicFilter: $0, qos: .atLeastOnce)
                })
        } catch let MQTTError.connectionError(code) where code == .notAuthorized || code == .badUserNameOrPassword {
            events.finish(throwing: SessionError.authFailed)
            try? await client.shutdown()
            return
        } catch {
            Self.log.error("connect failed: \(String(describing: error), privacy: .public)")
            events.finish(throwing: SessionError.disconnected)
            try? await client.shutdown()
            return
        }

        func publish(_ topic: String, _ payload: Data) async {
            try? await client.publish(to: topic, payload: ByteBuffer(bytes: payload), qos: .atLeastOnce)
        }
        func after(_ delay: Duration, _ value: Input) {
            timers.append(
                Task {
                    try? await Task.sleep(for: delay)
                    if !Task.isCancelled { input.yield(value) }
                })
        }
        var awaitingRegistration = false
        var registered = false
        var nextRequestId = 1
        func register() async {
            awaitingRegistration = true
            await publish(topics.register, CC2Protocol.registerPayload(clientId: clientId))
            after(Self.registrationTimeout, .registrationTimeout)
        }
        func requestSnapshot() async {
            await publish(topics.request, CC2Protocol.snapshotRequest(id: nextRequestId))
            nextRequestId += 1
        }

        if mode == .never {
            events.yield(.channel(.limited))
        } else {
            await register()
        }

        loop: for await item in stream {
            switch item {
            case .message(let topic, let payload) where topic == topics.status:
                if let report = CC2Protocol.decodeAutoReport(payload) { events.yield(.report(report)) }
            case .message(let topic, let payload) where topic == topics.registerResponse:
                guard awaitingRegistration else { continue }
                awaitingRegistration = false
                switch CC2Protocol.parseRegisterResponse(payload) {
                case .registered:
                    let first = !registered
                    registered = true
                    events.yield(.channel(.online))
                    await requestSnapshot()
                    if mode == .stay, first {
                        timers.append(
                            Task {
                                while !Task.isCancelled {
                                    try? await Task.sleep(for: Self.pingInterval)
                                    input.yield(.pingTick)
                                }
                            })
                    }
                case .tooManyClients:
                    events.yield(.channel(.limited))
                case .failed(let raw):
                    Self.log.error("registration failed: \(raw, privacy: .public)")
                    events.yield(.channel(.registrationFailed))
                }
            case .message(let topic, let payload) where topic == topics.response:
                if let snapshot = CC2Protocol.decodeSnapshot(payload) { events.yield(.snapshot(snapshot)) }
            case .message:
                continue
            case .registrationTimeout:
                guard awaitingRegistration else { continue }
                awaitingRegistration = false
                Self.log.error("registration timed out after 5 s")
                events.yield(.channel(.registrationFailed))
            case .pingTick:
                if registered { await publish(topics.request, CC2Protocol.ping) }
            case .resync:
                switch mode {
                case .stay where registered: await requestSnapshot()
                case .brief: await register()
                default: break
                }
            case .closed:
                break loop
            }
        }
        try? await client.shutdown()
        events.finish(throwing: Task.isCancelled ? nil : SessionError.disconnected)
    }
}
