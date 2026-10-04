import XCTest
import Compression
@testable import ImprimaCore

/// End-to-end check against CUPS' `ipptool` (present on macOS). Skipped when ipptool or its test files are missing.
final class IpptoolIntegrationTests: XCTestCase {
    private let ipptool = "/usr/bin/ipptool"
    private let testDir = URL(fileURLWithPath: "/usr/share/cups/ipptool")

    private var root: URL!
    private var store: FileJobStore!
    private var server: HttpServer!
    private var uri: String!

    override func setUpWithError() throws {
        let fm = FileManager.default
        try XCTSkipUnless(fm.isExecutableFile(atPath: ipptool), "ipptool not installed")
        try XCTSkipUnless(fm.fileExists(atPath: testDir.appendingPathComponent("ipp-everywhere.test").path), "ipptool test files missing")
        root = fm.temporaryDirectory.appendingPathComponent("imprima-ipptool-\(UUID().uuidString)")
        store = FileJobStore(documentsDirectory: root.appendingPathComponent("Documents"),
                             metadataURL: root.appendingPathComponent("jobs.json"))
    }

    private func startServer(compatibilityMode: Bool) throws {
        let config = PrinterConfig(name: "Imprima Test Printer", port: 0, uuid: "12345678-1234-1234-1234-123456789abc",
                                   compatibilityMode: compatibilityMode)
        let handler = IppPrinterHandler(config: { config }, jobs: store)
        let http = IppHttpHandler(handler: handler, config: { config }, jobs: store, iconPng: { nil })
        server = HttpServer(port: 0, handler: { http.handle($0) })
        try server.start()
        uri = "ipp://localhost:\(server.boundPort)\(PrinterConfig.resourcePath)"
    }

    override func tearDownWithError() throws {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var samplePdf: URL { testDir.appendingPathComponent("document-a4.pdf") }

    private func run(_ testFile: String, file: StaticString = #filePath, line: UInt = #line) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ipptool)
        p.arguments = ["-t", "-T", "30", "-f", samplePdf.path, uri, testDir.appendingPathComponent(testFile).path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        // Drain while running so a full pipe cannot block ipptool.
        var output = Data()
        let reader = DispatchQueue(label: "ipptool-out")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(90)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            XCTFail("ipptool timed out", file: file, line: line)
        }
        p.waitUntilExit()
        _ = done.wait(timeout: .now() + 5)
        let text = String(decoding: output, as: UTF8.self)
        print(text)
        return (p.terminationStatus, text)
    }

    func testGetPrinterAttributes() throws {
        try startServer(compatibilityMode: true)
        let (code, out) = try run("get-printer-attributes.test")
        XCTAssertEqual(0, code, out)
    }

    /// ipp-everywhere.test requires the raster formats, so it runs in compatibility mode.
    func testIppEverywhereConformance() throws {
        try startServer(compatibilityMode: true)
        let (code, out) = try run("ipp-everywhere.test")
        XCTAssertEqual(0, code, out)
    }

    func testPrintJobStoresPdf() throws {
        try startServer(compatibilityMode: true)
        try assertPrintJobStoresPdf()
    }

    func testPdfOnlyGetPrinterAttributes() throws {
        try startServer(compatibilityMode: false)
        let (code, out) = try run("get-printer-attributes.test")
        XCTAssertEqual(0, code, out)
    }

    func testPdfOnlyPrintJobStoresPdf() throws {
        try startServer(compatibilityMode: false)
        try assertPrintJobStoresPdf()
    }

    func testPdfOnlyIpp11Conformance() throws {
        try startServer(compatibilityMode: false)
        let (code, out) = try run("ipp-1.1.test")
        XCTAssertEqual(0, code, out)
    }

    private func assertPrintJobStoresPdf(file: StaticString = #filePath, line: UInt = #line) throws {
        let (code, out) = try run("print-job.test")
        XCTAssertEqual(0, code, out)
        let job = try XCTUnwrap(store.list().first)
        XCTAssertEqual(.completed, job.state)
        XCTAssertEqual("application/pdf", job.format)
        // macOS ships the sample documents gzip-compressed; ipptool inflates them before sending.
        let raw = try Data(contentsOf: samplePdf)
        let expected = raw.count > 2 && raw[0] == 0x1F && raw[1] == 0x8B ? try gunzip(raw) : raw
        let stored = try Data(contentsOf: XCTUnwrap(job.fileURL))
        XCTAssertEqual(Int64(expected.count), job.sizeBytes)
        XCTAssertEqual(expected.count, stored.count)
        XCTAssertTrue(expected == stored, "stored document differs from the sample")
    }

    func testIpp11Conformance() throws {
        try startServer(compatibilityMode: true)
        let (code, out) = try run("ipp-1.1.test")
        XCTAssertEqual(0, code, out)
    }

    /// Minimal gzip (RFC 1952) inflater over Apple's Compression raw-DEFLATE decoder.
    private func gunzip(_ data: Data) throws -> Data {
        struct GzipError: Error { let message: String }
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw GzipError(message: "not gzip") }
        let flags = b[3]
        var pos = 10
        if flags & 0x04 != 0 { pos += 2 + Int(b[pos]) | Int(b[pos + 1]) << 8 } // FEXTRA
        if flags & 0x08 != 0 { while b[pos] != 0 { pos += 1 }; pos += 1 }      // FNAME
        if flags & 0x10 != 0 { while b[pos] != 0 { pos += 1 }; pos += 1 }      // FCOMMENT
        if flags & 0x02 != 0 { pos += 2 }                                       // FHCRC
        let n = b.count
        let isize = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        let deflate = Array(b[pos..<(n - 8)])
        var out = [UInt8](repeating: 0, count: max(isize, 1) + 64)
        let written = deflate.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == isize else { throw GzipError(message: "inflate produced \(written) bytes, expected \(isize)") }
        return Data(out[0..<written])
    }
}
