@_exported import CoreGraphics
import CPortable
import Foundation

// Text layout and drawing with TrueType fonts found on the machine, measured like Core Text:
// hhea metrics, kerning, UTF-16 string ranges.

public let kCTFontAttributeName: CFString = "NSFont"
public let kCTForegroundColorAttributeName: CFString = "CTForegroundColor"
public let kCTForegroundColorFromContextAttributeName: CFString = "CTForegroundColorFromContext"
public let kCTKernAttributeName: CFString = "NSKern"

/// A loaded font file face.
final class FontFace: @unchecked Sendable {
    let handle: OpaquePointer
    let path: String
    let index: Int
    let fullName: String
    let family: String
    let style: String
    /// The family and style that group a big family's faces, when the font names them.
    let typographicFamily: String
    let typographicStyle: String
    let postScriptName: String
    let unitsPerEm: Int
    let ascent: Float
    let descent: Float
    let lineGap: Float

    convenience init?(path: String, index: Int) {
        guard let handle = plutovg_font_face_load_from_file(path, Int32(index)) else { return nil }
        self.init(handle: handle, path: path, index: index)
    }

    /// A face from font bytes, such as a TrueType font kept inside a Mac .dfont file.
    convenience init?(data: Data, path: String, index: Int) {
        guard !data.isEmpty, data.count < Int(UInt32.max) else { return nil }
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 16)
        data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
        guard let handle = plutovg_font_face_load_from_data(bytes, UInt32(data.count), 0, { $0?.deallocate() }, bytes) else {
            bytes.deallocate()
            return nil
        }
        self.init(handle: handle, path: path, index: index)
    }

    private init(handle: OpaquePointer, path: String, index: Int) {
        self.handle = handle
        self.path = path
        self.index = index
        func name(_ id: Int32) -> String {
            var buffer = [CChar](repeating: 0, count: 256)
            let length = plutovg_font_face_name(handle, id, &buffer, Int32(buffer.count))
            guard length > 0 else { return "" }
            return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        family = name(1)
        style = name(2)
        typographicFamily = name(16)
        typographicStyle = name(17)
        let full = name(4)
        fullName = full.isEmpty ? "\(family) \(style)" : full
        postScriptName = name(6)
        unitsPerEm = Int(plutovg_font_face_units_per_em(handle))
        var a: Float = 0, d: Float = 0, g: Float = 0
        plutovg_font_face_get_metrics(handle, Float(unitsPerEm), &a, &d, &g, nil)
        ascent = a
        descent = -d
        lineGap = g
    }

    deinit {
        plutovg_font_face_destroy(handle)
    }

    func hasGlyph(_ scalar: UInt32) -> Bool {
        plutovg_font_face_glyph_index(handle, scalar) != 0
    }

    var isBold: Bool {
        let lower = style.lowercased()
        return lower.contains("bold") || lower.contains("demi") || lower.contains("black") || lower.contains("heavy")
    }
}

