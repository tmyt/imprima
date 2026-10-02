import XCTest
@testable import RasaPrinterCore

final class IppPrinterHandlerTests: XCTestCase {
    private let printerUri = "ipp://192.168.1.5:8631/ipp/print"
    private let config = PrinterConfig(name: "Rasa Test", uuid: "1234-5678", location: "Desk")
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private var store: InMemoryJobStore!
    private var handler: IppPrinterHandler!
    private var requestId: Int32 = 1

    override func setUp() {
        super.setUp()
        store = InMemoryJobStore(clock: { [unowned self] in self.now })
        let cfg = config
        handler = IppPrinterHandler(config: { cfg }, jobs: store, clock: { [unowned self] in self.now })
    }

    // MARK: - helpers

    private func request(_ op: UInt16, _ attrs: IppAttribute..., charset: Bool = true, major: UInt8 = 2, minor: UInt8 = 0) -> IppMessage {
        let base: [IppAttribute] = charset ? [
            IppAttribute("attributes-charset", .charset("utf-8")),
            IppAttribute("attributes-natural-language", .naturalLanguage("en")),
            IppAttribute("printer-uri", .uri(printerUri)),
        ] : [IppAttribute("printer-uri", .uri(printerUri))]
        defer { requestId += 1 }
        return IppMessage(code: op, requestId: requestId, groups: [IppGroup(IppTag.operationAttributes, base + attrs)],
                          versionMajor: major, versionMinor: minor)
    }

    private func kw(_ name: String, _ v: String...) -> IppAttribute { IppAttribute(name, v.map { .keyword($0) }) }
    private func mime(_ v: String) -> IppAttribute { IppAttribute("document-format", .mimeMediaType(v)) }
    private func jobId(_ id: Int32) -> IppAttribute { IppAttribute("job-id", .integer(id)) }
    private func lastDoc(_ v: Bool) -> IppAttribute { IppAttribute("last-document", .bool(v)) }
    private func user(_ name: String) -> IppAttribute { IppAttribute("requesting-user-name", .name(name)) }
    /// ISO-8859-1 bytes of `s`.
    private func bytes(_ s: String) -> Data { Data(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) }
    private func body(_ d: Data) -> ByteInputStream { DataInputStream(d) }
    private var empty: ByteInputStream { DataInputStream(Data()) }

    @discardableResult
    private func send(_ req: IppMessage, _ doc: ByteInputStream? = nil, file: StaticString = #filePath, line: UInt = #line) -> IppMessage {
        let resp = handler.handle(req, document: doc ?? empty, printerUri: printerUri)
        XCTAssertEqual(req.requestId, resp.requestId, file: file, line: line)
        if req.versionMajor == 1 || req.versionMajor == 2 {
            XCTAssertEqual(req.versionMajor, resp.versionMajor, file: file, line: line)
            XCTAssertEqual(req.versionMinor, resp.versionMinor, file: file, line: line)
        } else {
            XCTAssertEqual(2, resp.versionMajor, file: file, line: line)
            XCTAssertEqual(0, resp.versionMinor, file: file, line: line)
        }
        let op = resp.groups.first
        XCTAssertEqual(IppTag.operationAttributes, op?.tag, file: file, line: line)
        XCTAssertEqual("utf-8", op?["attributes-charset"]?.stringValue, file: file, line: line)
        XCTAssertEqual("en", op?["attributes-natural-language"]?.stringValue, file: file, line: line)
        return resp
    }

    private func printerAttrs(_ requested: String...) throws -> IppGroup {
        let resp = requested.isEmpty
            ? send(request(IppOperation.getPrinterAttributes))
            : send(request(IppOperation.getPrinterAttributes, IppAttribute("requested-attributes", requested.map { .keyword($0) })))
        XCTAssertEqual(IppStatus.ok, resp.code)
        return try XCTUnwrap(resp.group(IppTag.printerAttributes))
    }

    private func createJob(_ userName: String = "alice") throws -> Int32 {
        let resp = send(request(IppOperation.createJob, user(userName)))
        XCTAssertEqual(IppStatus.ok, resp.code)
        return try XCTUnwrap(resp.jobAttributes?["job-id"]?.intValue)
    }

