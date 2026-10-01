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
            if !host.isEmpty, candidate.cameraURL == nil {
                Text("Nur Hostname oder IP-Adresse, ohne Port und ohne Leerzeichen.").foregroundStyle(.red)
            }
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
                        candidate.cameraURL == nil || candidate.serialNumber.isEmpty || candidate.accessCode.isEmpty)
            }
        }
        .onAppear {
            guard let current = model.currentConnection else { return }
            host = current.host
            serialNumber = current.serialNumber
            accessCode = current.accessCode
        }
    }

    private var candidate: PrinterConnection {
        PrinterConnection(
            host: host.trimmingCharacters(in: .whitespaces),
            serialNumber: serialNumber.trimmingCharacters(in: .whitespaces),
            accessCode: accessCode.trimmingCharacters(in: .whitespaces))
    }

    private func save() {
        do {
            try model.save(candidate)
            dismiss()
        } catch {
            saveError = "Speichern im Schlüsselbund fehlgeschlagen."
        }
    }
}