/// Finds fonts by name in the font folders of the machine and next to the app.
public enum FontRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var facesByName: [String: FontFace] = [:]
    nonisolated(unsafe) private static var scanned: [FontFace]?
    nonisolated(unsafe) private static var fallbackChain: [FontFace]?

    /// Extra folders to search first, such as one the user drops a font into.
    nonisolated(unsafe) public static var extraDirectories: [URL] = []

    /// What a requested name falls back to when the machine doesn't have it.
    static let substitutes: [String: [String]] = [
        "lucida grande": ["Lucida Grande", "LucidaGrande", ".Lucida Grande UI", "Lucida Grande UI", "Lucida Sans Unicode", "Lucida Sans", "Lucida Sans Regular", "DejaVu Sans", "Verdana", "Arial"],
        "helvetica neue": ["Helvetica Neue", "Helvetica", "Arial", "Liberation Sans", "DejaVu Sans"],
        "helvetica": ["Helvetica", "Arial", "Liberation Sans", "DejaVu Sans"],
    ]

    static let fallbackNames = [
        "Lucida Grande", "Lucida Sans Unicode", "DejaVu Sans", "Noto Sans", "Segoe UI", "Arial Unicode MS", "Arial",
        "Noto Sans CJK JP", "Noto Sans CJK SC", "Microsoft YaHei", "Yu Gothic", "Meiryo", "Malgun Gothic", "Noto Sans Arabic",
        "Noto Sans Hebrew", "Noto Sans Thai", "Segoe UI Symbol", "Noto Sans Symbols", "Noto Sans Symbols2", "DejaVu Sans Mono",
    ]

    static func directories() -> [URL] {
        var dirs = extraDirectories
        if let custom = ProcessInfo.processInfo.environment["FIRSTROW_FONTS"] {
            dirs.append(URL(fileURLWithPath: custom, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(Windows)
            let windows = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
            dirs.append(URL(fileURLWithPath: windows).appendingPathComponent("Fonts", isDirectory: true))
            if let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"] {
                dirs.append(URL(fileURLWithPath: local).appendingPathComponent("Microsoft/Windows/Fonts", isDirectory: true))
            }
        #else
            dirs.append(home.appendingPathComponent(".local/share/fonts", isDirectory: true))
            dirs.append(home.appendingPathComponent(".fonts", isDirectory: true))
            dirs.append(URL(fileURLWithPath: "/usr/local/share/fonts", isDirectory: true))
            dirs.append(URL(fileURLWithPath: "/usr/share/fonts", isDirectory: true))
            dirs.append(URL(fileURLWithPath: "/System/Library/Fonts", isDirectory: true))
            dirs.append(URL(fileURLWithPath: "/Library/Fonts", isDirectory: true))
        #endif
        return dirs
    }

    private static func allFaces() -> [FontFace] {
        if let scanned { return scanned }
        var faces: [FontFace] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let ext = url.pathExtension.lowercased()
            guard ext == "ttf" || ext == "ttc" || ext == "otf" || ext == "otc" || ext == "dfont" else { return }
            let path = url.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted, let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return }
            if ext == "dfont" {
                for (index, font) in MacResourceFork.sfntResources(in: data).enumerated() {
                    if let face = FontFace(data: font, path: path, index: index) { faces.append(face) }
                }
                return
            }
            let count = data.withUnsafeBytes { raw in
                raw.baseAddress.map { Int(plutovg_font_data_face_count($0)) } ?? 0
            }
            for index in 0 ..< max(1, count) {
                if let face = FontFace(path: path, index: index) {
                    faces.append(face)
                }
            }
        }
        for dir in directories() {
            // Folder links are followed, which the enumerator alone doesn't do.
            var pending = [dir.resolvingSymlinksInPath()]
            var visited = Set<String>()
            while let folder = pending.popLast() {
                guard visited.insert(folder.path).inserted, visited.count < 2000,
                      let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
                else { continue }
                for case let url as URL in walker {
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                        var isFolder: ObjCBool = false
                        let target = url.resolvingSymlinksInPath()
                        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder), isFolder.boolValue {
                            pending.append(target)
                            continue
                        }
                    }
                    add(url)
                }
            }
        }
        // Whatever else fontconfig knows of, such as folders added in its own settings.
        let listed = fontconfigFiles()
        for path in listed {
            add(URL(fileURLWithPath: path))
        }
        scanned = faces
        if debugFonts {
            FileHandle.standardError.write(Data("[fonts] \(faces.count) faces found, \(listed.count) files listed by fontconfig\n".utf8))
            if ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_FONTS_LIST"] == "1" {
                for face in faces {
                    FileHandle.standardError.write(Data("[fonts]   \(face.path) #\(face.index): \(face.family) / \(face.style) / \(face.fullName) / \(face.postScriptName)\n".utf8))
                }
            }
        }
        return faces
    }

    static let debugFonts = ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_FONTS"] == "1"

    /// The font files fontconfig lists, on systems that have it.
    private static func fontconfigFiles() -> [String] {
        #if os(Windows)
            return []
        #else
            let candidates = ["/usr/bin/fc-list", "/bin/fc-list", "/usr/local/bin/fc-list"]
            guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["--format", "%{file}\\n"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return []
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        #endif
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A name with case, spaces, hyphens and underscores dropped, so "LucidaGrande-Bold" and
    /// "Lucida Grande Bold" agree.
    private static func compact(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { !" -_".unicodeScalars.contains($0) })
    }

    private static let regularStyles: Set<String> = ["regular", "roman", "normal", "book", "plain", "standard", ""]

    private static func exact(_ name: String, in faces: [FontFace]) -> FontFace? {
        let wanted = compact(name)
        if let face = faces.first(where: { compact($0.fullName) == wanted || compact($0.postScriptName) == wanted }) {
            return face
        }
        // A bare family name means its regular style.
        func isRegular(_ style: String) -> Bool { regularStyles.contains(compact(style)) }
        if let face = faces.first(where: { compact($0.family) == wanted && isRegular($0.style) }) {
            return face
        }
        if let face = faces.first(where: { compact($0.typographicFamily) == wanted && isRegular($0.typographicStyle) }) {
            return face
        }
        // Family plus style, as in "Lucida Grande Bold" for a family that names its faces apart.
        return faces.first { face in
            [(face.family, face.style), (face.typographicFamily, face.typographicStyle)].contains { family, style in
                !family.isEmpty && compact(family + style) == wanted
            }
        }
    }

    /// Plain sans-serif faces to stand in for anything the machine doesn't have, most alike first.
    private static let lastResorts = [
        "DejaVu Sans", "Lucida Sans Unicode", "Lucida Sans", "Verdana", "Bitstream Vera Sans", "Noto Sans", "Liberation Sans",
        "Arimo", "Arial", "Helvetica", "Segoe UI", "Tahoma", "Open Sans", "Roboto", "Ubuntu", "Cantarell", "Adwaita Sans",
        "Inter", "FreeSans", "Nimbus Sans", "Nimbus Sans L",
    ]

    /// The likeliest plain upright sans-serif face when none of the known names is there.
    private static func plainFace(in faces: [FontFace]) -> FontFace? {
        for name in lastResorts {
            if let face = exact(name, in: faces) { return face }
        }
        let avoid = ["mono", "serif", "italic", "oblique", "symbol", "emoji", "math", "dingbat", "cond", "narrow"]
        let plain = faces.filter { face in
            let words = compact(face.fullName + face.family + face.style)
            return regularStyles.contains(compact(face.style)) && !avoid.contains { words.contains($0) }
        }
        return plain.min { $0.fullName < $1.fullName } ?? faces.first
    }

    /// The face for a font name, or the closest substitute, and whether bold had to be faked.
    static func face(named name: String) -> (FontFace, syntheticBold: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return resolve(normalized(name), original: name)
    }

    private static func resolve(_ key: String, original: String) -> (FontFace, syntheticBold: Bool)? {
        if let cached = facesByName[key] {
            return (cached, key.contains("bold") && !cached.isBold)
        }
        let faces = allFaces()
        var found: FontFace?
        if let face = exact(original, in: faces) ?? exact(key, in: faces) {
            found = face
        } else if key.contains("bold") {
            // Keep bold text in the same family as the regular text: its own bold if it has
            // one, otherwise the regular face thickened.
            let regularKey = key.replacingOccurrences(of: " bold", with: "")
            if let (regular, _) = resolve(regularKey, original: regularKey) {
                found = faces.first { $0.family == regular.family && $0.isBold && !$0.style.lowercased().contains("italic") } ?? regular
            }
        } else {
            for candidate in substitutes[key] ?? [] {
                if let face = exact(candidate, in: faces) {
                    found = face
                    break
                }
            }
        }
        if found == nil {
            found = plainFace(in: faces)
        }
        guard let face = found else { return nil }
        facesByName[key] = face
        if debugFonts {
            FileHandle.standardError.write(Data("[fonts] \(original) -> \(face.fullName) (\(face.path) #\(face.index))\n".utf8))
        }
        return (face, key.contains("bold") && !face.isBold)
    }

    /// Faces to try, in order, for characters the requested font lacks.
    static func fallbacks() -> [FontFace] {
        lock.lock()
        defer { lock.unlock() }
        if let fallbackChain { return fallbackChain }
        let faces = allFaces()
        var chain: [FontFace] = []
        for name in fallbackNames {
            if let face = exact(name, in: faces), !chain.contains(where: { $0 === face }) {
                chain.append(face)
            }
        }
        fallbackChain = chain
        return chain
    }

    /// The names of every face found, for diagnostics.
    public static func availableFontNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return allFaces().map(\.fullName)
    }
}

