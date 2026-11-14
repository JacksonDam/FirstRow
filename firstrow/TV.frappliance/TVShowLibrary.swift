import Foundation
#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

// Which of the movie files are episodes of TV shows, and of which shows.
//
// An episode is told by its name, as such files are named everywhere: "Show Name S01E02",
// "Show.Name.1x02.Its.Title", "Show Name - Season 1 Episode 2". Or by where it is: a file
// that begins with its number ("02 Its Title", "Episode 2") in a folder called "Season 1",
// which is in the show's folder (how the TV app keeps its own, too).
//
// Episodes are listed under TV Shows, by show or by date, and are left out of Movies Folder.

/// One episode: a movie file, and what is known of it.
struct TVEpisode: Equatable, Sendable {
    let url: URL
    /// The show's name as it is shown, and as shows are told apart (letters and digits only).
    let show: String
    let showKey: String
    let season: Int
    let episode: Int
    /// The episode's own name, where the file has one.
    let title: String?
    /// When the file was added (or made, or last changed, whichever is known).
    var date = Date.distantPast

    /// What the episode is called in its show's list: "2. Its Title", or "Episode 2".
    var numberedTitle: String {
        title.map { "\(episode). \($0)" } ?? L("Episode %@", episode)
    }

    /// What it is called in a list of episodes of every show.
    var titleWithShow: String {
        "\(show): \(title ?? "\(TVShow.name(ofSeason: season)), \(L("Episode %@", episode))")"
    }
}

/// A show: its episodes in their order.
struct TVShow: Equatable, Sendable {
    let key: String
    let name: String
    let episodes: [TVEpisode]

    var seasons: [Int] {
        Array(Set(episodes.map(\.season))).sorted()
    }

    func episodes(inSeason season: Int) -> [TVEpisode] {
        episodes.filter { $0.season == season }
    }

    static func name(ofSeason season: Int) -> String {
        season == 0 ? L("Specials") : L("Season %@", season)
    }
}

/// Every show there is, and every episode with the newest first.
struct TVShowLibrary: Equatable, Sendable {
    var shows: [TVShow] = []
    var newestFirst: [TVEpisode] = []

    var isEmpty: Bool {
        shows.isEmpty
    }

    func show(withKey key: String) -> TVShow? {
        shows.first { $0.key == key }
    }

    func episode(at url: URL) -> TVEpisode? {
        let path = url.standardizedFileURL.path
        return newestFirst.first { $0.url.path == path }
    }

    init() {}

    init(episodes: [TVEpisode]) {
        var byShow: [String: [TVEpisode]] = [:]
        for episode in episodes {
            byShow[episode.showKey, default: []].append(episode)
        }
        shows = byShow.map { key, episodes in
            // (The name most of its files give it.)
            var counts: [String: Int] = [:]
            for episode in episodes {
                counts[episode.show, default: 0] += 1
            }
            let name = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? key
            let ordered = episodes.sorted { ($0.season, $0.episode, $0.url.path) < ($1.season, $1.episode, $1.url.path) }
            return TVShow(key: key, name: name, episodes: ordered.map {
                TVEpisode(url: $0.url, show: name, showKey: key, season: $0.season, episode: $0.episode, title: $0.title, date: $0.date)
            })
        }
        .sorted { Self.sortName($0.name).localizedCaseInsensitiveCompare(Self.sortName($1.name)) == .orderedAscending }
        newestFirst = shows.flatMap(\.episodes).sorted {
            $0.date != $1.date ? $0.date > $1.date : ($0.show, $0.season, $0.episode, $0.url.path) < ($1.show, $1.season, $1.episode, $1.url.path)
        }
    }

    /// (A show is filed under its name without "The".)
    private static func sortName(_ name: String) -> String {
        name.lowercased().hasPrefix("the ") ? String(name.dropFirst(4)) : name
    }
}

