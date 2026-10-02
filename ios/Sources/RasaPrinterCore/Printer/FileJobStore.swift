import Foundation

/// File-backed JobStore. FROZEN INTERFACE.
/// Documents are written to `documentsDirectory` as "<yyyyMMdd-HHmmss>_<sanitised job name>.<ext>"
/// (unique; suffix " (2)" etc. on collision); metadata JSON lives at `metadataURL` (e.g. Application Support).
public final class FileJobStore: JobStore {
    public init(documentsDirectory: URL, metadataURL: URL, converter: DocumentConverter? = nil) { fatalError("TODO unit swift-printer") }
    public var onChange: (([PrintJob]) -> Void)? { get { fatalError("TODO") } set { fatalError("TODO") } }
    public func create(name: String, userName: String, format: String) -> PrintJob { fatalError("TODO unit swift-printer") }
    public func writeDocument(jobId: Int32, format: String, data: ByteInputStream) throws -> PrintJob { fatalError("TODO unit swift-printer") }
    public func get(_ jobId: Int32) -> PrintJob? { fatalError("TODO unit swift-printer") }
    @discardableResult public func setState(_ jobId: Int32, _ state: JobState) -> PrintJob? { fatalError("TODO unit swift-printer") }
    public func delete(_ jobId: Int32) { fatalError("TODO unit swift-printer") }
    public func list() -> [PrintJob] { fatalError("TODO unit swift-printer") }
}
