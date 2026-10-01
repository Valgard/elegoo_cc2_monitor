import Foundation

/// Registration bookkeeping of one MQTT session, kept pure so its rules are testable.
///
/// A refused or failed registration is retried later — at most one retry is pending at a time —
/// and an answer that arrives after the timeout still counts, because the printer did register
/// the client.
struct RegistrationTracker {
    struct Step: Equatable {
        var channel: StatusChannelState
        /// Schedule a new registration attempt.
        var retry: Bool
    }

    private(set) var isRegistered = false
    private var awaiting = false
    private var retryPending = false

    mutating func sent() {
        awaiting = true
    }

    mutating func received(_ outcome: RegistrationOutcome) -> Step? {
        awaiting = false
        switch outcome {
        case .registered:
            isRegistered = true
            return Step(channel: .online, retry: false)
        case .tooManyClients:
            return isRegistered ? nil : Step(channel: .limited, retry: scheduleRetry())
        case .failed:
            return isRegistered ? nil : Step(channel: .registrationFailed, retry: scheduleRetry())
        }
    }

    mutating func timedOut() -> Step? {
        guard awaiting else { return nil }
        awaiting = false
        return isRegistered ? nil : Step(channel: .registrationFailed, retry: scheduleRetry())
    }

    /// The scheduled retry has fired; a later refusal may schedule the next one.
    mutating func retryFired() {
        retryPending = false
    }

    private mutating func scheduleRetry() -> Bool {
        defer { retryPending = true }
        return !retryPending
    }
}

enum KeepAlive: Equatable {
    /// Registered and holding the slot: app-level PING, answered by PONG.
    case appPing
    /// Not holding a slot: MQTT PINGREQ, which fails within the client timeout on a dead link.
    case mqttPing
    /// Three PINGs went unanswered.
    case dropSession
}

enum Liveness {
    static func keepAlive(mode: RegistrationMode, registered: Bool, pongOverdue: Bool) -> KeepAlive {
        guard mode == .stay, registered else { return .mqttPing }
        return pongOverdue ? .dropSession : .appPing
    }

    /// A registered client gets a PONG for every PING; three missed intervals mean the link is dead.
    static func pongOverdue(lastPong: ContinuousClock.Instant, now: ContinuousClock.Instant, interval: Duration) -> Bool
    {
        now - lastPong > interval * 3
    }
}
