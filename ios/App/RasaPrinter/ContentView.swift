import SwiftUI
import UIKit
import RasaPrinterCore

struct ContentView: View {
    @EnvironmentObject var service: PrinterService
    @State private var showSettings = false
    @State private var preview: PrintJob?
    @State private var pendingDelete: PrintJob?
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                Section { statusCard }
                Section {
                    JobListView(preview: $preview, pendingDelete: $pendingDelete)
                } header: {
                    HStack {
                        Text("Print jobs (\(service.jobs.count))")
                        Spacer()
                        Menu {
                            Button { openInFiles() } label: { Label("Open in Files", systemImage: "folder") }
                            Button(role: .destructive) { confirmDeleteAll = true } label: {
                                Label("Delete all…", systemImage: "trash")
                            }
                            .disabled(service.jobs.isEmpty)
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Job actions")
                    }
                }
            }
            .sheet(item: $preview) { job in
                if let url = job.fileURL { QuickLookPreview(url: url).ignoresSafeArea() }
            }
            .confirmationDialog("Delete this job?", isPresented: Binding(get: { pendingDelete != nil },
                                                                         set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { job in
                Button("Delete", role: .destructive) { service.deleteJob(job.id) }
                Button("Cancel", role: .cancel) {}
            } message: { Text($0.name) }
            .confirmationDialog("Delete all jobs?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { service.deleteAllJobs() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes \(service.jobs.count) jobs and their files.") }
            .navigationTitle("Rasa Printer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func openInFiles() {
        if let url = URL(string: "shareddocuments://" + service.documentsDirectory.path) {
            UIApplication.shared.open(url)
        }
    }

    private var runningBinding: Binding<Bool> {
        Binding(get: { service.isRunning }, set: { $0 ? service.start() : service.stop() })
    }

    private var statusLine: String {
        let mode = service.config.compatibilityMode ? "High compatibility" : "PDF only"
        return service.isRunning ? "Running · \(mode)" : "Stopped · \(mode)"
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: runningBinding) {
                Text(service.config.name).font(.headline).lineLimit(1).truncationMode(.tail)
            }
            if let error = service.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            } else {
                Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