public final class CTFont: @unchecked Sendable, Hashable {
    let face: FontFace
    public let size: CGFloat
    public let name: String
    let syntheticBold: Bool

    init(face: FontFace, size: CGFloat, name: String, syntheticBold: Bool) {
        self.face = face
        self.size = size
        self.name = name
        self.syntheticBold = syntheticBold
    }

    var scale: CGFloat { size / CGFloat(max(1, face.unitsPerEm)) }

    public static func == (lhs: CTFont, rhs: CTFont) -> Bool {
        lhs.face === rhs.face && lhs.size == rhs.size && lhs.syntheticBold == rhs.syntheticBold
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(face))
        hasher.combine(size)
    }

    /// The same face at another size.
    func withFace(_ other: FontFace) -> CTFont {
        CTFont(face: other, size: size, name: name, syntheticBold: syntheticBold && !other.isBold)
    }

    func advance(_ scalar: UInt32) -> CGFloat {
        var advance: Float = 0
        plutovg_font_face_get_glyph_metrics(face.handle, Float(size), scalar, &advance, nil, nil)
        return CGFloat(advance)
    }

    func kerning(_ left: UInt32, _ right: UInt32) -> CGFloat {
        CGFloat(plutovg_font_face_kerning(face.handle, Float(size), left, right))
    }

    /// The glyph's outline in text space (y up), with its origin at `origin`.
    func glyphPath(_ scalar: UInt32, at origin: CGPoint) -> [PathElement] {
        guard let path = plutovg_path_create() else { return [] }
        defer { plutovg_path_destroy(path) }
        plutovg_font_face_get_glyph_path(face.handle, Float(size), 0, 0, scalar, path)
        var elements: [PathElement] = []
        var iterator = plutovg_path_iterator_t()
        plutovg_path_iterator_init(&iterator, path)
        var points = [plutovg_point_t](repeating: plutovg_point_t(), count: 3)
        func p(_ point: plutovg_point_t) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(point.x), y: origin.y - CGFloat(point.y))
        }
        while plutovg_path_iterator_has_next(&iterator) {
            let command = points.withUnsafeMutableBufferPointer { buffer in
                plutovg_path_iterator_next(&iterator, buffer.baseAddress)
            }
            switch command {
            case PLUTOVG_PATH_COMMAND_MOVE_TO: elements.append(.move(p(points[0])))
            case PLUTOVG_PATH_COMMAND_LINE_TO: elements.append(.line(p(points[0])))
            case PLUTOVG_PATH_COMMAND_CUBIC_TO: elements.append(.cubic(p(points[0]), p(points[1]), p(points[2])))
            case PLUTOVG_PATH_COMMAND_CLOSE: elements.append(.close)
            default: break
            }
        }
        return elements
    }
}

