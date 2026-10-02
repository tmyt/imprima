import Foundation
@testable import RasaPrinterCore

/// Test-only JobStore: documents kept in memory and mirrored to temp files.
final class InMemoryJobStore: JobStore {
    private let clock: () -> Date
    private let dir: URL
    private let lock = NSLock()
    private var map: [Int32: PrintJob] = [:]
    private var docs: [Int32: Data] = [:]
    private var nextId: Int32 = 1
    private var observer: (([PrintJob]) -> Void)?

    /// When true, writeDocument fails with an I/O error (job becomes aborted).
    var failWrites = false

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rasa-jobs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var onChange: (([PrintJob]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return observer }
        set { lock.lock(); observer = newValue; lock.unlock() }
    }

    func document(_ jobId: Int32) -> Data? { lock.lock(); defer { lock.unlock() }; return docs[jobId] }

    func create(name: String, userName: String, format: String) -> PrintJob {
        lock.lock()
        let job = PrintJob(id: nextId, name: name, userName: userName, format: format, state: .pending,
                           createdAt: clock(), sizeBytes: 0, fileURL: nil)
        nextId += 1
        map[job.id] = job
        lock.unlock()
        publish()
        return job
    }

    func writeDocument(jobId: Int32, format: String, data: ByteInputStream) throws -> PrintJob {
        lock.lock()
        let exists = map[jobId] != nil
        lock.unlock()
        guard exists else { throw JobStoreError("No job \(jobId)") }
        let bytes: Data
        do {
            if failWrites { throw StreamError.io("simulated failure") }
            bytes = try data.readToEnd()
        } catch {
            setState(jobId, .aborted)
            throw error
        }
        let file = dir.appendingPathComponent("job-\(jobId).bin")
        try bytes.write(to: file)
        lock.lock()
        var job = map[jobId]!
        job.format = format
        job.sizeBytes = Int64(bytes.count)
        job.state = .completed
        job.fileURL = file
        map[jobId] = job
        docs[jobId] = bytes
        lock.unlock()
        publish()
        return job
    }

    func get(_ jobId: Int32) -> PrintJob? { lock.lock(); defer { lock.unlock() }; return map[jobId] }

    @discardableResult func setState(_ jobId: Int32, _ state: JobState) -> PrintJob? {
        lock.lock()
        guard var job = map[jobId] else { lock.unlock(); return nil }
        job.state = state
        map[jobId] = job
        lock.unlock()
        publish()
        return job
    }

    func delete(_ jobId: Int32) {
        lock.lock()
        if let f = map.removeValue(forKey: jobId)?.fileURL { try? FileManager.default.removeItem(at: f) }
        docs.removeValue(forKey: jobId)
        lock.unlock()
        publish()
    }

    func list() -> [PrintJob] { lock.lock(); defer { lock.unlock() }; return map.values.sorted { $0.id > $1.id } }

    private func publish() { onChange?(list()) }
}
