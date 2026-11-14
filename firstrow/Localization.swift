import Foundation

/// The languages First Row's own words come in. English is what the code is written in; the
/// others are tables from the English words to theirs (see `German`).
enum AppLanguage: String {
    case english = "en"
    case german = "de"

    /// The language in use, settled once as First Row starts: the first of the languages
    /// the system prefers that First Row has, or English.
    static let current: AppLanguage = {
        for tag in preferredLanguageTags() {
            let code = tag.lowercased().split(whereSeparator: { "-_.@".contains($0) }).first.map(String.init) ?? ""
            if let language = AppLanguage(rawValue: code) { return language }
        }
        return .english
    }()

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
        #elseif FIRSTROW_PORTABLE
            return Locale.preferredLanguages
        #else
            // (The system chooses among the languages the app says it has, and a language
            // chosen for First Row alone in the system's settings counts.)
            return Bundle.main.preferredLocalizations
        #endif
    }

    /// For dates written out in words.
    var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en_US_POSIX")
        case .german: Locale(identifier: "de_DE")
        }
    }
}

/// First Row's own words in the language in use. `english` is the words as the code has
/// them, which is also what they are found by in another language's table: words missing
/// from a table stay English.
func L(_ english: String) -> String {
    switch AppLanguage.current {
    case .english: english
    case .german: German.words[english] ?? english
    }
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