public typealias CTFontDescriptor = CTFont

public func CTFontCreateWithName(_ name: CFString, _ size: CGFloat, _: UnsafePointer<CGAffineTransform>?) -> CTFont {
    let pointSize = size > 0 ? size : 12
    if let (face, synthetic) = FontRegistry.face(named: name) {
        return CTFont(face: face, size: pointSize, name: name, syntheticBold: synthetic)
    }
    fatalError("No usable font was found. Install DejaVu Sans or set FIRSTROW_FONTS to a folder of TrueType fonts.")
}

public func CTFontCreateCopyWithAttributes(_ font: CTFont, _ size: CGFloat, _: UnsafePointer<CGAffineTransform>?, _: CTFontDescriptor?) -> CTFont {
    CTFont(face: font.face, size: size > 0 ? size : font.size, name: font.name, syntheticBold: font.syntheticBold)
}

public func CTFontGetSize(_ font: CTFont) -> CGFloat { font.size }
public func CTFontGetAscent(_ font: CTFont) -> CGFloat { CGFloat(font.face.ascent) * font.scale }
public func CTFontGetDescent(_ font: CTFont) -> CGFloat { CGFloat(font.face.descent) * font.scale }
public func CTFontGetLeading(_ font: CTFont) -> CGFloat { CGFloat(font.face.lineGap) * font.scale }
public func CTFontGetUnitsPerEm(_ font: CTFont) -> UInt32 { UInt32(font.face.unitsPerEm) }
public func CTFontCopyPostScriptName(_ font: CTFont) -> CFString { font.face.postScriptName }
public func CTFontCopyFamilyName(_ font: CTFont) -> CFString { font.face.family }
public func CTFontCopyFullName(_ font: CTFont) -> CFString { font.face.fullName }

