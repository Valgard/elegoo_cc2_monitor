import Foundation

/// How the app uses the printer's limited client slots.
public enum RegistrationMode: String, Sendable {
    /// Register at startup, hold the slot with PING.
    case stay
    /// Register only to fetch a snapshot, then let the slot lapse.
    case brief
    /// Listen only.
    case never

    /// Measured 2026-10-01: the slicer keeps working and reconnects even with every slot taken.
    public static let `default`: RegistrationMode = .stay
}

public enum ResyncAction: Equatable, Sendable {
    case requestSnapshot
    case registerBriefly
    case resetPrintFields
}

/// What to do after a reconnect or a skipped report id, so stale values never pass as current.
public func resyncAction(mode: RegistrationMode, channel: StatusChannelState) -> ResyncAction {
    guard channel == .online else { return .resetPrintFields }
    switch mode {
    case .stay: return .requestSnapshot
    case .brief: return .registerBriefly
    case .never: return .resetPrintFields
    }
}