/// Reads an episode out of a file's name and place.
enum TVShowNames {
    static func episode(at url: URL) -> TVEpisode? {
        // (The Tiger look has no TV Shows to list one under: it stays a movie among the movies.)
        if TigerTheme.isActive { return nil }
        let name = Array(url.deletingPathExtension().lastPathComponent)
        let folder = url.deletingLastPathComponent()
        let parent = folder.lastPathComponent
        let grandparent = folder.deletingLastPathComponent().lastPathComponent
        let seasonOfFolder = season(ofFolderNamed: parent)
        if let found = numbers(in: name) {
            var show = cleaned(String(name[..<found.start]))
            if show.isEmpty { show = cleaned(seasonOfFolder == nil ? parent : grandparent) }
            return make(url, show: show, season: found.season, episode: found.episode, rest: String(name[found.end...]))
        }
        // By its place: "02 Its Title" in "Season 1", in the show's folder.
        if let seasonOfFolder, let found = leadingNumber(in: name) {
            return make(url, show: cleaned(grandparent), season: seasonOfFolder, episode: found.episode, rest: String(name[found.end...]))
        }
        return nil
    }

    private static func make(_ url: URL, show: String, season: Int, episode: Int, rest: String) -> TVEpisode? {
        let key = key(for: show)
        guard !key.isEmpty else { return nil }
        // (Written all in small letters, as names with dots for spaces often are, it gets capitals.)
        let name = show == show.lowercased() ? show.capitalized : show
        return TVEpisode(url: url.standardizedFileURL, show: name, showKey: key, season: season, episode: episode, title: title(from: rest))
    }

    /// What shows are told apart by: the name's letters and digits, in small letters.
    static func key(for show: String) -> String {
        String(show.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: Numbers in a name

    private static let separators: Set<Character> = [" ", ".", "_", "-"]

    private static func digit(_ character: Character) -> Int? {
        character.isASCII ? character.wholeNumberValue : nil
    }

    /// A number of up to `most` digits at `index`: its value and where it ends. Nil if there
    /// is none there, or if more digits follow than that.
    private static func number(in name: [Character], at index: Int, most: Int) -> (value: Int, end: Int)? {
        var value = 0
        var end = index
        while end < name.count, let digit = digit(name[end]) {
            value = value * 10 + digit
            end += 1
            if end - index > most { return nil }
        }
        return end > index ? (value, end) : nil
    }

    private static func skipSeparators(in name: [Character], from index: Int, also more: Set<Character> = []) -> Int {
        var index = index
        while index < name.count, separators.contains(name[index]) || more.contains(name[index]) {
            index += 1
        }
        return index
    }

    private static func has(_ word: String, in name: [Character], at index: Int) -> Bool {
        let word = Array(word)
        guard index + word.count <= name.count else { return false }
        return !word.indices.contains { String(name[index + $0]).lowercased() != String(word[$0]) }
    }

    /// The first "S01E02", "Season 1 Episode 2" or "1x02" in a name: where it starts and
    /// ends, and its two numbers.
    private static func numbers(in name: [Character]) -> (start: Int, end: Int, season: Int, episode: Int)? {
        for start in name.indices {
            // (It begins a word: "Paris02x03" and "words1x02" aren't taken for one.)
            if start > 0, name[start - 1].isLetter || name[start - 1].isNumber { continue }
            if has("s", in: name, at: start), let season = number(in: name, at: start + 1, most: 2) {
                var index = season.end
                if index < name.count, separators.contains(name[index]) { index += 1 }
                if has("e", in: name, at: index), let episode = number(in: name, at: index + 1, most: 3) {
                    // (Two episodes in one file, "S01E01E02" or "S01E01-E02": it is the first.)
                    var end = episode.end
                    while end < name.count {
                        var next = end
                        if name[next] == "-" { next += 1 }
                        if has("e", in: name, at: next) { next += 1 } else if next == end { break }
                        guard let more = number(in: name, at: next, most: 3) else { break }
                        end = more.end
                    }
                    return (start, end, season.value, episode.value)
                }
            }
            if has("season", in: name, at: start) {
                let index = skipSeparators(in: name, from: start + 6)
                if let season = number(in: name, at: index, most: 2) {
                    let word = skipSeparators(in: name, from: season.end, also: [","])
                    if has("episode", in: name, at: word),
                       let episode = number(in: name, at: skipSeparators(in: name, from: word + 7), most: 3)
                    {
                        return (start, episode.end, season.value, episode.value)
                    }
                }
            }
            if let season = number(in: name, at: start, most: 2), has("x", in: name, at: season.end),
               let episode = number(in: name, at: season.end + 1, most: 3), episode.end - season.end - 1 >= 2,
               episode.end == name.count || !(name[episode.end].isLetter || name[episode.end].isNumber)
            {
                return (start, episode.end, season.value, episode.value)
            }
        }
        return nil
    }

    /// The number a name begins with, for a file in a season's folder: "02 Its Title",
    /// "2 - Its Title", "Episode 2", "E02".
    private static func leadingNumber(in name: [Character]) -> (end: Int, episode: Int)? {
        var index = 0
        for word in ["episode", "ep", "e"] where has(word, in: name, at: 0) {
            index = skipSeparators(in: name, from: word.count)
            break
        }
        guard let episode = number(in: name, at: index, most: 3) else { return nil }
        if episode.end < name.count, name[episode.end].isLetter || name[episode.end].isNumber { return nil }
        return (episode.end, episode.value)
    }

    /// The season a folder's name says it holds: "Season 1", "Series 2", "S03", "Specials".
    static func season(ofFolderNamed folder: String) -> Int? {
        let name = Array(folder.lowercased().trimmingCharacters(in: .whitespaces))
        if String(name) == "specials" { return 0 }
        for word in ["season", "series", "staffel", "saison", "temporada", "stagione"] where has(word, in: name, at: 0) {
            return number(in: name, at: skipSeparators(in: name, from: word.count), most: 2)?.value
        }
        if has("s", in: name, at: 0), let season = number(in: name, at: 1, most: 2), season.end == name.count {
            return season.value
        }
        return nil
    }

    // MARK: Names

    /// A piece of a file's name as words: dots or underscores that stand for spaces are
    /// spaces, and what joined it to the rest of the name is gone.
    private static func cleaned(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "_", with: " ")
        // ("[Whoever made the file] Show Name")
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") { text = String(text[text.index(after: close)...]) }
        if !text.contains(" ") { text = text.replacingOccurrences(of: ".", with: " ") }
        let joins = CharacterSet(charactersIn: " -.,:;")
        text = text.trimmingCharacters(in: joins)
        while let last = text.last, "([".contains(last) {
            text = String(text.dropLast()).trimmingCharacters(in: joins)
        }
        while let first = text.first, ")]".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: joins)
        }
        return text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Words that begin the part of a name that says how the file was made, not what it is.
    private static let makingWords: Set<String> = [
        "2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd", "hdr", "hdr10", "sdr", "web", "webrip", "web-dl", "webdl",
        "hdtv", "pdtv", "dsr", "bluray", "blu-ray", "bdrip", "brrip", "dvdrip", "dvd", "remux", "x264", "x265", "h264", "h265",
        "hevc", "avc", "xvid", "divx", "aac", "ac3", "eac3", "dts", "10bit", "8bit", "proper", "repack", "internal", "amzn",
    ]

