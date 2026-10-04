import XCTest
@testable import ImprimaCore

final class IppHttpHandlerTests: XCTestCase {
    private var cfg = PrinterConfig(name: "Imprima <Office>", uuid: "abcd-ef")
    private var store: InMemoryJobStore!
    private var icon: Data?
    private var http: IppHttpHandler!

    override func setUp() {
        super.setUp()
        store = InMemoryJobStore()
        icon = nil
        let config: () -> PrinterConfig = { [unowned self] in self.cfg }
        http = IppHttpHandler(handler: IppPrinterHandler(config: config, jobs: store), config: config, jobs: store,
                              iconPng: { [unowned self] in self.icon })
    }

    private func req(_ method: String, _ path: String, _ contentType: String? = nil, _ body: Data = Data(),
                     host: String? = "10.0.0.2:8631") -> HttpRequest {
        var headers: [String: String] = [:]
        if let contentType { headers["content-type"] = contentType }
        if let host { headers["host"] = host }
        return HttpRequest(method: method, path: path, headers: headers, body: DataInputStream(body))
    }

    private func ippRequest(_ op: UInt16, _ extra: IppAttribute...) -> IppMessage {
        IppMessage(code: op, requestId: 7, groups: [
            IppGroup(IppTag.operationAttributes, [
                IppAttribute("attributes-charset", .charset("utf-8")),
                IppAttribute("attributes-natural-language", .naturalLanguage("en")),
                IppAttribute("printer-uri", .uri("ipp://10.0.0.2:8631/ipp/print")),
            ] + extra),
        ])
    }

    func testStatusPage() {
        _ = store.create(name: "<script>", userName: "u", format: "application/pdf")
        let r = http.handle(req("GET", "/"))
        XCTAssertEqual(200, r.status)
        XCTAssertTrue(r.contentType.hasPrefix("text/html"))
        let html = String(decoding: r.body, as: UTF8.self)
        XCTAssertTrue(html.contains("Imprima &lt;Office&gt;"))
        XCTAssertTrue(html.contains("abcd-ef"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testIcon() {
        XCTAssertEqual(404, http.handle(req("GET", "/icon.png")).status)
        icon = Data([1, 2, 3])
        let r = http.handle(req("GET", "/icon.png"))
        XCTAssertEqual(200, r.status)
        XCTAssertEqual("image/png", r.contentType)
        XCTAssertEqual(Data([1, 2, 3]), r.body)
    }

    func testOtherRoutes() {
        XCTAssertEqual(404, http.handle(req("GET", "/nope")).status)
        XCTAssertEqual(405, http.handle(req("PUT", "/")).status)
        XCTAssertEqual(415, http.handle(req("POST", "/ipp/print", "text/plain", Data([1]))).status)
        XCTAssertEqual(415, http.handle(req("POST", "/ipp/print", nil)).status)
        XCTAssertEqual(400, http.handle(req("POST", "/ipp/print", "application/ipp", Data([2, 0]))).status)
    }

    func testPostGetPrinterAttributes() throws {
        let bytes = IppCodec.encode(ippRequest(IppOperation.getPrinterAttributes))
        let r = http.handle(req("POST", "/", "Application/IPP; charset=utf-8", bytes))
        XCTAssertEqual(200, r.status)
        XCTAssertEqual("application/ipp", r.contentType)
        let resp = try IppCodec.decode(DataInputStream(r.body))
        XCTAssertEqual(IppStatus.ok, resp.code)
        XCTAssertEqual(7, resp.requestId)
        XCTAssertEqual("ipp://10.0.0.2:8631/ipp/print", resp.attr(IppTag.printerAttributes, "printer-uri-supported")?.stringValue)
    }

    func testPostPrintJobStreamsDocumentAndFallsBackHost() throws {
        let doc = Data("%PDF-1.4 document after attributes".utf8)
        let bytes = IppCodec.encode(ippRequest(IppOperation.printJob)) + doc
        let r = http.handle(req("POST", "/ipp/print", "application/ipp", bytes, host: nil))
        let resp = try IppCodec.decode(DataInputStream(r.body))
        XCTAssertEqual(IppStatus.ok, resp.code)
        XCTAssertEqual("ipp://localhost:8631/ipp/print/1", resp.attr(IppTag.jobAttributes, "job-uri")?.stringValue)
        XCTAssertEqual("application/pdf", store.get(1)?.format)
        XCTAssertEqual(doc, store.document(1))
    }
}
