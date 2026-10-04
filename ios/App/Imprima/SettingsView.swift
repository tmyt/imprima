import SwiftUI
import ImprimaCore

struct SettingsView: View {
    @EnvironmentObject var service: PrinterService
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var portText = ""
    @State private var location = ""
    @State private var compatibility = false

    private var port: UInt16? {
        guard let p = Int(portText), (1024...65535).contains(p) else { return nil }
        return UInt16(p)
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { port != nil && !trimmedName.isEmpty }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Printer") {
                    TextField("Name", text: $name)
                    TextField("Location", text: $location)
                }
                Section {
                    TextField("Port", text: $portText).keyboardType(.numberPad)
                } header: { Text("Port") } footer: {
                    Text(port == nil ? String(localized: "Enter a port from 1024 to 65535.") : String(localized: "Port must be 1024 or higher. Default is 8631."))
                        .foregroundStyle(port == nil ? Color.red : Color.secondary)
                }
                Section("Current addresses") {
                    if service.addresses.isEmpty {
                        Text("Not connected to a network").foregroundStyle(.secondary)
                    }
                    ForEach(service.addresses, id: \.self) { addr in
                        Text(addr).font(.body.monospaced())
                    }
                }
                Section {
                    Picker("Mode", selection: $compatibility) {
                        Text("PDF only (recommended)").tag(false)
                        Text("High compatibility").tag(true)
                    }
                } header: { Text("Mode") } footer: {
                    Text(compatibility
                         ? String(localized: "Accepts PDF and AirPrint. Raster pages are converted to PDF.")
                         : String(localized: "Accepts PDF only. Not visible to AirPrint."))
                }
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UUID").font(.footnote).foregroundStyle(.secondary)
                        Text(service.config.uuid).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .onAppear {
                service.refreshAddresses()
                name = service.config.name
                portText = String(service.config.port)
                location = service.config.location
                compatibility = service.config.compatibilityMode
            }
        }
    }

    private func save() {
        guard let port else { return }
        var c = service.config
        c.name = String(trimmedName.prefix(63))
        c.port = port
        c.location = location
        c.compatibilityMode = compatibility
        service.updateConfig(c)
        dismiss()
    }
}
