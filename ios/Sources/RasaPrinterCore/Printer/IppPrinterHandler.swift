import Foundation
import os

/// IPP Everywhere operation handler, transport-agnostic. FROZEN INTERFACE.
public final class IppPrinterHandler {
    private let config: () -> PrinterConfig
    private let jobs: JobStore
    private let clock: () -> Date
    /// Printer config/state never change while this handler lives: both change times are its construction time.
    private let startTime: Date

    static let log = Logger(subsystem: "com.rasa.printer", category: "IppPrinterHandler")
    static let octetStream = "application/octet-stream"
    static let sniffBytes = 8

    public init(config: @escaping () -> PrinterConfig, jobs: JobStore, clock: @escaping () -> Date = { Date() }) {
        self.config = config
        self.jobs = jobs
        self.clock = clock
        self.startTime = clock()
    }

    /// - document: bytes following the IPP attributes (read to EOF for Print-Job / Send-Document)
    /// - printerUri: e.g. "ipp://192.168.1.5:8631/ipp/print" (from the HTTP Host header)
    public func handle(_ request: IppMessage, document: ByteInputStream, printerUri: String) -> IppMessage {
        do {
            return try dispatch(request, document, printerUri)
        } catch let e as IppError {
            return response(request, e.status, e.message)
        } catch {
            Self.log.warning("IPP operation 0x\(String(format: "%04x", request.code)) failed: \(String(describing: error))")
            return response(request, IppStatus.serverErrorInternalError, "Internal error: \(error)")
        }
    }

    private struct IppError: Error {
        let status: UInt16
        let message: String
        init(_ status: UInt16, _ message: String) { self.status = status; self.message = message }
    }

    private struct Ctx {
        let req: IppMessage
        let op: IppGroup
        let printerUri: String
        var userName: String {
            if let s = op["requesting-user-name"]?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            return "anonymous"
        }
        var requested: [String]? {
            guard let a = op["requested-attributes"] else { return nil }
            let v = a.stringValues
            return v.isEmpty ? nil : v
        }
    }

    private func dispatch(_ req: IppMessage, _ document: ByteInputStream, _ printerUri: String) throws -> IppMessage {
        if req.versionMajor != 1 && req.versionMajor != 2 {
            throw IppError(IppStatus.serverErrorVersionNotSupported, "IPP version \(req.versionMajor).\(req.versionMinor) not supported")
        }
        if req.requestId <= 0 { throw IppError(IppStatus.clientErrorBadRequest, "Invalid request-id \(req.requestId)") }
        guard let op = req.groups.first, op.tag == IppTag.operationAttributes else {
            throw IppError(IppStatus.clientErrorBadRequest, "Missing operation attributes")
        }
        // RFC 8011 §4.1.4: attributes-charset first, attributes-natural-language second.
        let attrs = op.attributes
        let first = attrs.count > 0 ? attrs[0] : nil
        let second = attrs.count > 1 ? attrs[1] : nil
        if first?.name != "attributes-charset" || first?.stringValue == nil ||
            second?.name != "attributes-natural-language" || second?.stringValue == nil {
            throw IppError(IppStatus.clientErrorBadRequest, "attributes-charset and attributes-natural-language must be the first two attributes")
        }
        // RFC 8011 §4.2: every operation targets printer-uri (job operations may use job-uri instead).
        if op["printer-uri"]?.stringValue == nil && op["job-uri"]?.stringValue == nil {
            throw IppError(IppStatus.clientErrorBadRequest, "Missing printer-uri")
        }
        let ctx = Ctx(req: req, op: op, printerUri: printerUri)
        switch req.code {
        case IppOperation.getPrinterAttributes: return getPrinterAttributes(ctx)
        case IppOperation.validateJob:
            try checkCompression(op)
            _ = try declaredFormat(op)
            return ok(req)
        case IppOperation.printJob: return try printJob(ctx, document)
        case IppOperation.createJob: return try createJob(ctx)
        case IppOperation.sendDocument: return try sendDocument(ctx, document)
        case IppOperation.closeJob: return try closeJob(ctx)
        case IppOperation.cancelJob: return try cancelJob(ctx)
        case IppOperation.getJobAttributes: return try getJobAttributes(ctx)
        case IppOperation.getJobs: return try getJobs(ctx)
        case IppOperation.identifyPrinter: return ok(req)
        case IppOperation.cancelMyJobs: return try cancelMyJobs(ctx)
        default:
            throw IppError(IppStatus.serverErrorOperationNotSupported, "Operation 0x\(String(format: "%04x", req.code)) not supported")
        }
    }

