import Foundation
#if os(Windows)
    import WinSDK
#endif

/// The languages First Row's own words come in. English is what the code is written in; the
/// others are tables from the English words to theirs (see `German`).
enum AppLanguage: String {
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case japanese = "ja"
    case korean = "ko"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    /// The language in use, settled once as First Row starts: the first of the languages
    /// the system prefers that First Row has, or English.
    static let current: AppLanguage = {
        for tag in preferredLanguageTags() {
            if let language = AppLanguage(tag: tag) { return language }
        }
        return .english
    }()

    /// The language a system's tag names, if First Row has it: "de-AT", "fr_CA.UTF-8",
    /// "zh-Hant-TW", "zh_CN" and the like.
    init?(tag: String) {
        let parts = tag.lowercased().split(whereSeparator: { "-_.@".contains($0) }).map(String.init)
        guard let code = parts.first else { return nil }
        guard code == "zh" else {
            self.init(rawValue: code)
            return
        }
        // Chinese is written two ways: as the tag says, or failing that as the place it
        // names writes it (traditional characters in Taiwan, Hong Kong and Macao).
        let rest = parts.dropFirst()
        if rest.contains("hant") {
            self = .chineseTraditional
        } else if rest.contains("hans") {
            self = .chineseSimplified
        } else {
            self = rest.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .chineseTraditional : .chineseSimplified
        }
    }

    /// First Row's words in this language, by the English ones (nil for English itself).
    var words: [String: String]? {
        switch self {
        case .english: nil
        case .german: German.words
        case .french: French.words
        case .spanish: Spanish.words
        case .japanese: Japanese.words
        case .korean: Korean.words
        case .chineseSimplified: ChineseSimplified.words
        case .chineseTraditional: ChineseTraditional.words
        }
    }

    /// The table in use, looked up once.
    fileprivate static let currentWords = current.words

    /// The language as services on the internet are told it ("zh-TW" for traditional Chinese).
    var serviceTag: String {
        switch self {
        case .chineseSimplified: "zh-CN"
        case .chineseTraditional: "zh-TW"
        default: rawValue
        }
    }

    private static func preferredLanguageTags() -> [String] {
        #if os(Linux)
            // As other programs there read them: LANGUAGE (a list), then the first that is
            // set of LC_ALL, LC_MESSAGES and LANG.
            let environment = ProcessInfo.processInfo.environment
            var tags: [String] = []
            if let list = environment["LANGUAGE"], !list.isEmpty {
                tags += list.split(separator: ":").map(String.init)
            }
            for name in ["LC_ALL", "LC_MESSAGES", "LANG"] {
                if let value = environment[name], !value.isEmpty {
                    tags.append(value)
                    break
                }
            }
            return tags
        #elseif os(Windows)
            // The languages preferred in Windows' settings, in the user's order (what Windows
            // says apps appear in), and after them the one Windows itself is shown in.
            var tags: [String] = []
            let key = Array("Control Panel\\International\\User Profile".utf16) + [0]
            let name = Array("Languages".utf16) + [0]
            let kind = DWORD(RRF_RT_REG_MULTI_SZ)
            var size: DWORD = 0
            if RegGetValueW(HKEY_CURRENT_USER, key, name, kind, nil, nil, &size) == ERROR_SUCCESS, size > 0 {
                var list = [WCHAR](repeating: 0, count: Int(size) / MemoryLayout<WCHAR>.size + 1)
                if RegGetValueW(HKEY_CURRENT_USER, key, name, kind, nil, &list, &size) == ERROR_SUCCESS {
                    tags += strings(inList: list)
                }
            }
            var count: ULONG = 0
            var length: ULONG = 0
            if GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, nil, &length), length > 0 {
                var list = [WCHAR](repeating: 0, count: Int(length))
                if GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, &list, &length) {
                    tags += strings(inList: list)
                }
            }
            return tags
        #else
            // (The system chooses among the languages the app says it has, and a language
            // chosen for First Row alone in the system's settings counts.)
            return Bundle.main.preferredLocalizations
        #endif
    }

    #if os(Windows)
        /// The strings of one of Windows' lists, each of which ends with a zero.
        private static func strings(inList list: [WCHAR]) -> [String] {
            list.split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
        }
    #endif

    /// For dates written out in words.
    var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en_US_POSIX")
        case .german: Locale(identifier: "de_DE")
        case .french: Locale(identifier: "fr_FR")
        case .spanish: Locale(identifier: "es")
        case .japanese: Locale(identifier: "ja_JP")
        case .korean: Locale(identifier: "ko_KR")
        case .chineseSimplified: Locale(identifier: "zh_Hans_CN")
        case .chineseTraditional: Locale(identifier: "zh_Hant_TW")
        }
    }

    /// A day as a list of photographs is named by it: "Nov 14th, 2026" in English.
    func dayTitle(day: Int, month: String, year: Int, englishOrdinal: String) -> String {
        switch self {
        case .english: "\(month) \(day)\(englishOrdinal), \(year)"
        case .german: "\(day). \(month) \(year)"
        case .french: "\(day) \(month) \(year)"
        case .spanish: "\(day) \(month) \(year)"
        case .japanese, .chineseSimplified, .chineseTraditional: "\(year)年\(month)\(day)日"
        case .korean: "\(year)년 \(month) \(day)일"
        }
    }

    #if FIRSTROW_PORTABLE
        /// The fonts on Linux and Windows that write this language's own forms of the characters
        /// Chinese, Japanese and Korean share, to be tried before the others that have them.
        var fallbackFontNames: [String] {
            switch self {
            case .japanese: ["Noto Sans CJK JP", "Yu Gothic UI", "Yu Gothic", "Meiryo", "IPAexGothic", "IPAGothic", "VL Gothic", "MS Gothic"]
            case .korean: ["Noto Sans CJK KR", "Malgun Gothic", "NanumGothic"]
            case .chineseSimplified: ["Noto Sans CJK SC", "Microsoft YaHei", "WenQuanYi Micro Hei", "WenQuanYi Zen Hei", "SimSun"]
            case .chineseTraditional: ["Noto Sans CJK TC", "Microsoft JhengHei", "Noto Sans CJK HK"]
            default: []
            }
        }
    #endif

    /// A day and month in figures, as a list of episodes shows when each came out: "11/14".
    var dayAndMonthFormat: String {
        switch self {
        case .english, .japanese, .chineseSimplified, .chineseTraditional: "M/d"
        case .german: "d.M."
        case .french, .spanish: "d/M"
        case .korean: "M. d."
        }
    }
}

/// First Row's own words in the language in use. `english` is the words as the code has
/// them, which is also what they are found by in another language's table: words missing
/// from a table stay English.
func L(_ english: String) -> String {
    AppLanguage.currentWords?[english] ?? english
}

/// The same for words with something to fill in. Each "%@" takes the next of `parts`; a
/// language that says them in another order writes "%1$@", "%2$@" for the first, the second.
func L(_ english: String, _ parts: Any...) -> String {
    let template = Array(L(english))
    var result = ""
    var next = 0
    var index = 0
    while index < template.count {
        let character = template[index]
        guard character == "%", index + 1 < template.count else {
            result.append(character)
            index += 1
            continue
        }
        if template[index + 1] == "@" {
            if next < parts.count { result += "\(parts[next])" }
            next += 1
            index += 2
        } else if index + 3 < template.count, let number = template[index + 1].wholeNumberValue,
                  template[index + 2] == "$", template[index + 3] == "@"
        {
            if number >= 1, number <= parts.count { result += "\(parts[number - 1])" }
            index += 4
        } else {
            result.append(character)
            index += 1
        }
    }
    return result
}
