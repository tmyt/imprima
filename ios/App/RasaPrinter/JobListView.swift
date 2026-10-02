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

/// Rows of the job list. Presentation state (preview sheet, delete dialog) is owned by the parent
/// and attached to the enclosing List: attaching `.sheet` to a `Group` inside a List Section applies
/// it to every row, and the competing presentations dismiss each other immediately.
struct JobListView: View {
    @EnvironmentObject var service: PrinterService
    @Binding var preview: PrintJob?
    @Binding var pendingDelete: PrintJob?

    var body: some View {
        if service.jobs.isEmpty {
            Text("No print jobs yet. Jobs sent to this printer appear here and in the Files app.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(service.jobs) { job in row(job) }
        }
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