// MARK: Attributed strings

public final class CFAttributedString: @unchecked Sendable {
    public let string: String
    public let attributes: CFDictionary

    init(string: String, attributes: CFDictionary) {
        self.string = string
        self.attributes = attributes
    }
}

public func CFAttributedStringCreate(_: AnyObject?, _ string: CFString, _ attributes: CFDictionary?) -> CFAttributedString {
    CFAttributedString(string: string, attributes: attributes ?? [:])
}

public func CFAttributedStringGetLength(_ string: CFAttributedString) -> CFIndex {
    string.string.utf16.count
}

public func CFAttributedStringGetString(_ string: CFAttributedString) -> CFString {
    string.string
}

// MARK: Lines

/// A laid-out glyph: one Unicode scalar drawn with one face.
struct PlacedGlyph {
    let scalar: UInt32
    let font: CTFont
    let x: CGFloat
    let advance: CGFloat
    /// Index of the scalar's first UTF-16 unit in the source string.
    let utf16Index: Int
    let utf16Length: Int
    let isWhitespace: Bool
}

public final class CTLine: @unchecked Sendable {
    let glyphs: [PlacedGlyph]
    let width: CGFloat
    let color: CGColor?
    let usesContextColor: Bool
    let range: CFRange
    let baseFont: CTFont

    init(glyphs: [PlacedGlyph], width: CGFloat, color: CGColor?, usesContextColor: Bool, range: CFRange, baseFont: CTFont) {
        self.glyphs = glyphs
        self.width = width
        self.color = color
        self.usesContextColor = usesContextColor
        self.range = range
        self.baseFont = baseFont
    }

    /// Fonts that contribute to the line's height: the base font plus any fallback faces used.
    var fonts: [CTFont] {
        var list = [baseFont]
        for glyph in glyphs where !list.contains(where: { $0.face === glyph.font.face }) {
            list.append(glyph.font)
        }
        return list
    }
}

public enum CTLineTruncationType: UInt32, Sendable {
    case start = 0
    case end = 1
    case middle = 2
}

/// Shapes `text` (a slice of the attributed string) into glyphs with kerning and font fallback.
enum Shaper {
    static func font(of attributes: CFDictionary) -> CTFont {
        if let font = attributes[kCTFontAttributeName] as? CTFont { return font }
        return CTFontCreateWithName("Lucida Grande", 12, nil)
    }

