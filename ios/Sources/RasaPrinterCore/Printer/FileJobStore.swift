import Foundation
import os

/// File-backed JobStore. FROZEN INTERFACE.
/// Documents are written to `documentsDirectory` as "<yyyyMMdd-HHmmss>_<sanitised job name>.<ext>"
/// (unique; suffix " (2)" etc. on collision); metadata JSON lives at `metadataURL` (e.g. Application Support).
public final class FileJobStore: JobStore {
    private struct JobDto: Codable {
        var id: Int32
        var name: String
        var userName: String
        var format: String
        var state: Int32
        /// Seconds since 1970.
        var createdAt: Double
        var sizeBytes: Int64 = 0
        /// File name inside documentsDirectory.
        var fileName: String?
    }

    private struct StoreDto: Codable {
        var nextId: Int32 = 1
        var jobs: [JobDto] = []
    }

    private static let log = Logger(subsystem: "com.rasa.printer", category: "FileJobStore")

    private let documentsDirectory: URL
    private let metadataURL: URL
    private let converter: DocumentConverter?
    private let fm = FileManager.default

    private let lock = NSLock()
    private var byId: [Int32: JobDto] = [:]
    private var nextId: Int32 = 1
    private var observer: (([PrintJob]) -> Void)?
    /// Bumped (under `lock`) on every change; lets `notify` drop snapshots superseded by a newer one.
    private var changeSeq: UInt64 = 0

    private let notifyLock = NSLock()
    private var deliveredSeq: UInt64 = 0

