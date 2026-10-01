import CC2Kit
import SwiftUI

@main
struct CC2MonitorApp: App {
    @State private var model = AppModel()
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some Scene {
        Window("CC2 Monitor", id: "monitor") {
            MonitorWindow(model: model, alwaysOnTop: $alwaysOnTop)
        }
        .defaultSize(width: 800, height: 560)
        .windowLevel(alwaysOnTop ? .floating : .normal)
    }
}

/// Owns the connection settings and the running `PrinterMonitor`.
@MainActor
@Observable
final class AppModel {
    private(set) var monitor: PrinterMonitor?
    var showSettings = false
    /// Why the automatic import did not work, shown in the settings sheet.
    private(set) var importProblem: String?
    /// The settings sheet opens once per connection attempt after a rejected access code.
    var authPrompted = false

    private let store = ConfigStore()

    init() {
        do {
            connect(try store.load() ?? importFromSlicer())
        } catch {
            // A locked or denied keychain is not "no configuration": do not re-import over it.
            importProblem = "Zugangscode im Schlüsselbund nicht lesbar."
            connect(nil)
        }
    }

    var currentConnection: PrinterConnection? { try? store.load() }

    func save(_ connection: PrinterConnection) throws {
        try store.save(connection)
        importProblem = nil
        connect(connection)
    }

    private func connect(_ connection: PrinterConnection?) {
        monitor?.stop()
        authPrompted = false
        guard let connection else {
            monitor = nil
            showSettings = true
            return
        }
        let monitor = PrinterMonitor(connection: connection, clientId: Self.clientId())
        monitor.start()
        self.monitor = monitor
    }

    private func importFromSlicer() -> PrinterConnection? {
        let connection: PrinterConnection
        do {
            connection = try SlicerImport.importConnection(from: SlicerImport.defaultURL)
        } catch {
            importProblem = Self.message(for: error)
            return nil
        }
        do {
            try store.save(connection)
        } catch {
            importProblem = "Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden."
        }
        return connection
    }

    private static func message(for error: ImportError) -> String {
        switch error {
        case .fileMissing: "ElegooSlicer-Konfiguration nicht gefunden."
        case .unreadable: "ElegooSlicer-Konfiguration nicht lesbar."
        case .noCC2Entry: "Kein Centauri Carbon 2 im Slicer eingerichtet."
        case .incompleteEntry: "Druckereintrag im Slicer unvollständig."
        }
    }

    /// One id per installation, so a reconnect finds its registration again ("already registered").
    private static func clientId() -> String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "mqttClientId") { return id }
        let id = CC2Protocol.newClientId()
        defaults.set(id, forKey: "mqttClientId")
        return id
    }
}
