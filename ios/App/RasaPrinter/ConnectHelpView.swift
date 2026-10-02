import SwiftUI
import RasaPrinterCore

struct ConnectHelpView: View {
    @EnvironmentObject var service: PrinterService
    @Environment(\.dismiss) private var dismiss

    private var address: String { service.addresses.first ?? "<address>" }
    private var ippURI: String { "ipp://\(address):\(service.config.port)\(PrinterConfig.resourcePath)" }
    private var httpURI: String { "http://\(address):\(service.config.port)\(PrinterConfig.resourcePath)" }

    var body: some View {
        NavigationStack {
            List {
                Section("macOS") {
                    Text("Open System Settings → Printers & Scanners → Add Printer. The printer normally appears automatically (Bonjour), so manual entry is rarely needed. If you do need it, use this address:")
                    code(ippURI)
                }
                Section("Linux / CUPS") {
                    code("lpadmin -p rasa -E -v \(ippURI) -m everywhere")
                }
                Section("Windows") {
                    Text("Add a printer by URL:")
                    code(httpURI)
                }
                Section("iPhone / iPad") {
                    if service.config.compatibilityMode {
                        Text("Share → Print → select this printer.")
                    } else {
                        Text("Switch to High compatibility in Settings to print from iPhone or iPad.")
                    }
                }
                Section {
                    Text("Keep this app open — iOS stops the printer when the app is in the background.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("How to connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func code(_ text: String) -> some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.footnote.monospaced()).textSelection(.enabled)
            }
            Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy")
        }
    }
}
