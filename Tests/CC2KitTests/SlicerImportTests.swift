import Foundation
import Testing

@testable import CC2Kit

/// Writes a mutated copy of the printer_list fixture to a temp file.
private func printerList(_ mutate: (inout [String: [String: Any]]) -> Void = { _ in }) throws -> URL {
    let data = try Data(contentsOf: fixtureURL("printer_list", "json"))
    var list = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    mutate(&list)
    let url = FileManager.default.temporaryDirectory.appending(path: "printer_list-\(UUID()).json")
    try JSONSerialization.data(withJSONObject: list).write(to: url)
    return url
}

private func tempFile(_ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "printer_list-\(UUID()).json")
    try Data(text.utf8).write(to: url)
    return url
}

struct SlicerImportTests {
    @Test func importsCC2Entry() throws {
        let connection = try SlicerImport.importConnection(from: try printerList())
        #expect(
            connection
                == PrinterConnection(host: "192.168.130.97", serialNumber: "CC2SERIAL000001", accessCode: "123456"))
    }

    @Test func ignoresIsAddedFalse() throws {
        let url = try printerList { list in
            for key in list.keys { list[key]?["isAdded"] = false }
        }
        #expect(try SlicerImport.importConnection(from: url).host == "192.168.130.97")
    }

    @Test func latestActiveWins() throws {
        let url = try printerList { list in
            var newer = try! #require(list.values.first)
            newer["host"] = "10.0.0.5"
            newer["lastActiveTime"] = (newer["lastActiveTime"] as? Int ?? 0) + 100
            list["second"] = newer
        }
        #expect(try SlicerImport.importConnection(from: url).host == "10.0.0.5")
    }

    @Test func missingFile() {
        let url = FileManager.default.temporaryDirectory.appending(path: "does-not-exist-\(UUID()).json")
        #expect(throws: ImportError.fileMissing) { try SlicerImport.importConnection(from: url) }
    }

    @Test func unparseableFile() throws {
        let url = try tempFile("{")
        #expect(throws: ImportError.unreadable) { try SlicerImport.importConnection(from: url) }
    }

    @Test func noCC2Entry() throws {
        let url = try printerList { list in
            for key in list.keys { list[key]?["printerModel"] = "Elegoo Neptune 4" }
        }
        #expect(throws: ImportError.noCC2Entry) { try SlicerImport.importConnection(from: url) }
    }

    @Test func emptyAccessCode() throws {
        let url = try printerList { list in
            for key in list.keys { list[key]?["accessCode"] = "" }
        }
        #expect(throws: ImportError.incompleteEntry) { try SlicerImport.importConnection(from: url) }
    }
}