    /// The episode's own name from what follows its numbers, or nil if nothing does.
    private static func title(from rest: String) -> String? {
        var words: [Substring] = []
        for word in cleaned(rest).split(separator: " ") {
            if makingWords.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))) { break }
            words.append(word)
        }
        let title = cleaned(words.joined(separator: " "))
        if title.isEmpty { return nil }
        return title == title.lowercased() ? title.capitalized : title
    }
}

/// What a folder holds, read in one go: the name of each thing in it and whether it is a
/// folder, with nothing more asked of the disk for each (a folder brought in whole can hold
/// thousands of files, and may be on a drive or with a service that answers slowly).
enum FolderReader {
    typealias Child = (url: URL, isFolder: Bool)

    static func children(of folder: URL) -> [Child]? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        ) else { return nil }
        return contents.map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) }
    }

    /// Whether a folder is a disc kept as its files (see `MenuView.isDiscFolder`), told from
    /// what has already been read of it.
    static func isDisc(_ folder: URL, children: [Child]) -> Bool {
        if folder.pathExtension.lowercased() == "dvdmedia" { return true }
        return children.contains { child in
            guard child.isFolder else { return false }
            let name = child.url.lastPathComponent.uppercased()
            return name == "VIDEO_TS" || name == "BDMV"
        }
    }

    /// Whether a file is a movie, by the ending of its name. On iPhone and iPad the system
    /// is asked about an ending First Row doesn't list, once for each ending.
    static func isMovie(_ url: URL, _ movieExtensions: Set<String>) -> Bool {
        let ending = url.pathExtension.lowercased()
        if movieExtensions.contains(ending) { return true }
        #if os(iOS)
            guard !ending.isEmpty else { return false }
            endingsLock.lock()
            defer { endingsLock.unlock() }
            if let known = endingsTheSystemKnows[ending] { return known }
            let isMovie = UTType(filenameExtension: ending)?.conforms(to: .movie) ?? false
            endingsTheSystemKnows[ending] = isMovie
            return isMovie
        #else
            return false
        #endif
    }

    #if os(iOS)
        private static let endingsLock = NSLock()
        nonisolated(unsafe) private static var endingsTheSystemKnows: [String: Bool] = [:]
    #endif

    /// Does a piece of work for each of `items`, several at a time when there are enough of
    /// them to be worth it, and gives the answers back in the items' order.
    static func each<Item, Answer>(of items: [Item], _ work: (Item) -> Answer) -> [Answer] {
        guard items.count > 3 else { return items.map(work) }
        var answers = [Answer?](repeating: nil, count: items.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            let answer = work(items[index])
            lock.lock()
            answers[index] = answer
            lock.unlock()
        }
        return answers.map { $0! }
    }
}

