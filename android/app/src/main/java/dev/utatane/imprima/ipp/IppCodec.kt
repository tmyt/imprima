package dev.utatane.imprima.ipp

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

class IppDecodeException(message: String, cause: Throwable? = null) : IOException(message, cause)

/**
 * IPP binary encoding (RFC 8010). FROZEN INTERFACE.
 *
 * decode() reads header + attribute groups up to and including the end-of-attributes
 * tag (0x03) and returns; any document data following it is left UNREAD in [input]
 * so the caller can stream it. Must not read ahead beyond the end tag (no buffering
 * of the stream beyond what is consumed).
 */
object IppCodec {
    @Throws(IppDecodeException::class)
    fun decode(input: InputStream): IppMessage {
        try {
            return Decoder(Reader(input)).decodeMessage()
        } catch (e: IppDecodeException) {
            throw e
        } catch (e: EOFException) {
            throw IppDecodeException("Truncated IPP message", e)
        } catch (e: IOException) {
            throw IppDecodeException("I/O error while decoding IPP message: ${e.message}", e)
        }
    }

    fun encode(message: IppMessage): ByteArray {
        val bos = ByteArrayOutputStream()
        encode(message, bos)
        return bos.toByteArray()
    }

    fun encode(message: IppMessage, out: OutputStream) {
        // Build fully in memory first so a failed encode never emits partial output.
        val bos = ByteArrayOutputStream()
        val d = DataOutputStream(bos)
        d.writeByte(message.versionMajor)
        d.writeByte(message.versionMinor)
        d.writeShort(message.code)
        d.writeInt(message.requestId)
        for (group in message.groups) {
            if (group.tag == IppTag.END_OF_ATTRIBUTES) continue
            require(group.tag in 0x00..0x0F) { "Invalid group delimiter tag 0x${group.tag.toString(16)}" }
            d.writeByte(group.tag)
            for (attr in group.attributes) writeAttribute(d, attr.name, attr.values)
        }
        d.writeByte(IppTag.END_OF_ATTRIBUTES)
        d.flush()
        bos.writeTo(out)
    }

    // ---------------------------------------------------------------- encoding

    private fun writeAttribute(d: DataOutputStream, name: String, values: List<IppValue>) {
        if (values.isEmpty()) {
            // An attribute must carry at least one value; emit no-value.
            writeValue(d, name, IppValue.OutOfBand(IppTag.NO_VALUE))
            return
        }
        values.forEachIndexed { i, v -> writeValue(d, if (i == 0) name else "", v) }
    }

    private fun writeValue(d: DataOutputStream, name: String, value: IppValue) {
        val nameBytes = name.toByteArray(Charsets.UTF_8)
        if (value is IppValue.Collection) {
            writeHeader(d, IppTag.BEG_COLLECTION, nameBytes, 0)
            for (member in value.members) {
                writeHeader(d, IppTag.MEMBER_ATTR_NAME, ByteArray(0), 0, member.name.toByteArray(Charsets.UTF_8))
                for (mv in member.values) writeValue(d, "", mv)
            }
            writeHeader(d, IppTag.END_COLLECTION, ByteArray(0), 0)
            return
        }
        val bytes = valueBytes(value)
        writeHeader(d, value.tag, nameBytes, bytes.size, bytes)
    }

    private fun writeHeader(
        d: DataOutputStream, tag: Int, name: ByteArray, valueLen: Int, value: ByteArray? = null,
    ) {
        require(name.size <= 0xFFFF) { "Attribute name too long (${name.size} bytes)" }
        require(valueLen <= 0xFFFF) { "Attribute value too long ($valueLen bytes)" }
        d.writeByte(tag)
        d.writeShort(name.size)
        d.write(name)
        if (value != null) {
            require(value.size <= 0xFFFF) { "Attribute value too long (${value.size} bytes)" }
            d.writeShort(value.size)
            d.write(value)
        } else {
            d.writeShort(valueLen)
        }
    }

