import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Generic-password items in the login keychain, one per printer serial number.
public struct KeychainStore: SecretStore {
    private let service: String

    public init(service: String = "cc2-monitor") {
        self.service = service
    }

    private func query(account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func read(account: String) throws -> String? {
        var q = query(account: account)
        q[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account: account)
            q[kSecValueData] = data
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// The app's own copy of the connection: host and serial in UserDefaults, access code in a SecretStore.
public struct ConfigStore {
    private let defaults: UserDefaults
    private let secrets: any SecretStore

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public func load() -> PrinterConnection? {
        guard let host = defaults.string(forKey: "printerHost"),
            let serial = defaults.string(forKey: "printerSerial"),
            let code = try? secrets.read(account: serial)
        else { return nil }
        return PrinterConnection(host: host, serialNumber: serial, accessCode: code)
    }

    public func save(_ connection: PrinterConnection) throws {
        try secrets.write(connection.accessCode, account: connection.serialNumber)
        defaults.set(connection.host, forKey: "printerHost")
        defaults.set(connection.serialNumber, forKey: "printerSerial")
    }
}
