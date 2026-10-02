package com.rasa.printer.ipp

/**
 * IPP (RFC 8010 / 8011) data model. FROZEN INTERFACE — do not change signatures.
 */
object IppTag {
    // delimiter (group) tags
    const val OPERATION_ATTRIBUTES = 0x01
    const val JOB_ATTRIBUTES = 0x02
    const val END_OF_ATTRIBUTES = 0x03
    const val PRINTER_ATTRIBUTES = 0x04
    const val UNSUPPORTED_ATTRIBUTES = 0x05

    // out-of-band value tags
    const val UNSUPPORTED = 0x10
    const val DEFAULT = 0x11
    const val UNKNOWN = 0x12
    const val NO_VALUE = 0x13

    // value tags
    const val INTEGER = 0x21
    const val BOOLEAN = 0x22
    const val ENUM = 0x23
    const val OCTET_STRING = 0x30
    const val DATE_TIME = 0x31
    const val RESOLUTION = 0x32
    const val RANGE_OF_INTEGER = 0x33
    const val BEG_COLLECTION = 0x34
    const val TEXT_WITH_LANGUAGE = 0x35
    const val NAME_WITH_LANGUAGE = 0x36
    const val END_COLLECTION = 0x37
    const val TEXT_WITHOUT_LANGUAGE = 0x41
    const val NAME_WITHOUT_LANGUAGE = 0x42
    const val KEYWORD = 0x44
    const val URI = 0x45
    const val URI_SCHEME = 0x46
    const val CHARSET = 0x47
    const val NATURAL_LANGUAGE = 0x48
    const val MIME_MEDIA_TYPE = 0x49
    const val MEMBER_ATTR_NAME = 0x4A
}

sealed class IppValue {
    abstract val tag: Int

    data class Integer(val value: Int) : IppValue() { override val tag get() = IppTag.INTEGER }
    data class Bool(val value: Boolean) : IppValue() { override val tag get() = IppTag.BOOLEAN }
    data class Enum(val value: Int) : IppValue() { override val tag get() = IppTag.ENUM }
    data class OctetString(val value: ByteArray) : IppValue() { override val tag get() = IppTag.OCTET_STRING }
    /** 11-byte RFC 2579 DateAndTime encoding. */
    data class DateTime(val value: ByteArray) : IppValue() { override val tag get() = IppTag.DATE_TIME }
    /** units: 3 = dots per inch, 4 = dots per cm */
    data class Resolution(val xRes: Int, val yRes: Int, val units: Int = 3) : IppValue() { override val tag get() = IppTag.RESOLUTION }
    data class Range(val low: Int, val high: Int) : IppValue() { override val tag get() = IppTag.RANGE_OF_INTEGER }
    /** Collection: members are attributes (each may be multi-valued, may nest collections). */
    data class Collection(val members: List<IppAttribute>) : IppValue() { override val tag get() = IppTag.BEG_COLLECTION }
    /** textWithLanguage when [lang] != null, else textWithoutLanguage. */
    data class Text(val value: String, val lang: String? = null) : IppValue() {
        override val tag get() = if (lang == null) IppTag.TEXT_WITHOUT_LANGUAGE else IppTag.TEXT_WITH_LANGUAGE
    }
    /** nameWithLanguage when [lang] != null, else nameWithoutLanguage. */
    data class Name(val value: String, val lang: String? = null) : IppValue() {
        override val tag get() = if (lang == null) IppTag.NAME_WITHOUT_LANGUAGE else IppTag.NAME_WITH_LANGUAGE
    }
    data class Keyword(val value: String) : IppValue() { override val tag get() = IppTag.KEYWORD }
    data class Uri(val value: String) : IppValue() { override val tag get() = IppTag.URI }
    data class UriScheme(val value: String) : IppValue() { override val tag get() = IppTag.URI_SCHEME }
    data class Charset(val value: String) : IppValue() { override val tag get() = IppTag.CHARSET }
    data class NaturalLanguage(val value: String) : IppValue() { override val tag get() = IppTag.NATURAL_LANGUAGE }
    data class MimeMediaType(val value: String) : IppValue() { override val tag get() = IppTag.MIME_MEDIA_TYPE }
    /** Out-of-band values (unsupported / default / unknown / no-value): zero-length value. */
    data class OutOfBand(override val tag: Int) : IppValue()
    /** Any tag the codec does not understand; raw value bytes preserved. */
    data class Unknown(override val tag: Int, val value: ByteArray) : IppValue()

    /** String content for string-like values, null otherwise. */
    val stringValue: String?
        get() = when (this) {
            is Text -> value; is Name -> value; is Keyword -> value; is Uri -> value; is UriScheme -> value
            is Charset -> value; is NaturalLanguage -> value; is MimeMediaType -> value
            else -> null
        }

