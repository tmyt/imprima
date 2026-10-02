import Foundation
import os

/// HTTP adapter: POST application/ipp → IPP; GET "/" → HTML status; GET "/icon.png". FROZEN INTERFACE.
///
/// printerUri passed to the handler = "ipp://" + Host header + PrinterConfig.resourcePath
/// (fallback host "localhost:<port>" when Host is absent).
public final class IppHttpHandler {
    private let handler: IppPrinterHandler
    private let config: () -> PrinterConfig
    private let jobs: JobStore
    private let iconPng: () -> Data?

    private static let log = Logger(subsystem: "com.rasa.printer", category: "IppHttpHandler")
    private static let maxListed = 20

    public init(handler: IppPrinterHandler, config: @escaping () -> PrinterConfig, jobs: JobStore, iconPng: @escaping () -> Data?) {
        self.handler = handler
        self.config = config
        self.jobs = jobs
        self.iconPng = iconPng
    }

    public func handle(_ request: HttpRequest) -> HttpResponse {
        let path = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? request.path
        switch request.method.uppercased() {
        case "POST":
            return handlePost(request)
        case "GET":
            switch path {
            case "/": return .text(200, statusPage(), contentType: "text/html; charset=utf-8")
            case "/icon.png":
                if let icon = iconPng() { return HttpResponse(status: 200, body: icon, contentType: "image/png") }
                return .text(404, "Not found")
            default: return .text(404, "Not found")
            }
        default:
            return HttpResponse(status: 405, body: Data("Method not allowed".utf8), contentType: "text/plain; charset=utf-8",
                                headers: ["Allow": "GET, POST"])
        }
    }

    private func handlePost(_ request: HttpRequest) -> HttpResponse {
        let type = request.contentType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard type == "application/ipp" else {
            return .text(415, "Unsupported media type: expected application/ipp")
        }
        let message: IppMessage
        do {
            message = try IppCodec.decode(request.body)
        } catch {
            Self.log.info("Malformed IPP request: \(String(describing: error))")
            return .text(400, "Bad IPP request: \(error)")
        }
        var host = request.host?.trimmingCharacters(in: .whitespaces) ?? ""
        if host.isEmpty { host = "localhost:\(config().port)" }
        let printerUri = "ipp://\(host)\(PrinterConfig.resourcePath)"
        let response = handler.handle(message, document: request.body, printerUri: printerUri)
        return HttpResponse(status: 200, body: IppCodec.encode(response), contentType: "application/ipp")
    }

    private func statusPage() -> String {
        let cfg = config()
        let list = jobs.list()
        let rows = list.prefix(Self.maxListed).map { j in
            "<tr><td>\(j.id)</td><td>\(esc(j.name))</td><td>\(esc(j.userName))</td><td>\(esc(j.format))</td>" +
                "<td>\(j.state.displayName)</td><td>\(j.sizeBytes)</td></tr>"
        }.joined(separator: "\n")
        let location = cfg.location.isEmpty ? "" : " &middot; " + esc(cfg.location)
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(esc(cfg.name))</title></head>
        <body>
        <h1>\(esc(cfg.name))</h1>
        <p>\(esc(cfg.makeAndModel))\(location)</p>
        <p>UUID: \(esc(cfg.uuid))<br>Port: \(cfg.port)<br>IPP path: \(PrinterConfig.resourcePath)<br>Jobs: \(list.count)</p>
        <table border="1" cellpadding="4">
        <tr><th>ID</th><th>Name</th><th>User</th><th>Format</th><th>State</th><th>Bytes</th></tr>
        \(rows)
        </table>
        </body></html>

        """
    }

    private func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += "&amp;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }
}
