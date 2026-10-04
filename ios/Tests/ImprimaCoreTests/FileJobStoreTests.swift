import XCTest
@testable import ImprimaCore

final class FileJobStoreTests: XCTestCase {
    private var root: URL!
    private var docs: URL { root.appendingPathComponent("Documents") }
    private var meta: URL { root.appendingPathComponent("Support/jobs.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ converter: DocumentConverter? = nil) -> FileJobStore {
        FileJobStore(documentsDirectory: docs, metadataURL: meta, converter: converter)
    }

    private func stream(_ bytes: [UInt8]) -> ByteInputStream { DataInputStream(Data(bytes)) }

    /// Visible files in the documents directory (temp files are dot-prefixed).
    private func docFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: docs.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    private struct FnConverter: DocumentConverter {
        let fn: (URL, String, (String) -> URL) throws -> (URL, String)?
        func convert(source: URL, format: String, target: (String) -> URL) throws -> (URL, String)? { try fn(source, format, target) }
    }

    func testCreateWriteGet() throws {
        let store = makeStore()
        let job = store.create(name: "doc", userName: "alice", format: "application/pdf")
        XCTAssertEqual(1, job.id)
        XCTAssertEqual(.pending, job.state)
        XCTAssertNil(job.fileURL)
        let bytes = (0..<1000).map { UInt8(truncatingIfNeeded: $0) }
        let done = try store.writeDocument(jobId: job.id, format: "application/pdf", data: stream(bytes))
        XCTAssertEqual(.completed, done.state)
        XCTAssertEqual(1000, done.sizeBytes)
        let url = try XCTUnwrap(done.fileURL)
        XCTAssertEqual("pdf", url.pathExtension)
        XCTAssertEqual(Data(bytes), try Data(contentsOf: url))
        XCTAssertEqual(done, store.get(job.id))
    }

    func testIdsSurviveReopen() throws {
        let a = makeStore()
        _ = a.create(name: "a", userName: "u", format: "image/urf")
        let j2 = a.create(name: "b", userName: "u", format: "image/urf")
        _ = try a.writeDocument(jobId: j2.id, format: "image/urf", data: stream([1, 2]))
        a.delete(j2.id)
        let b = makeStore()
        XCTAssertEqual(1, b.list().count)
        XCTAssertEqual(3, b.create(name: "c", userName: "u", format: "image/png").id)
    }

    func testReopenKeepsDocument() throws {
        let a = makeStore()
        let j = a.create(name: "a", userName: "u", format: "image/jpeg")
        let written = try a.writeDocument(jobId: j.id, format: "image/jpeg", data: stream([9]))
        let got = try XCTUnwrap(makeStore().get(j.id))
        XCTAssertEqual(.completed, got.state)
        XCTAssertEqual("jpg", got.fileURL?.pathExtension)
        XCTAssertEqual(written, got)
    }

    func testSetStateAndDelete() throws {
        let s = makeStore()
        let j = s.create(name: "a", userName: "u", format: "application/pdf")
        XCTAssertEqual(.canceled, s.setState(j.id, .canceled)?.state)
        XCTAssertNil(s.setState(99, .canceled))
        let f = try XCTUnwrap(try s.writeDocument(jobId: j.id, format: "application/pdf", data: stream([1])).fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        s.delete(j.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertNil(s.get(j.id))
        s.delete(j.id)
    }

    func testUnknownIdThrows() {
        XCTAssertThrowsError(try makeStore().writeDocument(jobId: 5, format: "application/pdf", data: stream([]))) { e in
            XCTAssertTrue(e is JobStoreError, "\(e)")
        }
    }

    func testOnChangeNewestFirst() {
        let s = makeStore()
        var seen: [[Int32]] = []
        s.onChange = { seen.append($0.map { $0.id }) }
        _ = s.create(name: "a", userName: "u", format: "x")
        _ = s.create(name: "b", userName: "u", format: "x")
        _ = s.create(name: "c", userName: "u", format: "x")
        XCTAssertEqual([3, 2, 1], s.list().map { $0.id })
        XCTAssertEqual([[1], [2, 1], [3, 2, 1]], seen)
        s.setState(2, .canceled)
        s.delete(1)
        XCTAssertEqual([[3, 2, 1], [3, 2]], Array(seen.suffix(2)))
    }

    func testCorruptMetadataStartsEmpty() throws {
        try FileManager.default.createDirectory(at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: meta)
        let s = makeStore()
        XCTAssertTrue(s.list().isEmpty)
        XCTAssertEqual(1, s.create(name: "a", userName: "u", format: "x").id)
    }

    func testConverterReplacesFile() throws {
        let s = makeStore(FnConverter { _, _, target in
            let out = target("pdf")
            try Data("PDF".utf8).write(to: out)
            return (out, "application/pdf")
        })
        let j = s.create(name: "a", userName: "u", format: "image/urf")
        let done = try s.writeDocument(jobId: j.id, format: "image/urf", data: stream([1, 2, 3]))
        XCTAssertEqual("application/pdf", done.format)
        XCTAssertEqual("pdf", done.fileURL?.pathExtension)
        XCTAssertEqual(3, done.sizeBytes)
        XCTAssertEqual([done.fileURL!.lastPathComponent], try docFiles()) // source .urf deleted
        XCTAssertEqual(.completed, done.state)
    }

    func testConverterNullKeepsOriginal() throws {
        let s = makeStore(FnConverter { _, _, _ in nil })
        let j = s.create(name: "a", userName: "u", format: "image/urf")
        let done = try s.writeDocument(jobId: j.id, format: "image/urf", data: stream([1, 2]))
        XCTAssertEqual("image/urf", done.format)
        XCTAssertEqual("urf", done.fileURL?.pathExtension)
    }

    func testConverterThrowKeepsOriginal() throws {
        struct Boom: Error {}
        let s = makeStore(FnConverter { _, _, target in
            _ = target("pdf")
            throw Boom()
        })
        let j = s.create(name: "a", userName: "u", format: "image/urf")
        let done = try s.writeDocument(jobId: j.id, format: "image/urf", data: stream([1, 2]))
        XCTAssertEqual(.completed, done.state)
        XCTAssertEqual("image/urf", done.format)
        XCTAssertEqual(2, done.sizeBytes)
        let url = try XCTUnwrap(done.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual([url.lastPathComponent], try docFiles()) // reserved pdf target cleaned up
    }

    // MARK: - naming (ported from the Android export displayName tests)

    func testFileNameIsTimestampAndSanitisedJobName() throws {
        let s = makeStore()
        let j = s.create(name: "my doc/1", userName: "u", format: "application/pdf")
        let done = try s.writeDocument(jobId: j.id, format: "application/pdf", data: stream(Array(repeating: 0, count: 10)))
        let name = try XCTUnwrap(done.fileURL?.lastPathComponent)
        XCTAssertNotNil(name.range(of: #"^\d{8}-\d{6}_my doc_1\.pdf$"#, options: .regularExpression), name)
        XCTAssertEqual(10, done.sizeBytes)
    }

    func testEmptyNameFallsBackToJobId() throws {
        let s = makeStore()
        let j = s.create(name: "", userName: "u", format: "application/pdf")
        let done = try s.writeDocument(jobId: j.id, format: "application/pdf", data: stream([1, 2, 3, 4]))
        let name = try XCTUnwrap(done.fileURL?.lastPathComponent)
        XCTAssertNotNil(name.range(of: #"^\d{8}-\d{6}_job1\.pdf$"#, options: .regularExpression), name)
        XCTAssertEqual(.completed, done.state)
    }

    func testSanitize() {
        XCTAssertEqual("my doc_1", FileJobStore.sanitize("my doc/1", jobId: 1))
        XCTAssertEqual("a_b", FileJobStore.sanitize("a<>:\"|?*b", jobId: 1))
        XCTAssertEqual("Résumé (final)-v2.pdf", FileJobStore.sanitize("Résumé (final)-v2.pdf", jobId: 1))
        XCTAssertEqual("job7", FileJobStore.sanitize("   ", jobId: 7))
        XCTAssertEqual(60, FileJobStore.sanitize(String(repeating: "x", count: 100), jobId: 1).count)
    }

    func testNameCollisionGetsSuffix() throws {
        let s = makeStore()
        var names: [String] = []
        for _ in 0..<3 {
            let j = s.create(name: "same", userName: "u", format: "application/pdf")
            names.append(try XCTUnwrap(try s.writeDocument(jobId: j.id, format: "application/pdf", data: stream([1])).fileURL?.lastPathComponent))
        }
        // All three may not share a timestamp second; at least all names must be distinct and suffixes well-formed.
        XCTAssertEqual(3, Set(names).count, "\(names)")
        for n in names {
            XCTAssertNotNil(n.range(of: #"^\d{8}-\d{6}_same( \([23]\))?\.pdf$"#, options: .regularExpression), n)
        }
        if names.allSatisfy({ $0.prefix(15) == names[0].prefix(15) }) {
            XCTAssertTrue(names[1].hasSuffix("_same (2).pdf"))
            XCTAssertTrue(names[2].hasSuffix("_same (3).pdf"))
        }
    }

    // MARK: - failures / concurrency

    func testIoErrorAbortsJobAndRethrows() throws {
        final class FailingStream: ByteInputStream {
            var calls = 0
            func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int {
                calls += 1
                if calls > 1 { throw StreamError.io("disconnected") }
                buffer.pointee = 0x25
                return 1
            }
        }
        let s = makeStore()
        var states: [JobState] = []
        s.onChange = { if let j = $0.first { states.append(j.state) } }
        let j = s.create(name: "a", userName: "u", format: "application/pdf")
        XCTAssertThrowsError(try s.writeDocument(jobId: j.id, format: "application/pdf", data: FailingStream())) { e in
            XCTAssertEqual(e as? StreamError, .io("disconnected"))
        }
        XCTAssertEqual(.aborted, s.get(j.id)?.state)
        XCTAssertNil(s.get(j.id)?.fileURL)
        XCTAssertEqual([.pending, .aborted], states)
        XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: docs.path)) // temp file removed
        XCTAssertEqual(.aborted, makeStore().get(j.id)?.state) // persisted
    }

    func testConcurrentWrites() throws {
        let s = makeStore()
        let n = 40
        let ids = (0..<n).map { _ in s.create(name: "same", userName: "u", format: "application/pdf").id }
        let errors = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: n) { i in
            do {
                _ = try s.writeDocument(jobId: ids[i], format: "application/pdf", data: DataInputStream(Data([UInt8(i)])))
                _ = s.list()
            } catch {
                errors.lock(); failures += 1; errors.unlock()
            }
        }
        XCTAssertEqual(0, failures)
        let jobs = s.list()
        XCTAssertEqual(n, jobs.count)
        XCTAssertTrue(jobs.allSatisfy { $0.state == .completed && $0.fileURL != nil })
        XCTAssertEqual(n, Set(jobs.compactMap { $0.fileURL?.lastPathComponent }).count)
        for j in jobs {
            let i = ids.firstIndex(of: j.id)!
            XCTAssertEqual(Data([UInt8(i)]), try Data(contentsOf: j.fileURL!))
        }
        XCTAssertEqual(n, makeStore().list().count)
    }
}