    // MARK: - printer

    private func getPrinterAttributes(_ ctx: Ctx) -> IppMessage {
        let now = clock()
        let queued = Int32(clamping: jobs.list().filter { !$0.state.isTerminal }.count)
        let all = PrinterAttributes.build(config: config(), printerUri: ctx.printerUri, queuedJobCount: queued,
                                          upTimeSeconds: upTime(now), now: now, changeTime: startTime)
        let selected: [IppAttribute]
        if let requested = ctx.requested.map(Set.init), !requested.contains("all") {
            let desc = requested.contains("printer-description")
            let tmpl = requested.contains("job-template")
            selected = all.filter { a in
                requested.contains(a.name) ||
                    (desc && PrinterAttributes.descriptionNames.contains(a.name)) ||
                    (tmpl && PrinterAttributes.jobTemplateNames.contains(a.name))
            }
        } else {
            selected = all
        }
        return ok(ctx.req, [IppGroup(IppTag.printerAttributes, selected)])
    }

    /// printer-up-time in epoch seconds (as CUPS ippeveprinter does), so time-at-* attributes share its scale.
    private func upTime(_ now: Date? = nil) -> Int32 {
        let secs = Int64((now ?? clock()).timeIntervalSince1970.rounded(.down))
        return Int32(clamping: max(1, secs))
    }

    // MARK: - jobs

    private func printJob(_ ctx: Ctx, _ document: ByteInputStream) throws -> IppMessage {
        try checkCompression(ctx.op)
        let declared = try declaredFormat(ctx.op)
        let job = jobs.create(name: jobName(ctx.op), userName: ctx.userName, format: declared ?? Self.octetStream)
        let stored = try store(job.id, declared, document)
        return ok(ctx.req, [shortJobGroup(stored, ctx.printerUri)])
    }

    private func createJob(_ ctx: Ctx) throws -> IppMessage {
        try checkCompression(ctx.op)
        let declared = try declaredFormat(ctx.op)
        let job = jobs.create(name: jobName(ctx.op), userName: ctx.userName, format: declared ?? Self.octetStream)
        return ok(ctx.req, [shortJobGroup(job, ctx.printerUri)])
    }

    private func sendDocument(_ ctx: Ctx, _ document: ByteInputStream) throws -> IppMessage {
        try checkCompression(ctx.op)
        let declared = try declaredFormat(ctx.op)
        guard case .bool = ctx.op["last-document"]?.value else {
            throw IppError(IppStatus.clientErrorBadRequest, "Missing last-document")
        }
        let job = try findJob(ctx)
        // Only single-document jobs: the document is stored and the job completed whatever last-document says.
        let head = try readHead(document)
        let stored = job.format != Self.octetStream ? job.format : nil
        let result: PrintJob
        if head.isEmpty {
            if job.fileURL != nil || job.state.isTerminal {
                result = job
            } else {
                result = try store(job.id, declared ?? stored, DataInputStream(Data()))
            }
        } else {
            if job.state.isTerminal {
                throw IppError(IppStatus.clientErrorNotPossible, "Job \(job.id) is already \(job.state.displayName)")
            }
            result = try store(job.id, declared ?? stored, PrefixedInputStream(prefix: head, rest: document), head: head)
        }
        return ok(ctx.req, [shortJobGroup(result, ctx.printerUri)])
    }