    /** Integer content for integer/enum values, null otherwise. */
    val intValue: Int?
        get() = when (this) {
            is Integer -> value; is Enum -> value
            else -> null
        }
}

data class IppAttribute(val name: String, val values: List<IppValue>) {
    constructor(name: String, vararg values: IppValue) : this(name, values.toList())
    val value: IppValue? get() = values.firstOrNull()
    val stringValue: String? get() = value?.stringValue
    val intValue: Int? get() = value?.intValue
    val stringValues: List<String> get() = values.mapNotNull { it.stringValue }
}

data class IppGroup(val tag: Int, val attributes: List<IppAttribute>) {
    operator fun get(name: String): IppAttribute? = attributes.firstOrNull { it.name == name }
}

/**
 * One IPP request or response. [code] is the operation-id (request) or status-code (response).
 */
data class IppMessage(
    val code: Int,
    val requestId: Int,
    val groups: List<IppGroup>,
    val versionMajor: Int = 2,
    val versionMinor: Int = 0,
) {
    fun group(tag: Int): IppGroup? = groups.firstOrNull { it.tag == tag }
    fun attr(groupTag: Int, name: String): IppAttribute? = group(groupTag)?.get(name)
    val operationAttributes: IppGroup? get() = group(IppTag.OPERATION_ATTRIBUTES)
    val jobAttributes: IppGroup? get() = group(IppTag.JOB_ATTRIBUTES)
}

object IppOperation {
    const val PRINT_JOB = 0x0002
    const val PRINT_URI = 0x0003
    const val VALIDATE_JOB = 0x0004
    const val CREATE_JOB = 0x0005
    const val SEND_DOCUMENT = 0x0006
    const val SEND_URI = 0x0007
    const val CANCEL_JOB = 0x0008
    const val GET_JOB_ATTRIBUTES = 0x0009
    const val GET_JOBS = 0x000A
    const val GET_PRINTER_ATTRIBUTES = 0x000B
    const val HOLD_JOB = 0x000C
    const val RELEASE_JOB = 0x000D
    const val PAUSE_PRINTER = 0x0010
    const val RESUME_PRINTER = 0x0011
    const val CLOSE_JOB = 0x003B
    const val IDENTIFY_PRINTER = 0x003C
    const val CUPS_GET_PRINTERS = 0x4002
    const val CUPS_GET_DEFAULT = 0x4001
}

object IppStatus {
    const val OK = 0x0000
    const val OK_IGNORED_OR_SUBSTITUTED = 0x0001
    const val OK_CONFLICTING = 0x0002
    const val CLIENT_ERROR_BAD_REQUEST = 0x0400
    const val CLIENT_ERROR_FORBIDDEN = 0x0401
    const val CLIENT_ERROR_NOT_AUTHENTICATED = 0x0402
    const val CLIENT_ERROR_NOT_AUTHORIZED = 0x0403
    const val CLIENT_ERROR_NOT_POSSIBLE = 0x0404
    const val CLIENT_ERROR_TIMEOUT = 0x0405
    const val CLIENT_ERROR_NOT_FOUND = 0x0406
    const val CLIENT_ERROR_GONE = 0x0407
    const val CLIENT_ERROR_REQUEST_ENTITY_TOO_LARGE = 0x0408
    const val CLIENT_ERROR_REQUEST_VALUE_TOO_LONG = 0x0409
    const val CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED = 0x040A
    const val CLIENT_ERROR_ATTRIBUTES_OR_VALUES_NOT_SUPPORTED = 0x040B
    const val CLIENT_ERROR_URI_SCHEME_NOT_SUPPORTED = 0x040C
    const val CLIENT_ERROR_CHARSET_NOT_SUPPORTED = 0x040D
    const val CLIENT_ERROR_CONFLICTING_ATTRIBUTES = 0x040E
    const val CLIENT_ERROR_COMPRESSION_NOT_SUPPORTED = 0x040F
    const val SERVER_ERROR_INTERNAL_ERROR = 0x0500
    const val SERVER_ERROR_OPERATION_NOT_SUPPORTED = 0x0501
    const val SERVER_ERROR_SERVICE_UNAVAILABLE = 0x0502
    const val SERVER_ERROR_VERSION_NOT_SUPPORTED = 0x0503
    const val SERVER_ERROR_DEVICE_ERROR = 0x0504
    const val SERVER_ERROR_TEMPORARY_ERROR = 0x0505
    const val SERVER_ERROR_NOT_ACCEPTING_JOBS = 0x0506
    const val SERVER_ERROR_BUSY = 0x0507
    const val SERVER_ERROR_JOB_CANCELED = 0x0508
}
