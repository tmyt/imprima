import Foundation

/// IPP (RFC 8010 / 8011) data model. FROZEN INTERFACE.
public enum IppTag {
    public static let operationAttributes: UInt8 = 0x01
    public static let jobAttributes: UInt8 = 0x02
    public static let endOfAttributes: UInt8 = 0x03
    public static let printerAttributes: UInt8 = 0x04
    public static let unsupportedAttributes: UInt8 = 0x05

    public static let unsupported: UInt8 = 0x10
    public static let defaultValue: UInt8 = 0x11
    public static let unknown: UInt8 = 0x12
    public static let noValue: UInt8 = 0x13

    public static let integer: UInt8 = 0x21
    public static let boolean: UInt8 = 0x22
    public static let enumValue: UInt8 = 0x23
    public static let octetString: UInt8 = 0x30
    public static let dateTime: UInt8 = 0x31
    public static let resolution: UInt8 = 0x32
    public static let rangeOfInteger: UInt8 = 0x33
    public static let begCollection: UInt8 = 0x34
    public static let textWithLanguage: UInt8 = 0x35
    public static let nameWithLanguage: UInt8 = 0x36
    public static let endCollection: UInt8 = 0x37
    public static let textWithoutLanguage: UInt8 = 0x41
    public static let nameWithoutLanguage: UInt8 = 0x42
    public static let keyword: UInt8 = 0x44
    public static let uri: UInt8 = 0x45
    public static let uriScheme: UInt8 = 0x46
    public static let charset: UInt8 = 0x47
    public static let naturalLanguage: UInt8 = 0x48
    public static let mimeMediaType: UInt8 = 0x49
    public static let memberAttrName: UInt8 = 0x4A
}