    static func shape(_ attributed: CFAttributedString, range: CFRange) -> CTLine {
        let base = font(of: attributed.attributes)
        let color = attributed.attributes[kCTForegroundColorAttributeName] as? CGColor
        let fromContext = (attributed.attributes[kCTForegroundColorFromContextAttributeName] as? Bool) ?? false
        let kern = (attributed.attributes[kCTKernAttributeName] as? NSNumber).map { CGFloat($0.doubleValue) } ?? (attributed.attributes[kCTKernAttributeName] as? CGFloat) ?? 0
        let utf16 = Array(attributed.string.utf16)
        let start = max(0, min(utf16.count, range.location))
        let end = range.length <= 0 ? utf16.count : max(start, min(utf16.count, range.location + range.length))
        var glyphs: [PlacedGlyph] = []
        var x: CGFloat = 0
        var index = start
        var previous: (UInt32, CTFont)?
        let fallbacks = FontRegistry.fallbacks()
        while index < end {
            var scalar = UInt32(utf16[index])
            var length = 1
            if (0xD800 ..< 0xDC00).contains(scalar), index + 1 < end, (0xDC00 ..< 0xE000).contains(UInt32(utf16[index + 1])) {
                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (UInt32(utf16[index + 1]) - 0xDC00)
                length = 2
            }
            let isWhitespace = scalar == 0x20 || scalar == 0x09 || scalar == 0xA0 || scalar == 0x0A || scalar == 0x0D || scalar == 0x2028
            let isControl = scalar < 0x20 || (0x200B ... 0x200F).contains(scalar) || scalar == 0xFEFF
            var font = base
            if !isControl, !base.face.hasGlyph(scalar), let fallback = fallbacks.first(where: { $0.hasGlyph(scalar) }) {
                font = base.withFace(fallback)
            }
            if let (previousScalar, previousFont) = previous, previousFont.face === font.face {
                x += font.kerning(previousScalar, scalar)
            }
            let advance = isControl ? 0 : font.advance(isWhitespace && scalar != 0x20 && scalar != 0xA0 ? 0x20 : scalar) + kern
            glyphs.append(PlacedGlyph(scalar: scalar, font: font, x: x, advance: advance, utf16Index: index, utf16Length: length, isWhitespace: isWhitespace))
            x += advance
            previous = (scalar, font)
            index += length
        }
        return CTLine(glyphs: glyphs, width: x, color: color, usesContextColor: fromContext, range: CFRange(location: start, length: end - start), baseFont: base)
    }
}

public func CTLineCreateWithAttributedString(_ string: CFAttributedString) -> CTLine {
    Shaper.shape(string, range: CFRange(location: 0, length: 0))
}

public func CTLineGetTypographicBounds(_ line: CTLine, _ ascent: UnsafeMutablePointer<CGFloat>?, _ descent: UnsafeMutablePointer<CGFloat>?, _ leading: UnsafeMutablePointer<CGFloat>?) -> Double {
    let fonts = line.fonts
    ascent?.pointee = fonts.map(CTFontGetAscent).max() ?? 0
    descent?.pointee = fonts.map(CTFontGetDescent).max() ?? 0
    leading?.pointee = fonts.map(CTFontGetLeading).max() ?? 0
    return Double(line.width)
}

public func CTLineGetTrailingWhitespaceWidth(_ line: CTLine) -> Double {
    var width: CGFloat = 0
    for glyph in line.glyphs.reversed() {
        guard glyph.isWhitespace else { break }
        width += glyph.advance
    }
    return Double(width)
}

public func CTLineGetGlyphCount(_ line: CTLine) -> CFIndex { line.glyphs.count }
public func CTLineGetStringRange(_ line: CTLine) -> CFRange { line.range }

public func CTLineGetImageBounds(_ line: CTLine, _: CGContext?) -> CGRect {
    var bounds = CGRect.null
    for glyph in line.glyphs where !glyph.isWhitespace {
        let box = CGPath(elements: glyph.font.glyphPath(glyph.scalar, at: CGPoint(x: glyph.x, y: 0))).boundingBox
        bounds = bounds.union(box)
    }
    return bounds.isNull ? .zero : bounds
}

public func CTLineGetOffsetForStringIndex(_ line: CTLine, _ index: CFIndex, _ secondary: UnsafeMutablePointer<CGFloat>?) -> CGFloat {
    let offset = line.glyphs.first(where: { $0.utf16Index >= index })?.x ?? line.width
    secondary?.pointee = offset
    return offset
}

