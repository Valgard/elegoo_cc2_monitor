import CoreGraphics
import Foundation
import Observation
import os

/// Where status events come from; `MQTTStatusClient` in the app, scripted sources in tests.
public protocol StatusSource: Sendable {
    func session() -> AsyncThrowingStream<StatusEvent, Error>
    func requestResync()
}

extension MQTTStatusClient: StatusSource {}

public enum CameraState: Equatable, Sendable {
    case connecting
    case live
    case reconnecting
}

/// The app's model: merges status events, keeps the latest camera frame, and reconnects both
/// channels independently every `retryInterval` — except after a rejected access code.
@MainActor
@Observable
public final class PrinterMonitor {
    public private(set) var status = PrinterStatus()
    public private(set) var latestFrame: CGImage?
    public private(set) var camera: CameraState = .connecting

    public var headline: String? {
        switch status.channel {
        case .authFailed: "Zugangscode falsch"
        case .offline: camera == .live ? "Status offline" : "Drucker nicht erreichbar"
        case .limited, .registrationFailed: "Eingeschränkter Status"
        case .connecting, .online: nil
        }
    }

    private static let log = Logger(subsystem: "cc2-monitor", category: "monitor")
    private let mode: RegistrationMode
    private let retryInterval: Duration
    private let frames: @Sendable () -> AsyncThrowingStream<CGImage, Error>
    private let source: any StatusSource
    private var tasks: [Task<Void, Never>] = []
    /// Set when a session ended; the next session's first channel state decides the resync.
    private var reconnected = false

    public convenience init(
        connection: PrinterConnection, clientId: String, mode: RegistrationMode = .default,
        retryInterval: Duration = .seconds(5)
    ) {
        self.init(
            mode: mode, retryInterval: retryInterval,
            source: MQTTStatusClient(connection: connection, clientId: clientId, mode: mode),
            frames: {
                guard let url = connection.cameraURL else {
                    return AsyncThrowingStream { $0.finish(throwing: URLError(.badURL)) }
                }
                return MJPEGStream.frames(from: url)
            })
    }

    init(
        mode: RegistrationMode, retryInterval: Duration,
        source: any StatusSource,
        frames: @escaping @Sendable () -> AsyncThrowingStream<CGImage, Error>
    ) {
        self.mode = mode
        self.retryInterval = retryInterval
        self.source = source
        self.frames = frames
    }

    public func start() {
        stop()
        tasks = [Task { await runStatus() }, Task { await runCamera() }]
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks = []
    }

    func handle(_ event: StatusEvent) {
        switch event {
        case .channel(.offline):
            status.channel = .offline
            status.lastReportId = nil
            reconnected = true
        case .channel(.connecting) where reconnected:
            break  // keep showing "offline" until the new session knows more
        case .channel(let state):
            status.channel = state
            if reconnected, state != .connecting {
                reconnected = false
                if resyncAction(mode: mode, channel: state) == .resetPrintFields {
                    status = StatusMerger.resetPrintFields(status)
                }
                // When registered, the session fetches a fresh snapshot by itself.
            }
        case .report(let report):
            let gap = StatusMerger.hasGap(lastId: status.lastReportId, newId: report.id)
            guard gap else {
                status = StatusMerger.merge(status, report: report)
                return
            }
            switch resyncAction(mode: mode, channel: status.channel) {
            case .resetPrintFields:
                status = StatusMerger.merge(StatusMerger.resetPrintFields(status), report: report)
            case .requestSnapshot, .registerBriefly:
                status = StatusMerger.merge(status, report: report)
                source.requestResync()
            }
        case .snapshot(let snapshot):
            status = StatusMerger.apply(status, snapshot: snapshot)
        }
    }

    private func runStatus() async {
        while !Task.isCancelled {
            do {
                for try await event in source.session() { handle(event) }
            } catch MQTTStatusClient.SessionError.authFailed {
                Self.log.error("printer rejected the access code; not retrying until the settings change")
                handle(.channel(.authFailed))
                return  // no retry until the settings change and the monitor is restarted
            } catch {
                Self.log.notice("status session ended: \(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            handle(.channel(.offline))
            try? await Task.sleep(for: retryInterval)
        }
    }

    private func runCamera() async {
        while !Task.isCancelled {
            do {
                for try await frame in frames() {
                    latestFrame = frame
                    camera = .live
                }
            } catch {
                Self.log.notice("camera stream ended: \(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            camera = .reconnecting
            try? await Task.sleep(for: retryInterval)
        }
    }
}
