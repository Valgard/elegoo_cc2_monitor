import CC2Kit
import SwiftUI

struct SettingsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var serialNumber = ""
    @State private var accessCode = ""
    @State private var saveError: String?

    var body: some View {
        Form {
            if let problem = model.importProblem {
                Text(problem).foregroundStyle(.orange)
            }
            if model.monitor?.status.channel == .authFailed {
                Text("Der Drucker hat den Zugangscode abgelehnt.").foregroundStyle(.red)
            }
            TextField("Host", text: $host)
            TextField("Seriennummer", text: $serialNumber)
            SecureField("Zugangscode", text: $accessCode)
            if let saveError {
                Text(saveError).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") { save() }
                    .disabled(
                        [host, serialNumber, accessCode].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .onAppear {
            guard let current = model.currentConnection else { return }
            host = current.host
            serialNumber = current.serialNumber
            accessCode = current.accessCode
        }
    }

    private func save() {
        let connection = PrinterConnection(
            host: host.trimmingCharacters(in: .whitespaces),
            serialNumber: serialNumber.trimmingCharacters(in: .whitespaces),
            accessCode: accessCode.trimmingCharacters(in: .whitespaces))
        do {
            try model.save(connection)
            dismiss()
        } catch {
            saveError = "Speichern im Schlüsselbund fehlgeschlagen."
        }
    }
}
