import Foundation

/// Reads the tags and length of a media file without decoding it: ID3 (MP3, AIFF), MP4 and
/// QuickTime atoms (M4A, MP4, MOV), FLAC, WAV and AIFF headers.
struct MediaFileInfo {
    struct Tag {
        let identifier: String
        let commonKey: String?
        let value: Any
    }

    var tags: [Tag] = []
    var duration: Double?
    var hasVideo = false
    var hasAudio = false
    var videoSize: CGSize?

    func string(_ identifier: String) -> String? {
        tags.first { $0.identifier == identifier }?.value as? String
    }
}

private final class FileReader {
    let handle: FileHandle
    let size: UInt64

    init?(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        size = (try? handle.seekToEnd()) ?? 0
    }

    deinit { try? handle.close() }

    func read(_ offset: UInt64, _ count: Int) -> [UInt8] {
        guard offset < size, count > 0 else { return [] }
        try? handle.seek(toOffset: offset)
        let length = Int(min(UInt64(count), size - offset))
        return [UInt8]((try? handle.read(upToCount: length)) ?? Data())
    }
}

private func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
    guard i + 3 < b.count else { return 0 }
    return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}

private func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
    UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4))
}

private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    guard i + 3 < b.count else { return 0 }
    return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

private func ascii(_ b: [UInt8], _ i: Int, _ n: Int) -> String {
    guard i + n <= b.count else { return "" }
    return String(decoding: b[i ..< i + n], as: UTF8.self)
}

enum TagReader {
    nonisolated(unsafe) private static var cache: [String: MediaFileInfo] = [:]
    private static let lock = NSLock()

    static func info(for url: URL) -> MediaFileInfo {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var info = MediaFileInfo()
        if let reader = FileReader(url) {
            let head = reader.read(0, 64)
            let ext = url.pathExtension.lowercased()
            if ascii(head, 0, 3) == "ID3" {
                readID3(reader, at: 0, into: &info)
                readMP3Duration(reader, &info)
                info.hasAudio = true
            } else if ascii(head, 4, 4) == "ftyp" || ["m4a", "m4v", "mp4", "mov", "m4b", "m4p", "3gp"].contains(ext) {
                readMP4(reader, &info)
            } else if ascii(head, 0, 4) == "fLaC" {
                readFLAC(reader, &info)
            } else if ascii(head, 0, 4) == "RIFF", ascii(head, 8, 4) == "WAVE" {
                readWAV(reader, &info)
            } else if ascii(head, 0, 4) == "FORM", ["AIFF", "AIFC"].contains(ascii(head, 8, 4)) {
                readAIFF(reader, &info)
            } else if ext == "mp3" {
                readMP3Duration(reader, &info)
                info.hasAudio = true
            }
            if ext == "mp3", info.tags.isEmpty { readID3v1(reader, &info) }
            if ["mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "ogv"].contains(ext) {
                info.hasVideo = true
                info.hasAudio = true
            }
            if ["ogg", "oga", "opus", "wma", "aac"].contains(ext) { info.hasAudio = true }
        }
        lock.lock()
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = info
        lock.unlock()
        return info
    }

    // MARK: ID3

    private static let id3v22: [String: String] = [
        "TT2": "TIT2", "TP1": "TPE1", "TP2": "TPE2", "TAL": "TALB", "TCO": "TCON", "TCM": "TCOM", "TRK": "TRCK",
        "TPA": "TPOS", "PIC": "APIC", "COM": "COMM", "TYE": "TYER",
    ]

    private static let id3Common: [String: String] = [
        "TIT2": "title", "TPE1": "artist", "TALB": "albumName", "APIC": "artwork", "COMM": "description", "TCOM": "creator",
    ]

    private static let id3Genres = ["Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"]

    private static func decodeText(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> String {
        var data = Array(bytes)
        switch encoding {
        case 1, 2:
            if encoding == 1, data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
                data.removeFirst(2)
                return utf16(data, littleEndian: true)
            }
            if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF { data.removeFirst(2) }
            return utf16(data, littleEndian: false)
        case 3:
            while data.last == 0 { data.removeLast() }
            return String(decoding: data, as: UTF8.self)
        default:
            while data.last == 0 { data.removeLast() }
            return String(data.map { Character(Unicode.Scalar($0)) })
        }
    }