    private func closeJob(_ ctx: Ctx) throws -> IppMessage {
        let job = try findJob(ctx)
        var result = job
        if job.fileURL != nil && !job.state.isTerminal {
            result = jobs.setState(job.id, .completed) ?? job
        }
        return ok(ctx.req, [shortJobGroup(result, ctx.printerUri)])
    }

    private func cancelJob(_ ctx: Ctx) throws -> IppMessage {
        let job = try findJob(ctx)
        if job.state.isTerminal {
            throw IppError(IppStatus.clientErrorNotPossible, "Job \(job.id) is already \(job.state.displayName)")
        }
        guard jobs.setState(job.id, .canceled) != nil else {
            throw IppError(IppStatus.clientErrorNotFound, "Job \(job.id) not found")
        }
        return ok(ctx.req)
    }

    /// Cancel-My-Jobs (PWG 5100.11): the given job-ids, or every active job of requesting-user-name.
    private func cancelMyJobs(_ ctx: Ctx) throws -> IppMessage {
        let targets: [PrintJob]
        if let ids = ctx.op["job-ids"]?.values.compactMap({ $0.intValue }) {
            targets = try ids.map { id in
                guard let j = jobs.get(id) else { throw IppError(IppStatus.clientErrorNotFound, "Job \(id) not found") }
                return j
            }
        } else {
            let user = ctx.userName
            targets = jobs.list().filter { $0.userName == user }
        }
        for t in targets where !t.state.isTerminal { jobs.setState(t.id, .canceled) }
        return ok(ctx.req)
    }

    private func getJobAttributes(_ ctx: Ctx) throws -> IppMessage {
        let job = try findJob(ctx)
        let attrs = filterJob(fullJobAttributes(job, ctx.printerUri), ctx.requested)
        return ok(ctx.req, [IppGroup(IppTag.jobAttributes, attrs)])
    }

    private func getJobs(_ ctx: Ctx) throws -> IppMessage {
        let which = ctx.op["which-jobs"]?.stringValue ?? "not-completed"
        let predicate: (PrintJob) -> Bool
        switch which {
        case "completed": predicate = { $0.state.isTerminal }
        case "not-completed": predicate = { !$0.state.isTerminal }
        case "all": predicate = { _ in true }
        default:
            throw IppError(IppStatus.clientErrorAttributesOrValuesNotSupported, "which-jobs '\(which)' not supported")
        }
        let myJobs = ctx.op["my-jobs"]?.value?.boolValue == true
        let user = ctx.userName
        var limit = Int.max
        if let l = ctx.op["limit"]?.intValue, l > 0 { limit = Int(l) }
        let requested = ctx.requested ?? ["job-id", "job-uri"]
        let groups = jobs.list()
            .sorted { $0.id > $1.id }
            .filter(predicate)
            .filter { !myJobs || $0.userName == user }
            .prefix(limit)
            .map { IppGroup(IppTag.jobAttributes, filterJob(fullJobAttributes($0, ctx.printerUri), requested)) }
        return ok(ctx.req, Array(groups))
    }

    // MARK: - helpers

    private func findJob(_ ctx: Ctx) throws -> PrintJob {
        var id = ctx.op["job-id"]?.intValue
        if id == nil, let uri = ctx.op["job-uri"]?.stringValue {
            let last = uri.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? uri
            id = Int32(last)
        }
        guard let jobId = id else { throw IppError(IppStatus.clientErrorBadRequest, "Missing job-id or job-uri") }
        guard let job = jobs.get(jobId) else { throw IppError(IppStatus.clientErrorNotFound, "Job \(jobId) not found") }
        return job
    }

    private func jobName(_ op: IppGroup) -> String {
        if let s = op["job-name"]?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        return "Untitled"
    }