/// Shortens a line to fit `width`, with `token` (usually an ellipsis) where text was cut.
public func CTLineCreateTruncatedLine(_ line: CTLine, _ width: Double, _ type: CTLineTruncationType, _ token: CTLine?) -> CTLine? {
    let limit = CGFloat(width)
    guard line.width > limit else { return line }
    let tokenGlyphs = token?.glyphs ?? []
    let tokenWidth = token?.width ?? 0
    guard tokenWidth <= limit else { return nil }
    var kept: [PlacedGlyph] = []
    switch type {
    case .end:
        for glyph in line.glyphs where glyph.x + glyph.advance + tokenWidth <= limit + 0.001 {
            kept.append(glyph)
        }
        while let last = kept.last, last.isWhitespace { kept.removeLast() }
        let start = kept.last.map { $0.x + $0.advance } ?? 0
        let tail = tokenGlyphs.map { PlacedGlyph(scalar: $0.scalar, font: $0.font, x: start + $0.x, advance: $0.advance, utf16Index: $0.utf16Index, utf16Length: 0, isWhitespace: $0.isWhitespace) }
        return CTLine(glyphs: kept + tail, width: start + tokenWidth, color: line.color, usesContextColor: line.usesContextColor, range: line.range, baseFont: line.baseFont)
    case .start:
        var tail: [PlacedGlyph] = []
        for glyph in line.glyphs.reversed() {
            if line.width - glyph.x + tokenWidth > limit + 0.001 { break }
            tail.insert(glyph, at: 0)
        }
        let shift = tail.first.map { $0.x } ?? line.width
        let head = tokenGlyphs.map { PlacedGlyph(scalar: $0.scalar, font: $0.font, x: $0.x, advance: $0.advance, utf16Index: 0, utf16Length: 0, isWhitespace: $0.isWhitespace) }
        let moved = tail.map { PlacedGlyph(scalar: $0.scalar, font: $0.font, x: $0.x - shift + tokenWidth, advance: $0.advance, utf16Index: $0.utf16Index, utf16Length: $0.utf16Length, isWhitespace: $0.isWhitespace) }
        return CTLine(glyphs: head + moved, width: tokenWidth + line.width - shift, color: line.color, usesContextColor: line.usesContextColor, range: line.range, baseFont: line.baseFont)
    case .middle:
        let half = (limit - tokenWidth) / 2
        let head = line.glyphs.filter { $0.x + $0.advance <= half }
        let headWidth = head.last.map { $0.x + $0.advance } ?? 0
        let tailStart = line.width - (limit - tokenWidth - headWidth)
        let tail = line.glyphs.filter { $0.x >= tailStart - 0.001 }
        let shift = (tail.first?.x ?? line.width) - headWidth - tokenWidth
        let middle = tokenGlyphs.map { PlacedGlyph(scalar: $0.scalar, font: $0.font, x: headWidth + $0.x, advance: $0.advance, utf16Index: 0, utf16Length: 0, isWhitespace: false) }
        let moved = tail.map { PlacedGlyph(scalar: $0.scalar, font: $0.font, x: $0.x - shift, advance: $0.advance, utf16Index: $0.utf16Index, utf16Length: $0.utf16Length, isWhitespace: $0.isWhitespace) }
        let total = (moved.last.map { $0.x + $0.advance }) ?? (headWidth + tokenWidth)
        return CTLine(glyphs: head + middle + moved, width: total, color: line.color, usesContextColor: line.usesContextColor, range: line.range, baseFont: line.baseFont)
    }
}

/// Draws the line with its origin at the context's text position.
public func CTLineDraw(_ line: CTLine, _ context: CGContext) {
    let color = line.usesContextColor ? context.fillColor : (line.color ?? CGColor(gray: 0, alpha: 1))
    let origin = context.textPosition
    let matrix = context.textMatrix
    var elements: [PathElement] = []
    var boldStrokes: [(CTFont, [PathElement])] = []
    for glyph in line.glyphs where !glyph.isWhitespace {
        let local = glyph.font.glyphPath(glyph.scalar, at: CGPoint(x: glyph.x, y: 0))
        let placed = local.map { $0.applying(matrix.concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))) }
        elements.append(contentsOf: placed)
        if glyph.font.syntheticBold {
            boldStrokes.append((glyph.font, placed))
        }
    }
    context.fillUserPath(elements, color: color)
    // Fake bold: thicken the outlines the way a font's bold would.
    for (font, path) in boldStrokes {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(font.size * 0.045)
        context.setLineJoin(.round)
        context.beginPath()
        context.addPath(CGPath(elements: path))
        context.strokePath()
        context.restoreGState()
    }
    context.textPosition = CGPoint(x: origin.x + line.width, y: origin.y)
}