    private fun valueBytes(value: IppValue): ByteArray {
        val bos = ByteArrayOutputStream()
        val d = DataOutputStream(bos)
        when (value) {
            is IppValue.Integer -> d.writeInt(value.value)
            is IppValue.Enum -> d.writeInt(value.value)
            is IppValue.Bool -> d.writeByte(if (value.value) 1 else 0)
            is IppValue.OctetString -> d.write(value.value)
            is IppValue.DateTime -> d.write(value.value)
            is IppValue.Resolution -> { d.writeInt(value.xRes); d.writeInt(value.yRes); d.writeByte(value.units) }
            is IppValue.Range -> { d.writeInt(value.low); d.writeInt(value.high) }
            is IppValue.Text -> writeMaybeLang(d, value.value, value.lang)
            is IppValue.Name -> writeMaybeLang(d, value.value, value.lang)
            is IppValue.Keyword -> d.write(value.value.toByteArray(Charsets.UTF_8))
            is IppValue.Uri -> d.write(value.value.toByteArray(Charsets.UTF_8))
            is IppValue.UriScheme -> d.write(value.value.toByteArray(Charsets.UTF_8))
            is IppValue.Charset -> d.write(value.value.toByteArray(Charsets.UTF_8))
            is IppValue.NaturalLanguage -> d.write(value.value.toByteArray(Charsets.UTF_8))
            is IppValue.MimeMediaType -> d.write(value.value.toByteArray(Charsets.UTF_8))
            is IppValue.OutOfBand -> Unit
            is IppValue.Unknown -> d.write(value.value)
            is IppValue.Collection -> throw IllegalStateException("collections are written by writeValue")
        }
        d.flush()
        return bos.toByteArray()
    }

    private fun writeMaybeLang(d: DataOutputStream, text: String, lang: String?) {
        val t = text.toByteArray(Charsets.UTF_8)
        if (lang == null) {
            d.write(t)
        } else {
            val l = lang.toByteArray(Charsets.UTF_8)
            require(l.size <= 0xFFFF && t.size <= 0xFFFF) { "Text/language too long" }
            d.writeShort(l.size)
            d.write(l)
            d.writeShort(t.size)
            d.write(t)
        }
    }

    // ---------------------------------------------------------------- decoding

    /** Reads exact counts from the stream without any read-ahead. */
    private class Reader(private val input: InputStream) {
        fun readByte(): Int {
            val b = input.read()
            if (b < 0) throw EOFException("Unexpected end of IPP data")
            return b
        }

        fun readShort(): Int = (readByte() shl 8) or readByte()

        fun readInt(): Int = (readByte() shl 24) or (readByte() shl 16) or (readByte() shl 8) or readByte()

        fun readBytes(n: Int): ByteArray {
            val buf = ByteArray(n)
            var off = 0
            while (off < n) {
                val r = input.read(buf, off, n - off)
                if (r < 0) throw EOFException("Unexpected end of IPP data")
                off += r
            }
            return buf
        }
    }

    private class Decoder(private val r: Reader) {
        fun decodeMessage(): IppMessage {
            val major = r.readByte()
            val minor = r.readByte()
            val code = r.readShort()
            val requestId = r.readInt()

            val groups = ArrayList<IppGroup>()
            var groupTag = -1
            var attrs = ArrayList<Pair<String, MutableList<IppValue>>>()

            fun flush() {
                if (groupTag >= 0) groups.add(IppGroup(groupTag, attrs.map { IppAttribute(it.first, it.second.toList()) }))
                attrs = ArrayList()
            }

            while (true) {
                val tag = r.readByte()
                if (tag == IppTag.END_OF_ATTRIBUTES) {
                    flush()
                    break
                }
                if (tag <= 0x0F) {
                    flush()
                    groupTag = tag
                    continue
                }
                if (groupTag < 0) throw IppDecodeException("Attribute before any group delimiter")
                val name = String(r.readBytes(r.readShort()), Charsets.UTF_8)
                val value = readValue(tag)
                if (name.isEmpty()) {
                    val last = attrs.lastOrNull()
                        ?: throw IppDecodeException("Additional value without a preceding attribute")
                    last.second.add(value)
                } else {
                    attrs.add(name to mutableListOf(value))
                }
            }
            return IppMessage(code, requestId, groups, major, minor)
        }

        /** Reads value-length + value for [tag] (name already consumed). */
        private fun readValue(tag: Int): IppValue {
            val len = r.readShort()
            if (tag == IppTag.BEG_COLLECTION) {
                r.readBytes(len)
                return IppValue.Collection(readCollectionMembers())
            }
            return parseValue(tag, r.readBytes(len))
        }