/// Looks through folders for episodes.
enum TVShowScanner {
    /// How deep under a folder it looks, and how many files and folders it reads in all
    /// before it stops (a whole drive brought in as one folder isn't read to its end). Reading
    /// asks the disk only for names, so the count can be a large one: a folder with tens of
    /// thousands of other files in it still has all its shows found.
    private static let depth = 6
    private static let most = 200_000

    /// Every episode among the movie files in `folders` and the folders inside them, and
    /// among `files`.
    static func library(folders: [URL], files: [URL], movieExtensions: Set<String>) -> TVShowLibrary {
        var episodes: [TVEpisode] = []
        var seen = Set<String>()
        var left = most
        func take(_ url: URL) {
            guard var episode = TVShowNames.episode(at: url), seen.insert(episode.url.path).inserted else { return }
            // (Only an episode's dates are read: most files in a folder are no episode.)
            episode.date = date(from: try? url.resourceValues(forKeys: dateKeys))
            episodes.append(episode)
        }
        func look(in folder: URL, level: Int) {
            guard left > 0, let children = FolderReader.children(of: folder) else { return }
            // (A disc kept as a folder is a movie, not a folder of episodes.)
            if level > 0, FolderReader.isDisc(folder, children: children) { return }
            for child in children {
                left -= 1
                guard left > 0 else { return }
                if child.isFolder {
                    if level < depth { look(in: child.url, level: level + 1) }
                } else if FolderReader.isMovie(child.url, movieExtensions) {
                    take(child.url)
                }
            }
        }
        for file in files where FolderReader.isMovie(file, movieExtensions) {
            take(file)
        }
        for folder in folders {
            look(in: folder, level: 0)
        }
        return TVShowLibrary(episodes: episodes)
    }

    /// Whether the movies in a folder, and in the folders inside it, are all episodes (and
    /// there is one at least): such a folder has nothing to show in Movies Folder. `children`
    /// is what the folder holds, where that has been read already.
    static func holdsOnlyEpisodes(_ folder: URL, children known: [FolderReader.Child]? = nil, movieExtensions: Set<String>) -> Bool {
        var left = 1500
        var episodes = 0
        func look(in folder: URL, _ known: [FolderReader.Child]?, level: Int) -> Bool {
            guard let children = known ?? FolderReader.children(of: folder) else { return false }
            left -= children.count
            // (Too much to read through: it is shown as the folder it is.)
            guard left > 0 else { return false }
            if FolderReader.isDisc(folder, children: children) { return false }
            // Its own files first: one movie that is no episode settles it, without the
            // folders inside it being read at all.
            for child in children where !child.isFolder && FolderReader.isMovie(child.url, movieExtensions) {
                guard TVShowNames.episode(at: child.url) != nil else { return false }
                episodes += 1
            }
            for child in children where child.isFolder {
                guard level < 4, look(in: child.url, nil, level: level + 1) else { return false }
            }
            return true
        }
        return look(in: folder, known, level: 0) && episodes > 0
    }

    private static var dateKeys: Set<URLResourceKey> {
        #if canImport(Darwin)
            [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        #else
            [.contentModificationDateKey]
        #endif
    }

    private static func date(from values: URLResourceValues?) -> Date {
        #if canImport(Darwin)
            values?.addedToDirectoryDate ?? values?.creationDate ?? values?.contentModificationDate ?? .distantPast
        #else
            values?.contentModificationDate ?? .distantPast
        #endif
    }
}
