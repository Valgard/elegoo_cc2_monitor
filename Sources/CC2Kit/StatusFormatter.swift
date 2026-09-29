import Foundation

/// German display strings for the status bar. Unknown values read `–`.
public enum StatusFormatter {
    public static let unknown = "–"

    private static let stateLabels: [MachineState: String] = [
        .offline: "Offline",
        .initializing: "Startet",
        .idle: "Bereit",
        .printing: "Druckt",
        .loading: "Lädt Filament",
        .unloading: "Entlädt Filament",
        .autoLeveling: "Nivelliert",
        .pidCalibration: "PID-Kalibrierung",
        .resonanceTester: "Resonanztest",
        .selfCheck: "Selbsttest",
        .upgrade: "Update",
        .manualHoming: "Referenzfahrt",
        .fileSending: "Empfängt Datei",
        .timeLapseVideoGenerating: "Zeitraffer wird erstellt",
        .extrudering: "Extrudiert",
        .emergencyStop: "Not-Aus",
        .powerOffResume: "Fortsetzen nach Stromausfall",
        .componentUpgrade: "Komponenten-Update",
        .foreignObjectDetection: "Fremdkörper erkannt",
    ]

    public static func state(_ s: PrinterStatus) -> String {
        guard let code = s.machineState else { return unknown }
        return MachineState(rawValue: code).flatMap { stateLabels[$0] } ?? "Status \(code)"
    }

    public static func progress(_ s: PrinterStatus) -> String {
        s.progress.map { "\($0) %" } ?? unknown
    }

    public static func layer(_ s: PrinterStatus) -> String {
        guard let current = s.currentLayer else { return unknown }
        return s.totalLayers.map { "\(current) / \($0)" } ?? "\(current)"
    }

    /// `h:mm`; negative values (seen on idle printers elsewhere) are not a time.
    public static func remaining(_ s: PrinterStatus) -> String {
        guard let seconds = s.remainingSeconds, seconds >= 0 else { return unknown }
        return String(format: "%d:%02d", seconds / 3600, seconds % 3600 / 60)
    }

    public static func temperature(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) °C" } ?? unknown
    }

    public static func fileName(_ s: PrinterStatus) -> String {
        s.fileName ?? unknown
    }
}