public indirect enum IppValue: Equatable {
    case integer(Int32)
    case bool(Bool)
    case enumValue(Int32)
    case octetString(Data)
    /// 11-byte RFC 2579 DateAndTime.
    case dateTime(Data)
    /// units: 3 = dpi, 4 = dpcm
    case resolution(x: Int32, y: Int32, units: UInt8)
    case range(low: Int32, high: Int32)
    case collection([IppAttribute])
    /// textWithLanguage when lang != nil
    case text(String, lang: String?)
    /// nameWithLanguage when lang != nil
    case name(String, lang: String?)
    case keyword(String)
    case uri(String)
    case uriScheme(String)
    case charset(String)
    case naturalLanguage(String)
    case mimeMediaType(String)
    /// unsupported / default / unknown / no-value (zero-length value)
    case outOfBand(UInt8)
    /// Unrecognised tag, raw bytes preserved.
    case unknown(tag: UInt8, Data)

    public static func text(_ s: String) -> IppValue { .text(s, lang: nil) }
    public static func name(_ s: String) -> IppValue { .name(s, lang: nil) }

    public var tag: UInt8 {
        switch self {
        case .integer: return IppTag.integer
        case .bool: return IppTag.boolean
        case .enumValue: return IppTag.enumValue
        case .octetString: return IppTag.octetString
        case .dateTime: return IppTag.dateTime
        case .resolution: return IppTag.resolution
        case .range: return IppTag.rangeOfInteger
        case .collection: return IppTag.begCollection
        case .text(_, let lang): return lang == nil ? IppTag.textWithoutLanguage : IppTag.textWithLanguage
        case .name(_, let lang): return lang == nil ? IppTag.nameWithoutLanguage : IppTag.nameWithLanguage
        case .keyword: return IppTag.keyword
        case .uri: return IppTag.uri
        case .uriScheme: return IppTag.uriScheme
        case .charset: return IppTag.charset
        case .naturalLanguage: return IppTag.naturalLanguage
        case .mimeMediaType: return IppTag.mimeMediaType
        case .outOfBand(let t): return t
        case .unknown(let t, _): return t
        }
    }

    /// String content for string-like values.
    public var stringValue: String? {
        switch self {
        case .text(let s, _), .name(let s, _), .keyword(let s), .uri(let s), .uriScheme(let s),
             .charset(let s), .naturalLanguage(let s), .mimeMediaType(let s):
            return s
        default: return nil
        }
    }

    public var intValue: Int32? {
        switch self {
        case .integer(let v), .enumValue(let v): return v
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

public struct IppAttribute: Equatable {
    public var name: String
    public var values: [IppValue]
    public init(_ name: String, _ values: [IppValue]) { self.name = name; self.values = values }
    public init(_ name: String, _ value: IppValue) { self.name = name; self.values = [value] }
    public var value: IppValue? { values.first }
    public var stringValue: String? { value?.stringValue }
    public var intValue: Int32? { value?.intValue }
    public var stringValues: [String] { values.compactMap { $0.stringValue } }
}

public struct IppGroup: Equatable {
    public var tag: UInt8
    public var attributes: [IppAttribute]
    public init(_ tag: UInt8, _ attributes: [IppAttribute]) { self.tag = tag; self.attributes = attributes }
    public subscript(name: String) -> IppAttribute? { attributes.first { $0.name == name } }
}

/// One IPP request or response; `code` is the operation-id or status-code.
public struct IppMessage: Equatable {
    public var code: UInt16
    public var requestId: Int32
    public var groups: [IppGroup]
    public var versionMajor: UInt8
    public var versionMinor: UInt8
    public init(code: UInt16, requestId: Int32, groups: [IppGroup], versionMajor: UInt8 = 2, versionMinor: UInt8 = 0) {
        self.code = code; self.requestId = requestId; self.groups = groups
        self.versionMajor = versionMajor; self.versionMinor = versionMinor
    }
    public func group(_ tag: UInt8) -> IppGroup? { groups.first { $0.tag == tag } }
    public func attr(_ groupTag: UInt8, _ name: String) -> IppAttribute? { group(groupTag)?[name] }
    public var operationAttributes: IppGroup? { group(IppTag.operationAttributes) }
    public var jobAttributes: IppGroup? { group(IppTag.jobAttributes) }
}

public enum IppOperation {
    public static let printJob: UInt16 = 0x0002
    public static let printUri: UInt16 = 0x0003
    public static let validateJob: UInt16 = 0x0004
    public static let createJob: UInt16 = 0x0005
    public static let sendDocument: UInt16 = 0x0006
    public static let sendUri: UInt16 = 0x0007
    public static let cancelJob: UInt16 = 0x0008
    public static let getJobAttributes: UInt16 = 0x0009
    public static let getJobs: UInt16 = 0x000A
    public static let getPrinterAttributes: UInt16 = 0x000B
    public static let holdJob: UInt16 = 0x000C
    public static let releaseJob: UInt16 = 0x000D
    public static let pausePrinter: UInt16 = 0x0010
    public static let resumePrinter: UInt16 = 0x0011
    public static let cancelMyJobs: UInt16 = 0x0039
    public static let closeJob: UInt16 = 0x003B
    public static let identifyPrinter: UInt16 = 0x003C
}

public enum IppStatus {
    public static let ok: UInt16 = 0x0000
    public static let okIgnoredOrSubstituted: UInt16 = 0x0001
    public static let clientErrorBadRequest: UInt16 = 0x0400
    public static let clientErrorNotPossible: UInt16 = 0x0404
    public static let clientErrorNotFound: UInt16 = 0x0406
    public static let clientErrorDocumentFormatNotSupported: UInt16 = 0x040A
    public static let clientErrorAttributesOrValuesNotSupported: UInt16 = 0x040B
    public static let clientErrorCompressionNotSupported: UInt16 = 0x040F
    public static let serverErrorInternalError: UInt16 = 0x0500
    public static let serverErrorOperationNotSupported: UInt16 = 0x0501
    public static let serverErrorVersionNotSupported: UInt16 = 0x0503
}