// MARK: Typesetting

public final class CTTypesetter: @unchecked Sendable {
    let attributed: CFAttributedString
    let fullLine: CTLine
    let utf16: [UInt16]

    init(_ attributed: CFAttributedString) {
        self.attributed = attributed
        fullLine = Shaper.shape(attributed, range: CFRange(location: 0, length: 0))
        utf16 = Array(attributed.string.utf16)
    }
}

public func CTTypesetterCreateWithAttributedString(_ string: CFAttributedString) -> CTTypesetter {
    CTTypesetter(string)
}

/// How many UTF-16 units from `start` fit in `width`, breaking after spaces or hyphens where
/// possible. Trailing spaces stay on the line, as Core Text keeps them.
public func CTTypesetterSuggestLineBreak(_ typesetter: CTTypesetter, _ start: CFIndex, _ width: Double) -> CFIndex {
    let glyphs = typesetter.fullLine.glyphs.filter { $0.utf16Index >= start }
    guard let first = glyphs.first else { return 0 }
    let origin = first.x
    let limit = CGFloat(width)
    var lastBreak: Int?
    var fitted = 0
    for (index, glyph) in glyphs.enumerated() {
        if glyph.scalar == 0x0A || glyph.scalar == 0x2028 {
            return glyph.utf16Index + glyph.utf16Length - start
        }
        let right = glyph.x + glyph.advance - origin
        if right > limit + 0.001, !glyph.isWhitespace {
            if let lastBreak { return lastBreak - start }
            // One word wider than the line: break inside it.
            return max(fitted, index > 0 ? glyphs[index].utf16Index - start : glyph.utf16Length)
        }
        fitted = glyph.utf16Index + glyph.utf16Length - start
        if glyph.isWhitespace || glyph.scalar == 0x2D || glyph.scalar == 0x2010 || glyph.scalar == 0x2013 || glyph.scalar == 0x2014 || glyph.scalar == 0x2F {
            lastBreak = glyph.utf16Index + glyph.utf16Length
        } else if glyph.scalar >= 0x2E80 {
            // Ideographs break anywhere.
            lastBreak = glyph.utf16Index + glyph.utf16Length
        }
    }
    return typesetter.utf16.count - start
}

public func CTTypesetterCreateLine(_ typesetter: CTTypesetter, _ range: CFRange) -> CTLine {
    Shaper.shape(typesetter.attributed, range: range)
}

/// Reads the TrueType fonts out of a Mac resource fork kept as a file, as in a .dfont.
enum MacResourceFork {
    static func sfntResources(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= bytes.count else { return nil }
            return Int(bytes[at]) << 8 | Int(bytes[at + 1])
        }
        guard let dataOffset = u32(0), let mapOffset = u32(4), let typeListOffset = u16(mapOffset + 24),
              let typeCountMinusOne = u16(mapOffset + typeListOffset) else { return [] }
        let typeList = mapOffset + typeListOffset
        var fonts: [Data] = []
        for type in 0 ... min(typeCountMinusOne, 255) {
            let entry = typeList + 2 + type * 8
            guard entry + 8 <= bytes.count, String(decoding: bytes[entry ..< entry + 4], as: UTF8.self) == "sfnt",
                  let countMinusOne = u16(entry + 4), let referencesOffset = u16(entry + 6) else { continue }
            for index in 0 ... min(countMinusOne, 255) {
                let reference = typeList + referencesOffset + index * 12
                guard let attributes = u32(reference + 4) else { continue }
                let start = dataOffset + (attributes & 0xFFFFFF)
                guard let length = u32(start), start + 4 + length <= bytes.count else { continue }
                fonts.append(Data(bytes[start + 4 ..< start + 4 + length]))
            }
        }
        return fonts
    }
}
