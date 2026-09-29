import Foundation
import Synchronization
import Testing

@testable import CC2Kit

final class MemorySecrets: SecretStore {
    private let items = Mutex<[String: String]>([:])
    func read(account: String) throws -> String? { items.withLock { $0[account] } }
    func write(_ secret: String, account: String) throws { items.withLock { $0[account] = secret } }
}

private func freshDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "cc2-monitor-tests-\(UUID())"))
}

struct ConfigStoreTests {
    let connection = PrinterConnection(host: "192.168.130.97", serialNumber: "SN1", accessCode: "123456")

    @Test func roundTripWithMemorySecrets() throws {
        let store = ConfigStore(defaults: try freshDefaults(), secrets: MemorySecrets())
        try store.save(connection)
        #expect(store.load() == connection)
    }

    @Test func loadReturnsNilWithoutCode() throws {
        let defaults = try freshDefaults()
        defaults.set("192.168.130.97", forKey: "printerHost")
        defaults.set("SN1", forKey: "printerSerial")
        #expect(ConfigStore(defaults: defaults, secrets: MemorySecrets()).load() == nil)
    }

    @Test func keychainRoundTrip() throws {
        let keychain = KeychainStore(service: "cc2-monitor-test-\(UUID())")
        defer { try? keychain.delete(account: "SN1") }
        try keychain.write("123456", account: "SN1")
        try keychain.write("654321", account: "SN1")
        #expect(try keychain.read(account: "SN1") == "654321")
        #expect(try keychain.read(account: "other") == nil)
    }
}