    private func checkCompression(_ op: IppGroup) throws {
        guard let c = op["compression"]?.stringValue else { return }
        if c.lowercased() != "none" {
            throw IppError(IppStatus.clientErrorCompressionNotSupported, "Compression '\(c)' not supported")
        }
    }

    /// Validated document-format, or nil when absent / application/octet-stream (= sniff).
    private func declaredFormat(_ op: IppGroup) throws -> String? {
        guard let raw = op["document-format"]?.stringValue else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let format = base.trimmingCharacters(in: .whitespaces).lowercased()
        if !PrinterAttributes.documentFormats.contains(format) {
            throw IppError(IppStatus.clientErrorDocumentFormatNotSupported, "Document format '\(raw)' not supported")
        }
        return format == Self.octetStream ? nil : format
    }

    /// Writes the document; sniffs the format from the first bytes when `format` is nil.
    /// `head` are bytes already read from `data` (data still yields them), if any.
    private func store(_ jobId: Int32, _ format: String?, _ data: ByteInputStream, head: [UInt8]? = nil) throws -> PrintJob {
        var stream = data
        var actual = format
        if actual == nil {
            let prefix: [UInt8]
            if let head = head {
                prefix = head
            } else {
                prefix = try readHead(data)
                stream = PrefixedInputStream(prefix: prefix, rest: data)
            }
            actual = Self.sniff(prefix)
        }
        do {
            return try jobs.writeDocument(jobId: jobId, format: actual!, data: stream)
        } catch {
            Self.log.warning("Storing document for job \(jobId) failed: \(String(describing: error))")
            throw IppError(IppStatus.serverErrorInternalError, "Failed to store document: \(error)")
        }
    }

    /// Reads up to `sniffBytes` bytes (fewer only at EOF).
    private func readHead(_ input: ByteInputStream) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: Self.sniffBytes)
        var n = 0
        try buf.withUnsafeMutableBufferPointer { p in
            while n < Self.sniffBytes {
                let r = try input.read(into: p.baseAddress! + n, maxLength: Self.sniffBytes - n)
                if r <= 0 { break }
                n += r
            }
        }
        return Array(buf[0..<n])
    }

    static func sniff(_ b: [UInt8]) -> String {
        func starts(_ p: [UInt8]) -> Bool { b.count >= p.count && Array(b[0..<p.count]) == p }
        if starts(Array("%PDF".utf8)) { return "application/pdf" }
        if starts(Array("RaS2".utf8)) { return "image/pwg-raster" }
        if starts(Array("UNIRAST".utf8)) { return "image/urf" }
        if starts([0xFF, 0xD8]) { return "image/jpeg" }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        return octetStream
    }

    private func shortJobGroup(_ job: PrintJob, _ printerUri: String) -> IppGroup {
        IppGroup(IppTag.jobAttributes, [
            IppAttribute("job-id", .integer(job.id)),
            IppAttribute("job-uri", .uri(jobUri(job, printerUri))),
            IppAttribute("job-state", .enumValue(job.state.rawValue)),
            IppAttribute("job-state-reasons", .keyword(job.state.reason)),
            IppAttribute("job-state-message", .text(job.state.message)),
        ])
    }

    private func fullJobAttributes(_ job: PrintJob, _ printerUri: String) -> [IppAttribute] {
        let created = IppValue.integer(Int32(clamping: Int64(job.createdAt.timeIntervalSince1970.rounded(.down))))
        let noValue = IppValue.outOfBand(IppTag.noValue)
        let processed = job.state != .pending && job.state != .pendingHeld
        return [
            IppAttribute("job-id", .integer(job.id)),
            IppAttribute("job-uri", .uri(jobUri(job, printerUri))),
            IppAttribute("job-printer-uri", .uri(printerUri)),
            IppAttribute("job-name", .name(job.name)),
            IppAttribute("job-originating-user-name", .name(job.userName)),
            IppAttribute("job-state", .enumValue(job.state.rawValue)),
            IppAttribute("job-state-reasons", .keyword(job.state.reason)),
            IppAttribute("job-state-message", .text(job.state.message)),
            IppAttribute("time-at-creation", created),
            IppAttribute("time-at-processing", processed ? created : noValue),
            IppAttribute("time-at-completed", job.state.isTerminal ? created : noValue),
            IppAttribute("job-printer-up-time", .integer(upTime())),
            IppAttribute("job-impressions-completed", .integer(0)),
            IppAttribute("job-k-octets", .integer(Int32(clamping: (job.sizeBytes + 1023) / 1024))),
            IppAttribute("document-format", .mimeMediaType(job.format)),
            IppAttribute("date-time-at-creation", PrinterAttributes.dateTime(job.createdAt)),
        ]
    }

    private func filterJob(_ attrs: [IppAttribute], _ requested: [String]?) -> [IppAttribute] {
        guard let requested = requested,
              !requested.contains(where: { $0 == "all" || $0 == "job-description" || $0 == "job-template" }) else { return attrs }
        let set = Set(requested)
        return attrs.filter { set.contains($0.name) }
    }

    private func jobUri(_ job: PrintJob, _ printerUri: String) -> String { "\(printerUri)/\(job.id)" }

    private func ok(_ req: IppMessage, _ groups: [IppGroup] = []) -> IppMessage {
        response(req, IppStatus.ok, nil, groups)
    }

    private func response(_ req: IppMessage, _ status: UInt16, _ message: String?, _ groups: [IppGroup] = []) -> IppMessage {
        var op = [
            IppAttribute("attributes-charset", .charset("utf-8")),
            IppAttribute("attributes-natural-language", .naturalLanguage("en")),
        ]
        if let m = message { op.append(IppAttribute("status-message", .text(m))) }
        // RFC 8011 §4.1.8: answer in the request's version when supported; 2.0 otherwise.
        let supported = req.versionMajor == 1 || req.versionMajor == 2
        return IppMessage(code: status, requestId: req.requestId,
                          groups: [IppGroup(IppTag.operationAttributes, op)] + groups,
                          versionMajor: supported ? req.versionMajor : 2,
                          versionMinor: supported ? req.versionMinor : 0)
    }
}

