import Foundation

/// State of the MQTT status channel, independent of the camera.
public enum StatusChannelState: Equatable, Sendable {
    case connecting
    case online
    /// Registration refused ("too many clients"): listen-only.
    case limited
    /// Registration timed out or returned something unexpected: listen-only.
    case registrationFailed
    case offline
    case authFailed
}

/// `machine_status.status` values, as enumerated in the ElegooSlicer LAN plugin.
public enum MachineState: Int, Sendable {
    case offline = -1
    case initializing = 0
    case idle
    case printing
    case loading
    case unloading
    case autoLeveling
    case pidCalibration
    case resonanceTester
    case selfCheck
    case upgrade
    case manualHoming
    case fileSending
    case timeLapseVideoGenerating
    case extrudering
    case emergencyStop
    case powerOffResume
    case componentUpgrade
    case foreignObjectDetection
}

/// Everything the status bar shows. Print fields are `nil` until the printer has reported them.
public struct PrinterStatus: Equatable, Sendable {
    public var machineState: Int?
    public var progress: Int?
    public var currentLayer: Int?
    public var totalLayers: Int?
    public var remainingSeconds: Int?
    public var fileName: String?
    public var nozzleTemp: Double?
    public var bedTemp: Double?
    /// Last seen auto-report id, across methods 6000 and 6008.
    public var lastReportId: Int?
    public var channel: StatusChannelState = .connecting

    public init() {}
}
