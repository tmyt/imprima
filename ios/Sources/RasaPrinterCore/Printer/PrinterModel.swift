import Foundation

/// User-editable printer settings. FROZEN INTERFACE.
public struct PrinterConfig: Equatable, Codable {
    public var name: String
    /// Non-privileged TCP port (never 631).
    public var port: UInt16
    /// UUID string without "urn:uuid:".
    public var uuid: String
    public var location: String
    public var makeAndModel: String
    /// false (default): PDF-only mode - only application/pdf is accepted; no URF/PWG advertised (iOS AirPrint
    /// does not list the printer; macOS/CUPS send PDF). true: high-compatibility mode - also accepts
    /// image/urf, image/pwg-raster, image/jpeg, image/png (raster converted to PDF) and advertises AirPrint.
    public var compatibilityMode: Bool
    public static let defaultPort: UInt16 = 8631
    public static let resourcePath = "/ipp/print"
    public init(name: String, port: UInt16 = PrinterConfig.defaultPort, uuid: String, location: String = "", makeAndModel: String = "Rasa Virtual Printer", compatibilityMode: Bool = false) {
        self.name = name; self.port = port; self.uuid = uuid; self.location = location; self.makeAndModel = makeAndModel
        self.compatibilityMode = compatibilityMode
    }

    private enum CodingKeys: String, CodingKey { case name, port, uuid, location, makeAndModel, compatibilityMode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? PrinterConfig.defaultPort
        uuid = try c.decode(String.self, forKey: .uuid)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        makeAndModel = try c.decodeIfPresent(String.self, forKey: .makeAndModel) ?? "Rasa Virtual Printer"
        compatibilityMode = try c.decodeIfPresent(Bool.self, forKey: .compatibilityMode) ?? false
    }
}

/// IPP job-state enum values (RFC 8011 §5.3.7). FROZEN INTERFACE.
public enum JobState: Int32, Codable {
    case pending = 3, pendingHeld = 4, processing = 5, processingStopped = 6, canceled = 7, aborted = 8, completed = 9
    public var isTerminal: Bool { self == .completed || self == .canceled || self == .aborted }
}

/// One received print job. FROZEN INTERFACE.
public struct PrintJob: Equatable, Identifiable {
    public var id: Int32
    public var name: String
    public var userName: String
    /// MIME type of the stored document.
    public var format: String
    public var state: JobState
    public var createdAt: Date
    public var sizeBytes: Int64
    /// Stored document, nil until a document has been received.
    public var fileURL: URL?
    public init(id: Int32, name: String, userName: String, format: String, state: JobState, createdAt: Date, sizeBytes: Int64, fileURL: URL?) {
        self.id = id; self.name = name; self.userName = userName; self.format = format; self.state = state
        self.createdAt = createdAt; self.sizeBytes = sizeBytes; self.fileURL = fileURL
    }
}

public struct JobStoreError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Job persistence. FROZEN INTERFACE. Implementations must be thread-safe.
public protocol JobStore: AnyObject {
    /// Observer called (on an arbitrary thread) after every change with the full list, newest first.
    var onChange: (([PrintJob]) -> Void)? { get set }
    /// Creates a PENDING job without a document. Ids increase monotonically from 1 and survive restarts.
    func create(name: String, userName: String, format: String) -> PrintJob
    /// Stores the document (reads `data` to EOF), sets sizeBytes/format/state = completed. Throws JobStoreError
    /// if the job does not exist; rethrows I/O errors after marking the job aborted.
    func writeDocument(jobId: Int32, format: String, data: ByteInputStream) throws -> PrintJob
    func get(_ jobId: Int32) -> PrintJob?
    /// Returns the updated job, or nil if absent.
    @discardableResult func setState(_ jobId: Int32, _ state: JobState) -> PrintJob?
    /// Removes the job and its file. No-op if absent.
    func delete(_ jobId: Int32)
    /// Newest first.
    func list() -> [PrintJob]
}

/// Post-receive conversion hook. FROZEN INTERFACE. Return nil when not applicable (original kept);
/// return (url, format) to replace the stored file (the store deletes the source); throw on failure (original kept).
public protocol DocumentConverter {
    func convert(source: URL, format: String, target: (_ extension: String) -> URL) throws -> (URL, String)?
}
