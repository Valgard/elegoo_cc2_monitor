import Foundation

/// Pure functions that turn printer messages into a `PrinterStatus`.
public enum StatusMerger {
    /// Applies a delta: a field absent from the delta keeps its current value.
    public static func merge(_ status: PrinterStatus, _ delta: StatusDelta) -> PrinterStatus {
        var s = status
        s.nozzleTemp = delta.extruder?.temperature ?? s.nozzleTemp
        s.bedTemp = delta.heaterBed?.temperature ?? s.bedTemp
        s.machineState = delta.machineStatus?.status ?? s.machineState
        s.progress = delta.machineStatus?.progress ?? s.progress
        s.currentLayer = delta.printStatus?.currentLayer ?? s.currentLayer
        s.totalLayers = delta.printStatus?.totalLayers ?? s.totalLayers
        s.remainingSeconds = delta.printStatus?.remainingTimeSec ?? s.remainingSeconds
        s.fileName = delta.printStatus?.filename ?? s.fileName
        return s
    }

    /// Merges a report's fields (if any) and records its id.
    public static func merge(_ status: PrinterStatus, report: AutoReport) -> PrinterStatus {
        var s = report.result.map { merge(status, $0) } ?? status
        s.lastReportId = report.id
        return s
    }

    /// A snapshot is the full state: fields it does not carry become unknown.
    public static func apply(_ status: PrinterStatus, snapshot: StatusDelta) -> PrinterStatus {
        merge(resetPrintFields(status), snapshot)
    }

    /// Sets every print field to unknown; channel state and report id stay.
    public static func resetPrintFields(_ status: PrinterStatus) -> PrinterStatus {
        var s = PrinterStatus()
        s.lastReportId = status.lastReportId
        s.channel = status.channel
        return s
    }

    /// True when at least one report id was skipped.
    public static func hasGap(lastId: Int?, newId: Int) -> Bool {
        guard let lastId else { return false }
        return newId > lastId + 1
    }
}