    private func printPdf() throws -> Int32 {
        let resp = send(request(IppOperation.printJob, mime("application/pdf")), body(bytes("%PDF-1.4 x")))
        XCTAssertEqual(IppStatus.ok, resp.code)
        return try XCTUnwrap(resp.jobAttributes?["job-id"]?.intValue)
    }

    private func jobIds(_ resp: IppMessage) -> [Int32?] {
        resp.groups.filter { $0.tag == IppTag.jobAttributes }.map { $0["job-id"]?.intValue }
    }

    private var nowSeconds: Int32 { Int32(now.timeIntervalSince1970) }

    // MARK: - Get-Printer-Attributes

    func testGetPrinterAttributesAll() throws {
        let g = try printerAttrs()
        XCTAssertEqual(printerUri, g["printer-uri-supported"]?.stringValue)
        let ops = g["operations-supported"]!.values.compactMap { $0.intValue }
        for op in [IppOperation.printJob, IppOperation.validateJob, IppOperation.createJob, IppOperation.sendDocument,
                   IppOperation.cancelJob, IppOperation.getJobAttributes, IppOperation.getJobs,
                   IppOperation.getPrinterAttributes, IppOperation.closeJob, IppOperation.identifyPrinter] {
            XCTAssertTrue(ops.contains(Int32(op)), "op \(op)")
        }
        let formats = g["document-format-supported"]!.stringValues
        for f in ["application/pdf", "image/pwg-raster", "image/urf"] { XCTAssertTrue(formats.contains(f)) }
        XCTAssertTrue(g["urf-supported"]!.stringValues.contains("V1.4"))
        XCTAssertNotNil(g["media-col-database"])
        XCTAssertEqual("urn:uuid:1234-5678", g["printer-uuid"]?.stringValue)
        XCTAssertEqual("http://192.168.1.5:8631/icon.png", g["printer-icons"]?.stringValue)
        XCTAssertEqual("http://192.168.1.5:8631/", g["printer-more-info"]?.stringValue)
        XCTAssertEqual(["ipp-everywhere"], g["ipp-features-supported"]?.stringValues)
        guard case .dateTime(let dt)? = g["printer-current-time"]?.value else { return XCTFail("printer-current-time") }
        XCTAssertEqual(11, dt.count)
        // names unique
        let names = g.attributes.map { $0.name }
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testGetPrinterAttributesExplicitAll() throws {
        XCTAssertNotNil(try printerAttrs("all")["media-col-database"])
    }

    func testPrinterDescriptionExcludesMediaColDatabase() throws {
        let g = try printerAttrs("printer-description")
        XCTAssertNil(g["media-col-database"])
        XCTAssertNotNil(g["printer-uri-supported"])
        XCTAssertNil(g["media-default"]) // job-template, not description
    }

    func testMediaColDatabaseByName() throws {
        let g = try printerAttrs("media-col-database")
        XCTAssertEqual(["media-col-database"], g.attributes.map { $0.name })
        XCTAssertEqual(5, g["media-col-database"]?.values.count)
    }

    func testJobTemplateGroupAndUnknownNames() throws {
        let g = try printerAttrs("job-template", "printer-name", "no-such-attribute")
        XCTAssertNotNil(g["media-col-default"])
        XCTAssertNotNil(g["copies-supported"])
        XCTAssertNotNil(g["printer-name"])
        XCTAssertNil(g["printer-uri-supported"])
        XCTAssertNil(g["media-col-database"])
    }

    // MARK: - Print-Job

    func testPrintJobPdf() throws {
        let doc = bytes("%PDF-1.4\n%âã body bytes \u{0000}ÿ end")
        let resp = send(request(IppOperation.printJob, mime("application/pdf"), user("bob"),
                                IppAttribute("job-name", .name("report.pdf"))), body(doc))
        XCTAssertEqual(IppStatus.ok, resp.code)
        let job = try XCTUnwrap(resp.jobAttributes)
        XCTAssertEqual(1, job["job-id"]?.intValue)
        XCTAssertEqual(9, job["job-state"]?.intValue)
        XCTAssertEqual("\(printerUri)/1", job["job-uri"]?.stringValue)
        let all = store.list()
        XCTAssertEqual(1, all.count)
        let stored = all[0]
        XCTAssertEqual(.completed, stored.state)
        XCTAssertEqual("application/pdf", stored.format)
        XCTAssertEqual("bob", stored.userName)
        XCTAssertEqual("report.pdf", stored.name)
        XCTAssertEqual(doc, store.document(1))
        XCTAssertEqual(doc, try Data(contentsOf: XCTUnwrap(stored.fileURL)))
    }

    func testPrintJobDefaultsNames() throws {
        _ = try printPdf()
        let j = try XCTUnwrap(store.get(1))
        XCTAssertEqual("anonymous", j.userName)
        XCTAssertEqual("Untitled", j.name)
    }

    func testPrintJobSniffsPwgRasterWithoutLosingBytes() {
        let doc = bytes("RaS2PwgRaster\u{0000}\u{0001}\u{0002} rest of raster data")
        let resp = send(request(IppOperation.printJob), body(doc))
        XCTAssertEqual(IppStatus.ok, resp.code)
        XCTAssertEqual("image/pwg-raster", store.get(1)?.format)
        XCTAssertEqual(doc, store.document(1))
    }

    func testPrintJobSniffsOctetStreamAndShortBodies() {
        send(request(IppOperation.printJob, mime("application/octet-stream")), body(bytes("UNIRAST\u{0000}xyz")))
        XCTAssertEqual("image/urf", store.get(1)?.format)
        send(request(IppOperation.printJob), body(Data([0xFF, 0xD8])))
        XCTAssertEqual("image/jpeg", store.get(2)?.format)
        XCTAssertEqual(Data([0xFF, 0xD8]), store.document(2))
        send(request(IppOperation.printJob), body(bytes("hi")))
        XCTAssertEqual("application/octet-stream", store.get(3)?.format)
        XCTAssertEqual(bytes("hi"), store.document(3))
    }

    func testPrintJobUnsupportedFormat() {
        let resp = send(request(IppOperation.printJob, mime("application/vnd.foo")), body(bytes("xx")))
        XCTAssertEqual(IppStatus.clientErrorDocumentFormatNotSupported, resp.code)
        XCTAssertNotNil(resp.operationAttributes?["status-message"])
        XCTAssertTrue(store.list().isEmpty)
    }

    func testPrintJobCompressionNotSupported() {
        let resp = send(request(IppOperation.printJob, kw("compression", "gzip")), body(bytes("%PDF")))
        XCTAssertEqual(IppStatus.clientErrorCompressionNotSupported, resp.code)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testPrintJobStorageFailure() {
        store.failWrites = true
        let resp = send(request(IppOperation.printJob, mime("application/pdf")), body(bytes("%PDF")))
        XCTAssertEqual(IppStatus.serverErrorInternalError, resp.code)
        XCTAssertEqual(.aborted, store.get(1)?.state)
    }

    func testValidateJob() {
        XCTAssertEqual(IppStatus.ok, send(request(IppOperation.validateJob, mime("image/urf"))).code)
        XCTAssertNil(send(request(IppOperation.validateJob)).jobAttributes)
        XCTAssertEqual(IppStatus.clientErrorDocumentFormatNotSupported,
                       send(request(IppOperation.validateJob, mime("text/plain"))).code)
        XCTAssertTrue(store.list().isEmpty)
    }

    // MARK: - Create-Job / Send-Document

    func testCreateSendGet() throws {
        let id = try createJob()
        XCTAssertEqual(.pending, store.get(id)?.state)

        let doc = bytes("%PDF-1.7 hello")
        let sendResp = send(request(IppOperation.sendDocument, jobId(id), lastDoc(true)), body(doc))
        XCTAssertEqual(IppStatus.ok, sendResp.code)
        XCTAssertEqual(9, sendResp.jobAttributes?["job-state"]?.intValue)
        XCTAssertEqual(.completed, store.get(id)?.state)
        XCTAssertEqual(doc, store.document(id))

        let get = send(request(IppOperation.getJobAttributes, jobId(id)))
        XCTAssertEqual(IppStatus.ok, get.code)
        let g = try XCTUnwrap(get.jobAttributes)
        XCTAssertEqual(9, g["job-state"]?.intValue)
        XCTAssertEqual("application/pdf", g["document-format"]?.stringValue)
        XCTAssertEqual("job-completed-successfully", g["job-state-reasons"]?.stringValue)
        XCTAssertEqual("alice", g["job-originating-user-name"]?.stringValue)
        XCTAssertEqual(printerUri, g["job-printer-uri"]?.stringValue)
        XCTAssertEqual(1, g["job-k-octets"]?.intValue)
        XCTAssertEqual(nowSeconds, g["time-at-completed"]?.intValue)
        guard case .dateTime(let dt)? = g["date-time-at-creation"]?.value else { return XCTFail("date-time-at-creation") }
        XCTAssertEqual(11, dt.count)

        let again = send(request(IppOperation.sendDocument, jobId(id), lastDoc(true)))
        XCTAssertEqual(IppStatus.ok, again.code)
        XCTAssertEqual(doc, store.document(id))

        let notPossible = send(request(IppOperation.sendDocument, jobId(id), lastDoc(true)), body(bytes("%PDF more")))
        XCTAssertEqual(IppStatus.clientErrorNotPossible, notPossible.code)
    }

    func testSendDocumentByJobUriAndLastDocumentFalse() throws {
        let id = try createJob()
        let doc = bytes("\u{0089}PNG\r\n\u{001a}\n...")
        let resp = send(request(IppOperation.sendDocument, IppAttribute("job-uri", .uri("\(printerUri)/\(id)")), lastDoc(false)), body(doc))
        XCTAssertEqual(IppStatus.ok, resp.code)
        XCTAssertEqual("image/png", store.get(id)?.format)
        XCTAssertEqual(doc, store.document(id))
    }

    func testSendDocumentUnknownJob() {
        XCTAssertEqual(IppStatus.clientErrorNotFound, send(request(IppOperation.sendDocument, jobId(42), lastDoc(true))).code)
        XCTAssertEqual(IppStatus.clientErrorBadRequest, send(request(IppOperation.sendDocument, lastDoc(true))).code)
    }

    func testGetJobAttributesFiltered() throws {
        let id = try printPdf()
        let g = try XCTUnwrap(send(request(IppOperation.getJobAttributes, jobId(id), kw("requested-attributes", "job-state", "job-name"))).jobAttributes)
        XCTAssertEqual(Set(["job-state", "job-name"]), Set(g.attributes.map { $0.name }))
        XCTAssertEqual(IppStatus.clientErrorNotFound, send(request(IppOperation.getJobAttributes, jobId(99))).code)
    }

    func testCloseJob() throws {
        let id = try createJob()
        let resp = send(request(IppOperation.closeJob, jobId(id)))
        XCTAssertEqual(IppStatus.ok, resp.code)
        XCTAssertEqual(.pending, store.get(id)?.state)
    }

    // MARK: - Cancel-Job

    func testCancelJob() throws {
        let done = try printPdf()
        XCTAssertEqual(IppStatus.clientErrorNotPossible, send(request(IppOperation.cancelJob, jobId(done))).code)
        XCTAssertEqual(.completed, store.get(done)?.state)

        let pending = try createJob()
        XCTAssertEqual(IppStatus.ok, send(request(IppOperation.cancelJob, jobId(pending))).code)
        XCTAssertEqual(.canceled, store.get(pending)?.state)
        XCTAssertEqual(IppStatus.clientErrorNotFound, send(request(IppOperation.cancelJob, jobId(77))).code)
    }

    // MARK: - Get-Jobs

    func testGetJobsCompleted() throws {
        let a = try printPdf()
        let pending = try createJob()
        let b = try printPdf()
        let c = try printPdf()

        let resp = send(request(IppOperation.getJobs, kw("which-jobs", "completed")))
        XCTAssertEqual(IppStatus.ok, resp.code)
        XCTAssertEqual([c, b, a], jobIds(resp))
        for g in resp.groups where g.tag == IppTag.jobAttributes {
            XCTAssertEqual(["job-id", "job-uri"], g.attributes.map { $0.name })
        }

        let limited = send(request(IppOperation.getJobs, kw("which-jobs", "completed"), IppAttribute("limit", .integer(2))))
        XCTAssertEqual([c, b], jobIds(limited))

        let notCompleted = send(request(IppOperation.getJobs))
        XCTAssertEqual([pending], notCompleted.groups.dropFirst().map { $0["job-id"]?.intValue })

        let all = send(request(IppOperation.getJobs, kw("which-jobs", "all"), kw("requested-attributes", "all")))
        XCTAssertEqual(4, all.groups.count - 1)
        XCTAssertNotNil(all.groups[1]["job-state"])
    }

    func testGetJobsEmptyAndMyJobs() throws {
        let emptyResp = send(request(IppOperation.getJobs))
        XCTAssertEqual(IppStatus.ok, emptyResp.code)
        XCTAssertEqual(1, emptyResp.groups.count)

        _ = try createJob("alice")
        _ = try createJob("bob")
        let mine = send(request(IppOperation.getJobs, IppAttribute("my-jobs", .bool(true)), user("bob")))
        XCTAssertEqual([2], mine.groups.dropFirst().map { $0["job-id"]?.intValue })
    }

    // MARK: - errors

    func testUnknownOperation() {
        XCTAssertEqual(IppStatus.serverErrorOperationNotSupported, send(request(0x0099)).code)
        XCTAssertEqual(IppStatus.serverErrorOperationNotSupported, send(request(IppOperation.pausePrinter)).code)
        XCTAssertEqual(IppStatus.serverErrorOperationNotSupported, send(request(0x4002 /* CUPS-Get-Printers */)).code)
    }

    func testMissingCharset() {
        XCTAssertEqual(IppStatus.clientErrorBadRequest, send(request(IppOperation.getPrinterAttributes, charset: false)).code)
        let noGroups = IppMessage(code: IppOperation.getPrinterAttributes, requestId: 5, groups: [])
        XCTAssertEqual(IppStatus.clientErrorBadRequest, send(noGroups).code)
    }

    func testUnsupportedVersion() {
        let resp = send(request(IppOperation.getPrinterAttributes, major: 3))
        XCTAssertEqual(IppStatus.serverErrorVersionNotSupported, resp.code)
        XCTAssertFalse(resp.groups.contains { $0.tag == IppTag.printerAttributes })
    }

    func testIdentifyPrinter() {
        XCTAssertEqual(IppStatus.ok, send(request(IppOperation.identifyPrinter)).code)
    }

    func testResponseEchoesSupportedRequestVersion() {
        let v11 = send(request(IppOperation.getPrinterAttributes, major: 1, minor: 1))
        XCTAssertEqual(IppStatus.ok, v11.code)
        XCTAssertEqual([1, 1], [v11.versionMajor, v11.versionMinor])

        let v20 = send(request(IppOperation.getPrinterAttributes))
        XCTAssertEqual(IppStatus.ok, v20.code)
        XCTAssertEqual([2, 0], [v20.versionMajor, v20.versionMinor])

        // errors on a supported version still echo it
        let err11 = send(request(0x0099, major: 1, minor: 1))
        XCTAssertEqual([1, 1], [err11.versionMajor, err11.versionMinor])

        let v30 = send(request(IppOperation.getPrinterAttributes, major: 3))
        XCTAssertEqual(IppStatus.serverErrorVersionNotSupported, v30.code)
        XCTAssertEqual([2, 0], [v30.versionMajor, v30.versionMinor])
    }

    func testRequestIdZeroIsBadRequest() {
        var req = request(IppOperation.getPrinterAttributes)
        req.requestId = 0
        let resp = send(req)
        XCTAssertEqual(IppStatus.clientErrorBadRequest, resp.code)
        XCTAssertNil(resp.group(IppTag.printerAttributes))
    }

    func testCharsetAndLanguageMustComeFirstInOrder() {
        let swapped = IppMessage(code: IppOperation.getPrinterAttributes, requestId: 9, groups: [
            IppGroup(IppTag.operationAttributes, [
                IppAttribute("attributes-natural-language", .naturalLanguage("en")),
                IppAttribute("attributes-charset", .charset("utf-8")),
                IppAttribute("printer-uri", .uri(printerUri)),
            ]),
        ])
        XCTAssertEqual(IppStatus.clientErrorBadRequest, send(swapped).code)
    }

    func testMissingPrinterUriIsBadRequest() {
        var req = request(IppOperation.getPrinterAttributes)
        req.groups = [IppGroup(IppTag.operationAttributes, req.groups[0].attributes.filter { $0.name != "printer-uri" })]
        let resp = send(req)
        XCTAssertEqual(IppStatus.clientErrorBadRequest, resp.code)
        XCTAssertNil(resp.group(IppTag.printerAttributes))
    }

    func testSendDocumentRequiresLastDocument() throws {
        let id = try createJob()
        XCTAssertEqual(IppStatus.clientErrorBadRequest, send(request(IppOperation.sendDocument, jobId(id)), body(bytes("%PDF"))).code)
        XCTAssertEqual(.pending, store.get(id)?.state)
    }

    func testCancelMyJobsByUser() throws {
        let done = try printPdf() // anonymous, completed
        let a1 = try createJob("alice")
        let b1 = try createJob("bob")
        let a2 = try createJob("alice")
        let g = try printerAttrs("operations-supported")
        XCTAssertTrue(g["operations-supported"]!.values.compactMap { $0.intValue }.contains(0x0039))

        let resp = send(request(IppOperation.cancelMyJobs, user("alice")))
        XCTAssertEqual(IppStatus.ok, resp.code)
        XCTAssertEqual(.canceled, store.get(a1)?.state)
        XCTAssertEqual(.canceled, store.get(a2)?.state)
        XCTAssertEqual(.pending, store.get(b1)?.state)
        XCTAssertEqual(.completed, store.get(done)?.state)
    }

    func testCancelMyJobsByJobIds() throws {
        let a = try createJob("alice")
        let b = try createJob("alice")
        let done = try printPdf()
        let ids = IppAttribute("job-ids", [.integer(a), .integer(done)])
        let resp = send(request(IppOperation.cancelMyJobs, user("alice"), ids))
        XCTAssertEqual(IppStatus.ok, resp.code)
        XCTAssertEqual(.canceled, store.get(a)?.state)
        XCTAssertEqual(.pending, store.get(b)?.state)
        XCTAssertEqual(.completed, store.get(done)?.state)
        let missing = IppAttribute("job-ids", .integer(99))
        XCTAssertEqual(IppStatus.clientErrorNotFound, send(request(IppOperation.cancelMyJobs, missing)).code)
    }

    func testEverywhereRequiredAttributes() throws {
        let g = try printerAttrs("all", "media-col-database")
        for name in [
            "finishings-default", "finishings-supported", "pages-per-minute", "pages-per-minute-color",
            "preferred-attributes-supported", "multiple-operation-time-out-action", "overrides-supported",
            "print-content-optimize-default", "print-content-optimize-supported", "print-rendering-intent-default",
            "print-rendering-intent-supported", "printer-config-change-date-time", "printer-config-change-time",
            "printer-get-attributes-supported", "printer-state-change-date-time", "printer-state-change-time",
            "printer-supply", "printer-supply-description", "printer-supply-info-uri",
        ] { XCTAssertNotNil(g[name], name) }
        guard case .octetString? = g["printer-supply"]?.value else { return XCTFail("printer-supply not octetString") }
        XCTAssertEqual(true, g["page-ranges-supported"]?.value?.boolValue)
        XCTAssertEqual(nowSeconds, g["printer-config-change-time"]?.intValue)
        XCTAssertEqual("http://192.168.1.5:8631/", g["printer-supply-info-uri"]?.stringValue)
    }

    /// Kotlin makes list() throw; Swift's JobStore methods are non-throwing, so the store fails with a
    /// non-I/O error from writeDocument instead. Either way the handler must answer 0x0500, not crash.
    func testInternalErrorDoesNotThrow() {
        final class BrokenStore: JobStore {
            struct Boom: Error {}
            let inner: InMemoryJobStore
            init(_ inner: InMemoryJobStore) { self.inner = inner }
            var onChange: (([PrintJob]) -> Void)? { get { inner.onChange } set { inner.onChange = newValue } }
            func create(name: String, userName: String, format: String) -> PrintJob { inner.create(name: name, userName: userName, format: format) }
            func writeDocument(jobId: Int32, format: String, data: ByteInputStream) throws -> PrintJob { throw Boom() }
            func get(_ jobId: Int32) -> PrintJob? { inner.get(jobId) }
            func setState(_ jobId: Int32, _ state: JobState) -> PrintJob? { inner.setState(jobId, state) }
            func delete(_ jobId: Int32) { inner.delete(jobId) }
            func list() -> [PrintJob] { inner.list() }
        }
        let cfg = config
        let h = IppPrinterHandler(config: { cfg }, jobs: BrokenStore(store), clock: { [unowned self] in self.now })
        let resp = h.handle(request(IppOperation.printJob), document: body(bytes("%PDF")), printerUri: printerUri)
        XCTAssertEqual(IppStatus.serverErrorInternalError, resp.code)
        XCTAssertNotNil(resp.operationAttributes?["status-message"])
    }

    /// A failing document stream (e.g. client disconnect) is an internal error too.
    func testDocumentReadErrorIsInternalError() {
        final class FailingStream: ByteInputStream {
            func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int { throw StreamError.closed }
        }
        let resp = send(request(IppOperation.printJob, mime("application/pdf")), FailingStream())
        XCTAssertEqual(IppStatus.serverErrorInternalError, resp.code)
        XCTAssertEqual(.aborted, store.get(1)?.state)
    }

    // MARK: - Swift-only helpers

    func testPrefixedInputStream() throws {
        let s = PrefixedInputStream(prefix: [1, 2, 3], rest: DataInputStream(Data([4, 5])))
        XCTAssertEqual(try s.readExactly(2), [1, 2])
        XCTAssertEqual(try s.readToEnd(), Data([3, 4, 5]))
        XCTAssertNil(try s.readByte())
    }

    func testBonjourTxt() {
        let txt = PrinterAttributes.bonjourTxt(config: config)
        XCTAssertEqual("1", txt["txtvers"])
        XCTAssertEqual("1", txt["qtotal"])
        XCTAssertEqual("ipp/print", txt["rp"])
        XCTAssertEqual("Rasa Test", txt["ty"])
        XCTAssertEqual("(Rasa Virtual Printer)", txt["product"])
        XCTAssertEqual("application/pdf,image/pwg-raster,image/urf,image/jpeg,image/png", txt["pdl"])
        XCTAssertEqual("V1.4,W8,SRGB24,CP1,RS300-600,IS1,MT1-2-3,OB9,PQ3-4-5,DM1", txt["URF"])
        XCTAssertEqual("T", txt["Color"])
        XCTAssertEqual("F", txt["Duplex"])
        XCTAssertEqual("F", txt["Scan"])
        XCTAssertEqual("F", txt["Fax"])
        XCTAssertEqual("document", txt["kind"])
        XCTAssertEqual("1234-5678", txt["UUID"])
        XCTAssertEqual("0", txt["priority"])
        XCTAssertEqual("Desk", txt["note"])
        XCTAssertNil(PrinterAttributes.bonjourTxt(config: PrinterConfig(name: "x", uuid: "y"))["note"])
    }

    func testDateTimeEncoding() {
        // 2023-11-14T22:13:20.700Z
        guard case .dateTime(let d) = PrinterAttributes.dateTime(Date(timeIntervalSince1970: 1_700_000_000.7)) else { return XCTFail() }
        XCTAssertEqual([0x07, 0xE7, 11, 14, 22, 13, 20, 7, UInt8(ascii: "+"), 0, 0], Array(d))
    }

    func testHttpBaseKeepsIpv6Authority() {
        XCTAssertEqual("http://[fe80::1]:8631", PrinterAttributes.httpBase(printerUri: "ipp://[fe80::1]:8631/ipp/print", fallbackPort: 1))
        XCTAssertEqual("https://h:1", PrinterAttributes.httpBase(printerUri: "ipps://h:1/ipp/print", fallbackPort: 1))
        XCTAssertEqual("http://localhost:9", PrinterAttributes.httpBase(printerUri: "garbage", fallbackPort: 9))
    }
}
