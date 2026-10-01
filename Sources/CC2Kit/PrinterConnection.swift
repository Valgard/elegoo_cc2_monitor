import Foundation

/// What the app needs to reach the printer.
public struct PrinterConnection: Equatable, Sendable {
    public var host: String
    public var serialNumber: String
    public var accessCode: String

    public init(host: String, serialNumber: String, accessCode: String) {
        self.host = host
        self.serialNumber = serialNumber
        self.accessCode = accessCode
    }
}

public enum ImportError: Error, Equatable {
    case fileMissing
    case unreadable
    case noCC2Entry
    case incompleteEntry
}

/// Reads the printer from ElegooSlicer's own configuration.
public enum SlicerImport {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/ElegooSlicer/user/printer_list.json")

    /// The file is a JSON object keyed by printer UUID. Picks the Centauri Carbon 2 entry that was
    /// active most recently; `isAdded` is ignored because it is `false` on real, working entries.
    public static func importConnection(from url: URL) throws(ImportError) -> PrinterConnection {
        guard FileManager.default.fileExists(atPath: url.path) else { throw .fileMissing }
        guard let data = try? Data(contentsOf: url),
            let list = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        else { throw .unreadable }

        let candidates = list.values.filter { ($0["printerModel"] as? String)?.contains("Centauri Carbon 2") == true }
        guard let entry = candidates.max(by: { lastActive($0) < lastActive($1) }) else { throw .noCC2Entry }
        guard let host = entry["host"] as? String, !host.isEmpty,
            let serial = entry["serialNumber"] as? String, !serial.isEmpty,
            let code = entry["accessCode"] as? String, !code.isEmpty
        else { throw .incompleteEntry }
        return PrinterConnection(host: host, serialNumber: serial, accessCode: code)
    }

    private static func lastActive(_ entry: [String: Any]) -> Int {
        (entry["lastActiveTime"] as? NSNumber)?.intValue ?? 0
    }
}

extension PrinterConnection {
    /// The camera stream, or `nil` when `host` is not a plain host name or IPv4 address
    /// (e.g. "192.168.1.5:1883" or "my printer" typed into the settings).
    public var cameraURL: URL? {
        guard host.wholeMatch(of: /[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?/) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = 8080
        components.path = "/"
        return components.url
    }
}
