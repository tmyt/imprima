import SwiftUI
import QuickLook
import RasaPrinterCore

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct JobListView: View {
    @EnvironmentObject var service: PrinterService
    @State private var preview: PrintJob?
    @State private var pendingDelete: PrintJob?

    var body: some View {
        Group {
            if service.jobs.isEmpty {
                Text("No print jobs yet. Jobs sent to this printer appear here and in the Files app.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.jobs) { job in row(job) }
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
    }

    private func row(_ job: PrintJob) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name.isEmpty ? "Job \(job.id)" : job.name).font(.headline).lineLimit(1)
                Text("\(job.userName) · \(Self.formatLabel(job.format)) · \(ByteCountFormatter.string(fromByteCount: job.sizeBytes, countStyle: .file))")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(job.createdAt, style: .relative)
                    Text("· \(Self.stateLabel(job.state))")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = job.fileURL {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if job.fileURL != nil { preview = job } }
        .swipeActions {
            Button(role: .destructive) { pendingDelete = job } label: { Label("Delete", systemImage: "trash") }
        }
    }

    static func formatLabel(_ mime: String) -> String {
        switch mime.lowercased() {
        case "application/pdf": return "PDF"
        case "image/jpeg": return "JPEG"
        case "image/png": return "PNG"
        case "image/pwg-raster": return "PWG Raster"
        case "image/urf": return "URF"
        default: return mime.isEmpty ? "Unknown" : mime
        }
    }

    static func stateLabel(_ s: JobState) -> String {
        switch s {
        case .pending: return "Pending"
        case .pendingHeld: return "Held"
        case .processing: return "Processing"
        case .processingStopped: return "Stopped"
        case .canceled: return "Canceled"
        case .aborted: return "Aborted"
        case .completed: return "Completed"
        }
    }
}
