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
        case retryRegistration
        case pingTick
        case resync
        case closed
    }

    private static let log = Logger(subsystem: "cc2-monitor", category: "mqtt")
    private static let pingInterval = Duration.seconds(10)
    private static let registrationTimeout = Duration.seconds(5)
    private static let registrationRetry = Duration.seconds(60)

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
        // A timeout makes publishes and MQTT pings fail fast on a dead link instead of waiting forever.
        let client = MQTTClient(
            host: connection.host, port: 1883, identifier: clientId,
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: .init(
                version: .v3_1_1, keepAliveInterval: .seconds(30), timeout: .seconds(5),
                userName: "elegoo", password: connection.accessCode))
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

        /// False when the printer did not acknowledge within the timeout: the link is dead.
        func publish(_ topic: String, _ payload: Data) async -> Bool {
            do {
                try await client.publish(to: topic, payload: ByteBuffer(bytes: payload), qos: .atLeastOnce)
                return true
            } catch {
                Self.log.error("publish failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        func after(_ delay: Duration, _ value: Input) {
            timers.append(
                Task {
                    try? await Task.sleep(for: delay)
                    if !Task.isCancelled { input.yield(value) }
                })
        }
        var registration = RegistrationTracker()
        var nextRequestId = 1
        var lastPong = ContinuousClock.now
        func register() async -> Bool {
            registration.sent()
            after(Self.registrationTimeout, .registrationTimeout)
            return await publish(topics.register, CC2Protocol.registerPayload(clientId: clientId))
        }
        func requestSnapshot() async -> Bool {
            defer { nextRequestId += 1 }
            return await publish(topics.request, CC2Protocol.snapshotRequest(id: nextRequestId))
        }
        func apply(_ step: RegistrationTracker.Step?) async -> Bool {
            guard let step else { return true }
            events.yield(.channel(step.channel))
            if step.retry { after(Self.registrationRetry, .retryRegistration) }
            guard step.channel == .online else { return true }
            lastPong = .now
            return await requestSnapshot()
        }

        // Liveness for every mode: registered sessions check PONGs, listen-only sessions MQTT pings.
        timers.append(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pingInterval)
                    input.yield(.pingTick)
                }
            })

        var alive = true
        if mode == .never {
            events.yield(.channel(.limited))
        } else {
            alive = await register()
        }

        loop: for await item in stream where alive {
            switch item {
            case .message(let topic, let payload) where topic == topics.status:
                if let report = CC2Protocol.decodeAutoReport(payload) { events.yield(.report(report)) }
            case .message(let topic, let payload) where topic == topics.registerResponse:
                let outcome = CC2Protocol.parseRegisterResponse(payload)
                if case .failed(let raw) = outcome { Self.log.error("registration failed: \(raw, privacy: .public)") }
                alive = await apply(registration.received(outcome))
            case .message(let topic, let payload) where topic == topics.response:
                if CC2Protocol.isPong(payload) {
                    lastPong = .now
                } else if let snapshot = CC2Protocol.decodeSnapshot(payload) {
                    events.yield(.snapshot(snapshot))
                }
            case .message:
                continue
            case .registrationTimeout:
                if let step = registration.timedOut() {
                    Self.log.error("registration timed out after 5 s")
                    alive = await apply(step)
                }
            case .retryRegistration:
                if !registration.isRegistered { alive = await register() }
            case .pingTick:
                if registration.isRegistered, mode == .stay {
                    if Liveness.pongOverdue(lastPong: lastPong, now: .now, interval: Self.pingInterval) {
                        Self.log.error("no PONG for three intervals, dropping the session")
                        alive = false
                    } else {
                        alive = await publish(topics.request, CC2Protocol.ping)
                    }
                } else {
                    do { try await client.ping() } catch { alive = false }
                }
            case .resync:
                switch mode {
                case .stay where registration.isRegistered: alive = await requestSnapshot()
                case .brief: alive = await register()
                default: break
                }
            case .closed:
                break loop
            }
            if !alive { break loop }
        }
        try? await client.shutdown()
        events.finish(throwing: Task.isCancelled ? nil : SessionError.disconnected)
    }
}
