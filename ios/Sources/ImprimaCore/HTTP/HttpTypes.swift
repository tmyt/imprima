import Foundation

/// Minimal HTTP model. FROZEN INTERFACE. Header names are lower-cased.
public struct HttpRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    /// De-chunked / bounded entity body (empty stream when no body). The server drains what the handler leaves.
    public var body: ByteInputStream
    public init(method: String, path: String, headers: [String: String], body: ByteInputStream) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
    public var contentType: String? { headers["content-type"] }
    public var host: String? { headers["host"] }
}

public struct HttpResponse {
    public var status: Int
    public var body: Data
    public var contentType: String
    public var headers: [String: String]
    public init(status: Int, body: Data = Data(), contentType: String = "application/octet-stream", headers: [String: String] = [:]) {
        self.status = status; self.body = body; self.contentType = contentType; self.headers = headers
    }
    public static func text(_ status: Int, _ text: String, contentType: String = "text/plain; charset=utf-8") -> HttpResponse {
        HttpResponse(status: status, body: Data(text.utf8), contentType: contentType)
    }
}

public typealias HttpHandler = (HttpRequest) -> HttpResponse