extension JobState {
    /// Lower-case name as used in messages and the status page ("pending_held", "completed"...).
    var displayName: String {
        switch self {
        case .pending: return "pending"
        case .pendingHeld: return "pending_held"
        case .processing: return "processing"
        case .processingStopped: return "processing_stopped"
        case .canceled: return "canceled"
        case .aborted: return "aborted"
        case .completed: return "completed"
        }
    }

    var reason: String {
        switch self {
        case .completed: return "job-completed-successfully"
        case .canceled: return "job-canceled-by-user"
        case .aborted: return "job-aborted-by-system"
        case .processing: return "job-printing"
        case .pendingHeld: return "job-hold-until-specified"
        case .processingStopped: return "printer-stopped"
        case .pending: return "none"
        }
    }

    var message: String {
        switch self {
        case .pending: return "Pending"
        case .pendingHeld: return "Held"
        case .processing: return "Processing"
        case .processingStopped: return "Stopped"
        case .canceled: return "Canceled"
        case .aborted: return "Aborted"
        case .completed: return "Completed"
        }
    }
}

/// Yields `prefix` first, then the rest of `rest` (used to give back sniffed bytes).
final class PrefixedInputStream: ByteInputStream {
    private let prefix: [UInt8]
    private var position = 0
    private let rest: ByteInputStream

    init(prefix: [UInt8], rest: ByteInputStream) { self.prefix = prefix; self.rest = rest }

    func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int {
        if maxLength <= 0 { return 0 }
        if position < prefix.count {
            let n = min(maxLength, prefix.count - position)
            prefix.withUnsafeBufferPointer { p in buffer.update(from: p.baseAddress! + position, count: n) }
            position += n
            return n
        }
        return try rest.read(into: buffer, maxLength: maxLength)
    }
}