    private static func utf16(_ data: [UInt8], littleEndian: Bool) -> String {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < data.count {
            let unit = littleEndian ? UInt16(data[i]) | UInt16(data[i + 1]) << 8 : UInt16(data[i]) << 8 | UInt16(data[i + 1])
            if unit == 0 { break }
            units.append(unit)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Splits at the first terminator for the encoding (one zero byte, or two for UTF-16).
    private static func split(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        let wide = encoding == 1 || encoding == 2
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if wide {
                if i + 1 < bytes.endIndex, bytes[i] == 0, bytes[i + 1] == 0 { return (bytes[bytes.startIndex ..< i], bytes[(i + 2)...]) }
                i += 2
            } else {
                if bytes[i] == 0 { return (bytes[bytes.startIndex ..< i], bytes[(i + 1)...]) }
                i += 1
            }
        }
        return (bytes, [])
    }

    private static func readID3(_ reader: FileReader, at offset: UInt64, into info: inout MediaFileInfo) {
        let header = reader.read(offset, 10)
        guard header.count == 10, ascii(header, 0, 3) == "ID3" else { return }
        let version = header[3]
        let flags = header[5]
        let size = Int(header[6] & 0x7F) << 21 | Int(header[7] & 0x7F) << 14 | Int(header[8] & 0x7F) << 7 | Int(header[9] & 0x7F)
        var body = reader.read(offset + 10, min(size, 32 * 1024 * 1024))
        if flags & 0x80 != 0, version < 4 {
            // Undo unsynchronisation: FF 00 -> FF.
            var out: [UInt8] = []
            out.reserveCapacity(body.count)
            var i = 0
            while i < body.count {
                out.append(body[i])
                if body[i] == 0xFF, i + 1 < body.count, body[i + 1] == 0 { i += 1 }
                i += 1
            }
            body = out
        }
        var i = 0
        if flags & 0x40 != 0, body.count > 4 {
            let extended = version == 4
                ? Int(body[0] & 0x7F) << 21 | Int(body[1] & 0x7F) << 14 | Int(body[2] & 0x7F) << 7 | Int(body[3] & 0x7F)
                : Int(be32(body, 0)) + 4
            i = extended
        }
        let idLength = version == 2 ? 3 : 4
        let headerLength = version == 2 ? 6 : 10
        while i + headerLength <= body.count {
            var id = ascii(body, i, idLength)
            guard id.first?.isLetter == true || id.first?.isNumber == true else { break }
            let frameSize: Int
            if version == 2 {
                frameSize = Int(body[i + 3]) << 16 | Int(body[i + 4]) << 8 | Int(body[i + 5])
            } else if version == 4 {
                frameSize = Int(body[i + 4] & 0x7F) << 21 | Int(body[i + 5] & 0x7F) << 14 | Int(body[i + 6] & 0x7F) << 7 | Int(body[i + 7] & 0x7F)
            } else {
                frameSize = Int(be32(body, i + 4))
            }
            let start = i + headerLength
            guard frameSize > 0, start + frameSize <= body.count else { break }
            let frame = body[start ..< start + frameSize]
            if version == 2 { id = id3v22[id] ?? id }
            i = start + frameSize
            let common = id3Common[id]
            if id.hasPrefix("T"), let encoding = frame.first {
                var text = decodeText(frame.dropFirst(), encoding: encoding)
                if id == "TCON" { text = genreName(text) }
                info.tags.append(.init(identifier: "id3/\(id)", commonKey: common, value: text))
            } else if id == "COMM", frame.count > 4, let encoding = frame.first {
                let (_, text) = split(frame.dropFirst(4), encoding: encoding)
                info.tags.append(.init(identifier: "id3/COMM", commonKey: common, value: decodeText(text, encoding: encoding)))
            } else if id == "APIC", let encoding = frame.first {
                var rest = frame.dropFirst()
                if version == 2 {
                    rest = rest.dropFirst(3)
                } else {
                    let (_, afterMime) = split(rest, encoding: 0)
                    rest = afterMime
                }
                rest = rest.dropFirst()
                let (_, picture) = split(rest, encoding: encoding)
                info.tags.append(.init(identifier: "id3/APIC", commonKey: "artwork", value: Data(picture)))
            }
        }
    }

    private static func genreName(_ raw: String) -> String {
        var text = raw
        if text.hasPrefix("("), let close = text.firstIndex(of: ")"), let number = Int(text[text.index(after: text.startIndex) ..< close]) {
            let rest = String(text[text.index(after: close)...])
            text = rest.isEmpty ? (number < id3Genres.count ? id3Genres[number] : raw) : rest
        } else if let number = Int(text), number < id3Genres.count {
            text = id3Genres[number]
        }
        return text
    }

    private static func readID3v1(_ reader: FileReader, _ info: inout MediaFileInfo) {
        guard reader.size > 128 else { return }
        let tag = reader.read(reader.size - 128, 128)
        guard ascii(tag, 0, 3) == "TAG" else { return }
        func field(_ start: Int, _ length: Int) -> String? {
            let text = decodeText(tag[start ..< start + length], encoding: 0).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        if let title = field(3, 30) { info.tags.append(.init(identifier: "id3/TIT2", commonKey: "title", value: title)) }
        if let artist = field(33, 30) { info.tags.append(.init(identifier: "id3/TPE1", commonKey: "artist", value: artist)) }
        if let album = field(63, 30) { info.tags.append(.init(identifier: "id3/TALB", commonKey: "albumName", value: album)) }
    }

    private static func readMP3Duration(_ reader: FileReader, _ info: inout MediaFileInfo) {
        var offset: UInt64 = 0
        let header = reader.read(0, 10)
        if ascii(header, 0, 3) == "ID3" {
            let size = UInt64(header[6] & 0x7F) << 21 | UInt64(header[7] & 0x7F) << 14 | UInt64(header[8] & 0x7F) << 7 | UInt64(header[9] & 0x7F)
            offset = 10 + size + (header[5] & 0x10 != 0 ? 10 : 0)
        }
        let window = reader.read(offset, 64 * 1024)
        var i = 0
        while i + 4 < window.count {
            if window[i] == 0xFF, window[i + 1] & 0xE0 == 0xE0 {
                let versionBits = (window[i + 1] >> 3) & 3
                let layerBits = (window[i + 1] >> 1) & 3
                let bitrateIndex = Int(window[i + 2] >> 4)
                let rateIndex = Int((window[i + 2] >> 2) & 3)
                if layerBits == 1, bitrateIndex > 0, bitrateIndex < 15, rateIndex < 3, versionBits != 1 {
                    let mpeg1 = versionBits == 3
                    let bitrates1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                    let bitrates2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
                    let bitrate = (mpeg1 ? bitrates1 : bitrates2)[bitrateIndex] * 1000
                    let rates = mpeg1 ? [44100, 48000, 32000] : (versionBits == 2 ? [22050, 24000, 16000] : [11025, 12000, 8000])
                    let sampleRate = rates[rateIndex]
                    let samplesPerFrame = mpeg1 ? 1152 : 576
                    let mono = (window[i + 3] >> 6) == 3
                    let sideInfo = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
                    let xing = i + 4 + sideInfo
                    let tag = ascii(window, xing, 4)
                    if tag == "Xing" || tag == "Info", be32(window, xing + 4) & 1 != 0 {
                        let frames = Double(be32(window, xing + 8))
                        info.duration = frames * Double(samplesPerFrame) / Double(sampleRate)
                    } else if ascii(window, i + 36, 4) == "VBRI" {
                        let frames = Double(be32(window, i + 36 + 14))
                        info.duration = frames * Double(samplesPerFrame) / Double(sampleRate)
                    } else if bitrate > 0 {
                        info.duration = Double(reader.size - offset - UInt64(i)) * 8 / Double(bitrate)
                    }
                    return
                }
            }
            i += 1
        }
    }

    // MARK: MP4 and QuickTime

    private static let mp4Common: [String: String] = [
        "©nam": "title", "©ART": "artist", "©alb": "albumName", "covr": "artwork", "desc": "description", "©wrt": "creator",
    ]

    private static func readMP4(_ reader: FileReader, _ info: inout MediaFileInfo) {
        func walk(_ start: UInt64, _ end: UInt64, depth: Int, path: [String]) {
            var offset = start
            while offset + 8 <= end, depth < 12 {
                let header = reader.read(offset, 16)
                guard header.count >= 8 else { return }
                var size = UInt64(be32(header, 0))
                let type = String(decoding: header[4 ..< 8], as: Unicode.ASCII.self)
                var bodyStart = offset + 8
                if size == 1 {
                    size = be64(header, 8)
                    bodyStart = offset + 16
                } else if size == 0 {
                    size = end - offset
                }
                guard size >= 8, offset + size <= end + 8 else { return }
                let atomEnd = min(end, offset + size)
                switch type {
                case "moov", "trak", "mdia", "udta", "ilst", "minf":
                    walk(bodyStart, atomEnd, depth: depth + 1, path: path + [type])
                case "meta":
                    // A full box: version and flags come first (except in some QuickTime files).
                    let peek = reader.read(bodyStart, 8)
                    let skip: UInt64 = ascii(peek, 4, 4) == "hdlr" ? 0 : 4
                    walk(bodyStart + skip, atomEnd, depth: depth + 1, path: path + [type])
                case "mvhd":
                    let box = reader.read(bodyStart, 32)
                    if box.first == 1 {
                        let timescale = Double(be32(box, 20))
                        let duration = Double(be64(box, 24))
                        if timescale > 0 { info.duration = duration / timescale }
                    } else {
                        let timescale = Double(be32(box, 12))
                        let duration = Double(be32(box, 16))
                        if timescale > 0 { info.duration = duration / timescale }
                    }
                case "hdlr" where path.last == "mdia":
                    let box = reader.read(bodyStart, 12)
                    let handler = ascii(box, 8, 4)
                    if handler == "vide" { info.hasVideo = true }
                    if handler == "soun" { info.hasAudio = true }
                case "tkhd":
                    let box = reader.read(bodyStart, 96)
                    let base = box.first == 1 ? 88 : 76
                    let width = Double(be32(box, base)) / 65536
                    let height = Double(be32(box, base + 4)) / 65536
                    if width > 0, height > 0 { info.videoSize = CGSize(width: width, height: height) }
                default:
                    if path.last == "ilst" {
                        readIlstItem(reader, type: type, start: bodyStart, end: atomEnd, into: &info)
                    }
                }
                offset += size
            }
        }
        walk(0, reader.size, depth: 0, path: [])
    }

    private static func readIlstItem(_ reader: FileReader, type: String, start: UInt64, end: UInt64, into info: inout MediaFileInfo) {
        let length = Int(min(end - start, 32 * 1024 * 1024))
        let body = reader.read(start, length)
        guard body.count >= 16, ascii(body, 4, 4) == "data" else { return }
        let dataSize = Int(be32(body, 0))
        let kind = be32(body, 8) & 0xFFFFFF
        guard dataSize >= 16, dataSize <= body.count else { return }
        let payload = body[16 ..< dataSize]
        let common = mp4Common[type]
        switch type {
        case "covr":
            info.tags.append(.init(identifier: "itsk/covr", commonKey: common, value: Data(payload)))
        case "trkn", "disk":
            let values = Array(payload)
            if values.count >= 6 {
                let number = Int(values[2]) << 8 | Int(values[3])
                let total = Int(values[4]) << 8 | Int(values[5])
                info.tags.append(.init(identifier: "itsk/\(type)", commonKey: nil, value: total > 0 ? "\(number)/\(total)" : "\(number)"))
            }
        case "gnre":
            let values = Array(payload)
            if values.count >= 2 {
                let number = Int(values[0]) << 8 | Int(values[1]) - 1
                if number >= 0, number < id3Genres.count {
                    info.tags.append(.init(identifier: "itsk/gnre", commonKey: nil, value: id3Genres[number]))
                }
            }
        default:
            if kind == 1 || kind == 0 {
                let text = String(decoding: payload, as: UTF8.self)
                info.tags.append(.init(identifier: "itsk/\(type)", commonKey: common, value: text))
            }
        }
    }

    // MARK: FLAC, WAV and AIFF

    private static let vorbisCommon: [String: String] = [
        "TITLE": "title", "ARTIST": "artist", "ALBUM": "albumName", "DESCRIPTION": "description", "COMPOSER": "creator",
    ]

    private static func readFLAC(_ reader: FileReader, _ info: inout MediaFileInfo) {
        info.hasAudio = true
        var offset: UInt64 = 4
        while offset + 4 <= reader.size {
            let header = reader.read(offset, 4)
            guard header.count == 4 else { return }
            let last = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let block = reader.read(offset + 4, min(length, 32 * 1024 * 1024))
            if type == 0, block.count >= 18 {
                let sampleRate = Int(block[10]) << 12 | Int(block[11]) << 4 | Int(block[12]) >> 4
                let total = UInt64(block[13] & 0x0F) << 32 | UInt64(be32(block, 14))
                if sampleRate > 0 { info.duration = Double(total) / Double(sampleRate) }
            } else if type == 4 {
                var i = Int(le32(block, 0)) + 4
                let count = Int(le32(block, i))
                i += 4
                for _ in 0 ..< count {
                    let size = Int(le32(block, i))
                    i += 4
                    guard i + size <= block.count else { break }
                    let entry = String(decoding: block[i ..< i + size], as: UTF8.self)
                    i += size
                    guard let equals = entry.firstIndex(of: "=") else { continue }
                    let key = entry[..<equals].uppercased()
                    let value = String(entry[entry.index(after: equals)...])
                    info.tags.append(.init(identifier: "vorbis/\(key)", commonKey: vorbisCommon[key], value: value))
                }
            } else if type == 6, block.count > 32 {
                var i = 4
                let mimeLength = Int(be32(block, i)); i += 4 + mimeLength
                let descriptionLength = Int(be32(block, i)); i += 4 + descriptionLength
                i += 16
                let dataLength = Int(be32(block, i)); i += 4
                if i + dataLength <= block.count {
                    info.tags.append(.init(identifier: "vorbis/PICTURE", commonKey: "artwork", value: Data(block[i ..< i + dataLength])))
                }
            }
            offset += 4 + UInt64(length)
            if last { return }
        }
    }

    private static func readWAV(_ reader: FileReader, _ info: inout MediaFileInfo) {
        info.hasAudio = true
        var offset: UInt64 = 12
        var byteRate = 0
        while offset + 8 <= reader.size {
            let header = reader.read(offset, 8)
            let id = ascii(header, 0, 4)
            let size = UInt64(le32(header, 4))
            if id == "fmt " {
                let fmt = reader.read(offset + 8, 16)
                byteRate = Int(le32(fmt, 8))
            } else if id == "data", byteRate > 0 {
                info.duration = Double(size) / Double(byteRate)
            }
            offset += 8 + size + (size & 1)
        }
    }

    private static func readAIFF(_ reader: FileReader, _ info: inout MediaFileInfo) {
        info.hasAudio = true
        var offset: UInt64 = 12
        while offset + 8 <= reader.size {
            let header = reader.read(offset, 8)
            let id = ascii(header, 0, 4)
            let size = UInt64(be32(header, 4))
            if id == "COMM" {
                let comm = reader.read(offset + 8, 18)
                let frames = Double(be32(comm, 2))
                let rate = extended80(Array(comm[8 ..< min(18, comm.count)]))
                if rate > 0 { info.duration = frames / rate }
            } else if id == "ID3 " || id == "id3 " {
                readID3(reader, at: offset + 8, into: &info)
            }
            offset += 8 + size + (size & 1)
        }
    }

    /// An IEEE 754 80-bit extended float, as AIFF stores its sample rate.
    static func extended80(_ b: [UInt8]) -> Double {
        guard b.count >= 10 else { return 0 }
        let exponent = Int(b[0] & 0x7F) << 8 | Int(b[1])
        var mantissa: UInt64 = 0
        for i in 2 ..< 10 { mantissa = mantissa << 8 | UInt64(b[i]) }
        if exponent == 0, mantissa == 0 { return 0 }
        let value = Double(mantissa) * pow(2, Double(exponent - 16383 - 63))
        return b[0] & 0x80 != 0 ? -value : value
    }
}
