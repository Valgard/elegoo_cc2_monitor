import CC2Kit
import SwiftUI

struct MonitorWindow: View {
    @Bindable var model: AppModel
    @Binding var alwaysOnTop: Bool

    var body: some View {
        VStack(spacing: 0) {
            camera
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            statusBar
        }
        .toolbar {
            Toggle("Immer im Vordergrund", systemImage: "pin", isOn: $alwaysOnTop)
            Button("Einstellungen", systemImage: "gearshape") { model.showSettings = true }
        }
        .sheet(isPresented: $model.showSettings) { SettingsSheet(model: model) }
        .onChange(of: model.monitor?.status.channel) { _, channel in
            if channel == .authFailed, !model.authPrompted {
                model.authPrompted = true
                model.showSettings = true
            }
        }
    }

    @ViewBuilder private var camera: some View {
        if let monitor = model.monitor, let frame = monitor.latestFrame {
            Image(decorative: frame, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(monitor.camera == .live ? 1 : 0.4)
                .overlay {
                    if monitor.camera != .live {
                        Text("Verbindung wird wiederhergestellt …")
                            .padding(8)
                            .background(.thinMaterial, in: .capsule)
                    }
                }
        } else {
            Text(model.monitor == nil ? "Keine Druckerverbindung eingerichtet" : "Warte auf Kamera …")
                .foregroundStyle(.secondary)
        }
    }

    private var statusBar: some View {
        let status = model.monitor?.status ?? PrinterStatus()
        let parts = [
            StatusFormatter.state(status),
            StatusFormatter.progress(status),
            "Schicht \(StatusFormatter.layer(status))",
            "Rest \(StatusFormatter.remaining(status))",
            StatusFormatter.fileName(status),
            "Düse \(StatusFormatter.temperature(status.nozzleTemp))",
            "Bett \(StatusFormatter.temperature(status.bedTemp))",
        ]
        return HStack(spacing: 8) {
            if let headline = model.monitor?.headline {
                Text(headline)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.25), in: .capsule)
            }
            Text(parts.joined(separator: " · "))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
