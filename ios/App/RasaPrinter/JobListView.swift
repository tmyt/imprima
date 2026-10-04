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
            VStack(spacing: 6) {
                Image(systemName: "printer").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("No print jobs yet").font(.headline)
                Text("Documents sent to this printer appear here and in the Files app.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            ForEach(service.jobs) { job in row(job) }
        }
    }

    private func row(_ job: PrintJob) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name.isEmpty ? String(localized: "Job \(Int(job.id))") : job.name).font(.headline).lineLimit(1)
                Text(detail(job)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if job.state != .completed {
                Text(Self.stateLabel(job.state))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Self.badgeColor(job.state).opacity(0.18), in: Capsule())
                    .foregroundStyle(Self.badgeColor(job.state))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if job.fileURL != nil { preview = job } }
        .swipeActions {
            Button(role: .destructive) { pendingDelete = job } label: { Image(systemName: "trash") }
                .accessibilityLabel("Delete")
        }
        .contextMenu {
            if let url = job.fileURL {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            Button(role: .destructive) { pendingDelete = job } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func detail(_ job: PrintJob) -> String {
        let size = ByteCountFormatter.string(fromByteCount: job.sizeBytes, countStyle: .file)
        let date = job.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        var parts = [Self.formatLabel(job.format), size, date]
        if !job.userName.isEmpty { parts.append(job.userName) }
        return parts.joined(separator: " · ")
    }

    static func badgeColor(_ s: JobState) -> Color {
        switch s {
        case .pending: return .orange
        case .aborted, .canceled: return .red
        default: return .gray
        }
    }

    static func formatLabel(_ mime: String) -> String {
        switch mime.lowercased() {
        case "application/pdf": return "PDF"
        case "image/jpeg": return "JPEG"
        case "image/png": return "PNG"
        case "image/pwg-raster": return "PWG Raster"
        case "image/urf": return "URF"
        default: return mime.isEmpty ? String(localized: "Unknown") : mime
        }
    }

    static func stateLabel(_ s: JobState) -> String {
        switch s {
        case .pending: return String(localized: "Pending")
        case .pendingHeld: return String(localized: "Held")
        case .processing: return String(localized: "Processing")
        case .processingStopped: return String(localized: "Job stopped")
        case .canceled: return String(localized: "Canceled")
        case .aborted: return String(localized: "Aborted")
        case .completed: return String(localized: "Completed")
        }
    }
}
