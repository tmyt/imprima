import SwiftUI
import UIKit
import RasaPrinterCore

struct ContentView: View {
    @EnvironmentObject var service: PrinterService
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section { statusCard }
                Section("Print jobs") { JobListView() }
            }
            .navigationTitle("Rasa Printer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("Error", isPresented: Binding(get: { service.errorMessage != nil },
                                                 set: { if !$0 { service.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(service.errorMessage ?? "") }
        }
    }

    private var runningBinding: Binding<Bool> {
        Binding(get: { service.isRunning }, set: { $0 ? service.start() : service.stop() })
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: runningBinding) {
                VStack(alignment: .leading) {
                    Text(service.config.name).font(.headline)
                    Text(service.status).font(.subheadline).foregroundStyle(.secondary)
                    Text(service.config.compatibilityMode ? "High compatibility" : "PDF only")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if service.isRunning {
                if service.addresses.isEmpty {
                    Text("No network address found. Connect to Wi-Fi.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(service.addresses, id: \.self) { addr in
                    let uri = "ipp://\(addr):\(service.config.port)\(PrinterConfig.resourcePath)"
                    HStack {
                        Text(uri).font(.footnote.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { UIPasteboard.general.string = uri } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Copy \(uri)")
                    }
                }
            }
            Text("Keep this app open — iOS stops the printer when the app is in the background. Add it on a computer as an IPP Everywhere printer or print from another iPhone via AirPrint.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
