import Foundation

/// Registration bookkeeping of one MQTT session, kept pure so its rules are testable.
///
/// A refused or failed registration is retried later; an answer that arrives after the
/// timeout still counts, because the printer did register the client.
struct RegistrationTracker {
    struct Step: Equatable {
        var channel: StatusChannelState
        var retry: Bool
        var firstRegistration = false
    }

    private(set) var isRegistered = false
    private var awaiting = false
    private var everRegistered = false

    mutating func sent() {
        awaiting = true
    }

    mutating func received(_ outcome: RegistrationOutcome) -> Step? {
        awaiting = false
        switch outcome {
        case .registered:
            isRegistered = true
            defer { everRegistered = true }
            return Step(channel: .online, retry: false, firstRegistration: !everRegistered)
        case .tooManyClients:
            return isRegistered ? nil : Step(channel: .limited, retry: true)
        case .failed:
            return isRegistered ? nil : Step(channel: .registrationFailed, retry: true)
        }
    }

    mutating func timedOut() -> Step? {
        guard awaiting else { return nil }
        awaiting = false
        return isRegistered ? nil : Step(channel: .registrationFailed, retry: true)
    }
}

enum Liveness {
    /// A registered client gets a PONG for every PING; three missed intervals mean the link is dead.
    static func pongOverdue(lastPong: ContinuousClock.Instant, now: ContinuousClock.Instant, interval: Duration) -> Bool
    {
        now - lastPong > interval * 3
    }
}