        private fun readCollectionMembers(): List<IppAttribute> {
            val members = ArrayList<IppAttribute>()
            var memberName: String? = null
            var memberValues = ArrayList<IppValue>()

            fun flush() {
                memberName?.let { members.add(IppAttribute(it, memberValues)) }
                memberName = null
                memberValues = ArrayList()
            }

            while (true) {
                val tag = r.readByte()
                val nameLen = r.readShort()
                if (nameLen != 0) r.readBytes(nameLen) // name must be empty inside collections; ignore
                when (tag) {
                    IppTag.END_COLLECTION -> {
                        r.readBytes(r.readShort())
                        flush()
                        return members
                    }
                    IppTag.MEMBER_ATTR_NAME -> {
                        val nameBytes = r.readBytes(r.readShort())
                        flush()
                        memberName = String(nameBytes, Charsets.UTF_8)
                    }
                    else -> {
                        if (tag <= 0x0F) throw IppDecodeException("Unexpected delimiter 0x${tag.toString(16)} inside collection")
                        if (memberName == null) throw IppDecodeException("Collection value without memberAttrName")
                        memberValues.add(readValue(tag))
                    }
                }
            }
        }

        private fun parseValue(tag: Int, b: ByteArray): IppValue {
            fun need(n: Int) {
                if (b.size != n) throw IppDecodeException("Tag 0x${tag.toString(16)} expects $n bytes, got ${b.size}")
            }
            fun int(off: Int) =
                ((b[off].toInt() and 0xFF) shl 24) or ((b[off + 1].toInt() and 0xFF) shl 16) or
                    ((b[off + 2].toInt() and 0xFF) shl 8) or (b[off + 3].toInt() and 0xFF)
            fun str() = String(b, Charsets.UTF_8)

            return when (tag) {
                IppTag.INTEGER -> { need(4); IppValue.Integer(int(0)) }
                IppTag.ENUM -> { need(4); IppValue.Enum(int(0)) }
                IppTag.BOOLEAN -> { need(1); IppValue.Bool(b[0].toInt() != 0) }
                IppTag.OCTET_STRING -> IppValue.OctetString(b)
                IppTag.DATE_TIME -> { need(11); IppValue.DateTime(b) }
                IppTag.RESOLUTION -> { need(9); IppValue.Resolution(int(0), int(4), b[8].toInt() and 0xFF) }
                IppTag.RANGE_OF_INTEGER -> { need(8); IppValue.Range(int(0), int(4)) }
                IppTag.TEXT_WITHOUT_LANGUAGE -> IppValue.Text(str())
                IppTag.NAME_WITHOUT_LANGUAGE -> IppValue.Name(str())
                IppTag.TEXT_WITH_LANGUAGE -> parseWithLanguage(b).let { IppValue.Text(it.second, it.first) }
                IppTag.NAME_WITH_LANGUAGE -> parseWithLanguage(b).let { IppValue.Name(it.second, it.first) }
                IppTag.KEYWORD -> IppValue.Keyword(str())
                IppTag.URI -> IppValue.Uri(str())
                IppTag.URI_SCHEME -> IppValue.UriScheme(str())
                IppTag.CHARSET -> IppValue.Charset(str())
                IppTag.NATURAL_LANGUAGE -> IppValue.NaturalLanguage(str())
                IppTag.MIME_MEDIA_TYPE -> IppValue.MimeMediaType(str())
                in 0x10..0x1F -> IppValue.OutOfBand(tag)
                else -> IppValue.Unknown(tag, b)
            }
        }

        /** Returns (language, text). */
        private fun parseWithLanguage(b: ByteArray): Pair<String, String> {
            fun u16(off: Int) = ((b[off].toInt() and 0xFF) shl 8) or (b[off + 1].toInt() and 0xFF)
            if (b.size < 4) throw IppDecodeException("Truncated text/name with language")
            val langLen = u16(0)
            if (2 + langLen + 2 > b.size) throw IppDecodeException("Bad language length")
            val lang = String(b, 2, langLen, Charsets.UTF_8)
            val textLen = u16(2 + langLen)
            if (4 + langLen + textLen > b.size) throw IppDecodeException("Bad text length")
            return lang to String(b, 4 + langLen, textLen, Charsets.UTF_8)
        }
    }
}