    public init(documentsDirectory: URL, metadataURL: URL, converter: DocumentConverter? = nil) {
        self.documentsDirectory = documentsDirectory
        self.metadataURL = metadataURL
        self.converter = converter
        try? fm.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: metadataURL.path) {
            do {
                let s = try JSONDecoder().decode(StoreDto.self, from: Data(contentsOf: metadataURL))
                for j in s.jobs { byId[j.id] = j }
                nextId = max(s.nextId, (byId.keys.max() ?? 0) + 1)
            } catch {
                Self.log.warning("Corrupt job metadata, starting empty: \(String(describing: error))")
                byId = [:]
                nextId = 1
            }
        }
    }

    public var onChange: (([PrintJob]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return observer }
        set { lock.lock(); observer = newValue; lock.unlock() }
    }

    public func create(name: String, userName: String, format: String) -> PrintJob {
        lock.lock()
        let dto = JobDto(id: nextId, name: name, userName: userName, format: format,
                         state: JobState.pending.rawValue, createdAt: Date().timeIntervalSince1970)
        nextId += 1
        byId[dto.id] = dto
        persistLogging()
        let job = toJob(dto)
        let change = changed()
        lock.unlock()
        notify(change)
        return job
    }

    public func writeDocument(jobId: Int32, format: String, data: ByteInputStream) throws -> PrintJob {
        lock.lock()
        let existing = byId[jobId]
        lock.unlock()
        guard let existing else { throw JobStoreError("No such job: \(jobId)") }

        let tmp = documentsDirectory.appendingPathComponent(".job\(jobId)-\(UUID().uuidString).tmp")
        var target: URL?
        do {
            try fm.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
            let size = try copy(data, to: tmp)
            let base = baseName(jobId: jobId, name: existing.name)
            lock.lock()
            do {
                defer { lock.unlock() }
                if byId[jobId] == nil {
                    try? fm.removeItem(at: tmp)
                    throw JobStoreError("Job deleted: \(jobId)")
                }
                // Reserve the final name and move the temp file there while holding the lock so concurrent
                // writes never pick the same name.
                let dest = uniqueURL(base: base, ext: Self.extensionFor(format))
                try fm.moveItem(at: tmp, to: dest)
                target = dest
            }
            var finalURL = target!
            var finalFormat = format
            var finalSize = size
            if let converter {
                let source = finalURL
                // Target names are reserved with an empty placeholder; the unused ones are removed afterwards.
                var reserved: [URL] = []
                do {
                    if let (out, outFormat) = try converter.convert(source: source, format: format, target: { ext in
                        self.lock.lock(); defer { self.lock.unlock() }
                        let u = self.uniqueURL(base: base, ext: ext, excluding: source)
                        _ = self.fm.createFile(atPath: u.path, contents: nil)
                        reserved.append(u)
                        return u
                    }) {
                        finalURL = out
                        finalFormat = outFormat
                        finalSize = (try? fm.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0
                        if !Self.samePath(out, source) { try? fm.removeItem(at: source) }
                    }
                } catch {
                    Self.log.warning("Conversion failed for job \(jobId), keeping original: \(String(describing: error))")
                    finalURL = source
                    finalFormat = format
                    finalSize = size
                }
                for u in reserved where !Self.samePath(u, finalURL) { try? fm.removeItem(at: u) }
            }
            lock.lock()
            guard var cur = byId[jobId] else {
                lock.unlock()
                try? fm.removeItem(at: finalURL)
                throw JobStoreError("Job deleted: \(jobId)")
            }
            cur.format = finalFormat
            cur.state = JobState.completed.rawValue
            cur.sizeBytes = finalSize
            cur.fileName = finalURL.lastPathComponent
            byId[jobId] = cur
            persistLogging()
            let job = toJob(cur)
            let change = changed()
            lock.unlock()
            notify(change)
            return job
        } catch let e as JobStoreError {
            throw e
        } catch {
            try? fm.removeItem(at: tmp)
            lock.lock()
            var change: Change?
            if var cur = byId[jobId] {
                cur.state = JobState.aborted.rawValue
                byId[jobId] = cur
                persistLogging()
                change = changed()
            }
            lock.unlock()
            if let change { notify(change) }
            throw error
        }
    }

    public func get(_ jobId: Int32) -> PrintJob? {
        lock.lock(); defer { lock.unlock() }
        return byId[jobId].map(toJob)
    }

    @discardableResult public func setState(_ jobId: Int32, _ state: JobState) -> PrintJob? {
        lock.lock()
        guard var cur = byId[jobId] else { lock.unlock(); return nil }
        cur.state = state.rawValue
        byId[jobId] = cur
        persistLogging()
        let job = toJob(cur)
        let change = changed()
        lock.unlock()
        notify(change)
        return job
    }

    public func delete(_ jobId: Int32) {
        lock.lock()
        guard let cur = byId.removeValue(forKey: jobId) else { lock.unlock(); return }
        if let f = cur.fileName { try? fm.removeItem(at: documentsDirectory.appendingPathComponent(f)) }
        persistLogging()
        let change = changed()
        lock.unlock()
        notify(change)
    }

    public func list() -> [PrintJob] {
        lock.lock(); defer { lock.unlock() }
        return snapshot()
    }

    // MARK: - internals

    private struct Change { let seq: UInt64; let jobs: [PrintJob]; let observer: (([PrintJob]) -> Void)? }

    // Must hold lock.
    private func snapshot() -> [PrintJob] { byId.values.sorted { $0.id > $1.id }.map(toJob) }

    // Must hold lock.
    private func changed() -> Change {
        changeSeq += 1
        return Change(seq: changeSeq, jobs: snapshot(), observer: observer)
    }

    /// Delivers outside the store lock (observers may call back into the store); stale snapshots are dropped.
    private func notify(_ change: Change) {
        guard let observer = change.observer else { return }
        notifyLock.lock(); defer { notifyLock.unlock() }
        guard change.seq > deliveredSeq else { return }
        deliveredSeq = change.seq
        observer(change.jobs)
    }

    // Must hold lock.
    private func persistLogging() {
        do { try persist() } catch { Self.log.warning("Persisting job metadata failed: \(String(describing: error))") }
    }

    // Must hold lock.
    private func persist() throws {
        let dto = StoreDto(nextId: nextId, jobs: byId.values.sorted { $0.id < $1.id })
        let data = try JSONEncoder().encode(dto)
        try data.write(to: metadataURL, options: .atomic)
    }

    // Must hold lock.
    private func toJob(_ d: JobDto) -> PrintJob {
        var url: URL?
        if let f = d.fileName {
            let u = documentsDirectory.appendingPathComponent(f)
            if fm.fileExists(atPath: u.path) { url = u }
        }
        return PrintJob(id: d.id, name: d.name, userName: d.userName, format: d.format,
                        state: JobState(rawValue: d.state) ?? .aborted,
                        createdAt: Date(timeIntervalSince1970: d.createdAt), sizeBytes: d.sizeBytes, fileURL: url)
    }

    private func copy(_ input: ByteInputStream, to url: URL) throws -> Int64 {
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var total: Int64 = 0
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = try chunk.withUnsafeMutableBufferPointer { try input.read(into: $0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { break }
            try out.write(contentsOf: chunk[0..<n])
            total += Int64(n)
        }
        try out.synchronize()
        return total
    }

    /// "<yyyyMMdd-HHmmss>_<sanitised name>" (no extension).
    private func baseName(jobId: Int32, name: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: Date()))_\(Self.sanitize(name, jobId: jobId))"
    }

    /// Letters, digits, space and "-_.()" kept; runs of anything else → "_"; trimmed, ≤ 60 chars; fallback "job<id>".
    static func sanitize(_ name: String, jobId: Int32) -> String {
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " -_.()"))
        var out = ""
        var inRun = false
        for scalar in name.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                out.append("_")
                inRun = true
            }
        }
        var clean = String(out.trimmingCharacters(in: .whitespaces).prefix(60)).trimmingCharacters(in: .whitespaces)
        // A leading "." would hide the file in Files.app / Finder.
        while clean.hasPrefix(".") { clean.removeFirst() }
        return clean.isEmpty ? "job\(jobId)" : clean
    }

    // Must hold lock.
    private func uniqueURL(base: String, ext: String, excluding: URL? = nil) -> URL {
        var n = 1
        while true {
            let candidate = documentsDirectory.appendingPathComponent(n == 1 ? "\(base).\(ext)" : "\(base) (\(n)).\(ext)")
            let isExcluded = excluding.map { Self.samePath($0, candidate) } ?? false
            if !isExcluded && !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func extensionFor(_ format: String) -> String {
        switch format.lowercased() {
        case "application/pdf": return "pdf"
        case "image/pwg-raster": return "pwg"
        case "image/urf": return "urf"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        default: return "bin"
        }
    }
}
