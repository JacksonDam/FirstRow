import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Lyrics for a song that brings none of its own (no .lrc file beside it, none in its tags, none
// from its library or server) are looked up at LRCLIB (lrclib.net), a free and open lyrics
// database, while the song plays in Now Playing. What is sent is what the song is known by:
// its title, artist, album and length. What comes back is kept on this device, so a song is
// asked about once.
//
// The song is asked for by all four first, which finds it when LRCLIB knows it by the same
// names; then by its title and artist, and last by its title alone, with what those bring
// back gone through for the same song: the same title once asides such as "(Remastered)" are
// left out, the same artist, and the same length to within three seconds. A wrong song's
// lyrics are worse than none, so anything less than that is left.

/// What a song is looked up by.
struct LyricsLookupQuery: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    /// In seconds; 0 when it isn't known.
    var duration: Double
}

/// One of LRCLIB's records, as far as First Row reads it.
struct LyricsLookupRecord: Codable, Equatable, Sendable {
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var duration: Double?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
}

/// Telling whether a record is the song that was asked for, and choosing between several.
enum LyricsMatching {
    /// Words that mark an aside in a title: which issue or recording it is, or who else is on it.
    private static let asideWords: Set<String> = ["remaster", "remastered", "live", "version", "edit", "mono", "stereo", "deluxe", "bonus"]
    private static let guestWords: Set<String> = ["feat", "ft", "featuring"]

    /// A title without its asides: "Song (feat. Someone) [2011 Remaster]" and
    /// "Song - Remastered 2011" are both "Song".
    static func cleanedTitle(_ title: String) -> String {
        var result = ""
        var index = title.startIndex
        let closers: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        while index < title.endIndex {
            let character = title[index]
            if let closer = closers[character], let close = title[index...].firstIndex(of: closer) {
                let inside = String(title[title.index(after: index) ..< close])
                if isAside(inside) {
                    index = title.index(after: close)
                    continue
                }
            }
            result.append(character)
            index = title.index(after: index)
        }
        // "Song - Remastered 2011", "Song - Live at ...": the part after the dash, when it is an aside.
        if let dash = result.range(of: " - ", options: .backwards), isAside(String(result[dash.upperBound...])) {
            result = String(result[..<dash.lowerBound])
        }
        // "Song feat. Someone", outside any brackets.
        let words = result.split(separator: " ", omittingEmptySubsequences: true)
        if let guest = words.firstIndex(where: { guestWords.contains(folded(String($0))) }), guest > words.startIndex {
            result = words[..<guest].joined(separator: " ")
        } else {
            result = words.joined(separator: " ")
        }
        let cleaned = result.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title.trimmingCharacters(in: .whitespaces) : cleaned
    }

    private static func isAside(_ text: String) -> Bool {
        let words = folded(text).split(separator: " ").map(String.init)
        guard let first = words.first else { return false }
        if guestWords.contains(first) { return true }
        return words.contains { asideWords.contains($0) }
    }

    /// Lower case, without accents or punctuation, "&" read as "and", single spaces.
    static func folded(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        var result = ""
        var lastWasSpace = true
        for scalar in plain.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace, scalar != "'", scalar != "’" {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// The ways an artist may be written, each with its words in order of the alphabet: the
    /// whole of it, and the first of several named together ("A feat. B", "A, B", "A & B").
    static func artistForms(_ artist: String) -> Set<String> {
        func form(_ text: String) -> String {
            folded(text).split(separator: " ").sorted().joined(separator: " ")
        }
        var forms: Set<String> = []
        let whole = form(artist)
        if !whole.isEmpty { forms.insert(whole) }
        var first = artist
        for separator in [";", ",", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " & ", " and ", " with ", " x ", " vs. ", " vs ", " + "] {
            if let range = first.range(of: separator, options: .caseInsensitive) {
                first = String(first[..<range.lowerBound])
            }
        }
        let lead = form(first)
        if !lead.isEmpty { forms.insert(lead) }
        return forms
    }

    /// The record is the song asked for: its title, its artist and its length all agree.
    static func isSameSong(_ record: LyricsLookupRecord, as query: LyricsLookupQuery) -> Bool {
        guard let title = record.trackName, let artist = record.artistName, let duration = record.duration, query.duration > 0 else { return false }
        guard abs(duration - query.duration) <= 3 else { return false }
        guard folded(cleanedTitle(title)) == folded(cleanedTitle(query.title)) else { return false }
        return !artistForms(artist).isDisjoint(with: artistForms(query.artist))
    }

    /// The record's lyrics, timed when it has them timed. Nil for an instrumental, or one with
    /// no words.
    static func lyrics(from record: LyricsLookupRecord) -> MusicLyrics? {
        guard record.instrumental != true else { return nil }
        if let synced = record.syncedLyrics, let lyrics = MusicLyrics.parse(synced), lyrics.isSynced {
            return lyrics
        }
        if let plain = record.plainLyrics, let lyrics = MusicLyrics.parse(plain) {
            return lyrics
        }
        return nil
    }

    /// Of several records, the one to show for the song: timed lyrics before plain ones, then
    /// the nearest in length. Nil when none of them is the song, or none has words.
    static func best(of records: [LyricsLookupRecord], for query: LyricsLookupQuery) -> (record: LyricsLookupRecord, lyrics: MusicLyrics)? {
        let candidates = records.compactMap { record -> (record: LyricsLookupRecord, lyrics: MusicLyrics)? in
            guard isSameSong(record, as: query), let lyrics = lyrics(from: record) else { return nil }
            return (record, lyrics)
        }
        return candidates.min { first, second in
            if first.lyrics.isSynced != second.lyrics.isSynced { return first.lyrics.isSynced }
            return abs((first.record.duration ?? 0) - query.duration) < abs((second.record.duration ?? 0) - query.duration)
        }
    }

    /// What a song's lyrics are kept under: its artist, its title and its length.
    static func key(for query: LyricsLookupQuery) -> String {
        "\(artistForms(query.artist).sorted().first ?? "")|\(folded(cleanedTitle(query.title)))|\(Int(query.duration.rounded()))"
    }
}

/// Looks lyrics up at LRCLIB, one request after another, and keeps what it finds.
actor LyricsLookupService {
    static let shared = LyricsLookupService()

    /// First Row's registration with LRCLIB, sent with each request. It says who is asking and
    /// is public: not a key, and nothing is unlocked by it.
    static let applicationID = "ZISnlXL-cvhRZpaUAOSEyOR4einypVhTi90FfqZGAgY"
    static let userAgent = "First Row \(FirstRowVersion.current) (https://github.com/JacksonDam/FirstRow)"

    enum Outcome: Sendable {
        case found(MusicLyrics)
        /// LRCLIB has none for this song: not asked again while First Row is open.
        case none
        /// It couldn't be asked just now (no network, a busy server): nothing is concluded.
        case failed
    }

    /// Where requests go, and whether they go at all. (Not from the test harness: its runs
    /// have no business asking a real server.)
    private var baseURL: URL? = FirstRowHarness.isActive ? nil : URL(string: "https://lrclib.net")
    private var found: [String: MusicLyrics] = [:]
    private var foundOrder: [String] = []
    private var notFound: Set<String> = []
    private var failuresInARow = 0
    private var restsUntil: Date?
    private var sendsApplicationID = true
    private var lastRequestEnded: Date?

    private static let requestTimeout: TimeInterval = 5
    private static let pauseBetweenRequests: TimeInterval = 0.25
    private static let keptSongs = 500
    private static let keptFor: TimeInterval = 30 * 24 * 60 * 60

    // MARK: - Asking

    /// What is already known here for the song, without asking anyone: lyrics found before, or
    /// that LRCLIB had none when it was asked earlier.
    func known(for query: LyricsLookupQuery) -> Outcome? {
        let key = LyricsMatching.key(for: query)
        if let lyrics = found[key] { return .found(lyrics) }
        if notFound.contains(key) { return Outcome.none }
        if let lyrics = readKept(key) {
            remember(lyrics, for: key)
            return .found(lyrics)
        }
        return nil
    }

    /// Asks LRCLIB for the song's lyrics.
    func lookUp(_ query: LyricsLookupQuery) async -> Outcome {
        if let known = known(for: query) { return known }
        guard baseURL != nil, query.duration > 0, !query.title.isEmpty, !query.artist.isEmpty else { return .failed }
        if let restsUntil, restsUntil > Date() { return .failed }
        let key = LyricsMatching.key(for: query)

        // By everything it is known by.
        var items = [URLQueryItem(name: "track_name", value: query.title), URLQueryItem(name: "artist_name", value: query.artist)]
        if !query.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: query.album)) }
        if (1 ... 3600).contains(query.duration.rounded()) { items.append(URLQueryItem(name: "duration", value: String(Int(query.duration.rounded())))) }
        switch await get("/api/get", items) {
        case let .answer(data):
            if let record = try? JSONDecoder().decode(LyricsLookupRecord.self, from: data), let lyrics = LyricsMatching.lyrics(from: record) {
                return keep(lyrics, for: key)
            }
        case .nothing:
            break
        case .failure:
            return .failed
        }

        // By its title and artist, then by its title alone.
        let title = LyricsMatching.cleanedTitle(query.title)
        let artist = query.artist
        for search in [
            [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)],
            [URLQueryItem(name: "track_name", value: title)],
        ] {
            switch await get("/api/search", search) {
            case let .answer(data):
                if let records = try? JSONDecoder().decode([LyricsLookupRecord].self, from: data), let best = LyricsMatching.best(of: records, for: query) {
                    return keep(best.lyrics, for: key)
                }
            case .nothing:
                break
            case .failure:
                return .failed
            }
        }
        notFound.insert(key)
        return Outcome.none
    }

    private func keep(_ lyrics: MusicLyrics, for key: String) -> Outcome {
        remember(lyrics, for: key)
        writeKept(lyrics, for: key)
        return .found(lyrics)
    }

    private func remember(_ lyrics: MusicLyrics, for key: String) {
        if found[key] == nil { foundOrder.append(key) }
        found[key] = lyrics
        while foundOrder.count > 100 { found[foundOrder.removeFirst()] = nil }
    }

    // MARK: - Requests

    private enum Answer {
        case answer(Data)
        /// The server answered, and has nothing for this.
        case nothing
        case failure
    }

    /// One request, after the one before it has finished and a pause.
    private func get(_ path: String, _ items: [URLQueryItem], retrying: Bool = false) async -> Answer {
        guard let baseURL, var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return .failure }
        // (Everything but letters, digits and "-._~" is escaped: a "+" left as it is would be
        // read as a space, an "&" as the end of the value.)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        components.percentEncodedQuery = items.map { item in
            item.name + "=" + ((item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        guard let url = components.url else { return .failure }
        if let lastRequestEnded {
            let wait = Self.pauseBetweenRequests - Date().timeIntervalSince(lastRequestEnded)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if sendsApplicationID { request.setValue(Self.applicationID, forHTTPHeaderField: "Lrclib-App-Id") }
        let result = try? await URLSession.shared.data(for: request)
        lastRequestEnded = Date()
        guard let (data, response) = result, let http = response as? HTTPURLResponse else {
            noteFailure()
            return .failure
        }
        switch http.statusCode {
        case 200:
            failuresInARow = 0
            return .answer(data)
        case 400, 404:
            // (400: something about the song LRCLIB won't take, a length out of its range say.)
            failuresInARow = 0
            return .nothing
        case 401 where sendsApplicationID && !retrying:
            // The registration isn't known there (any more): asked again without it, as
            // anyone may.
            sendsApplicationID = false
            return await get(path, items, retrying: true)
        case 429, 503:
            // Asked to wait: for as long as it says, and a little more, so that everyone told
            // to wait at the same moment doesn't come back at the same moment.
            let stated = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let wait = min(max(stated ?? (http.statusCode == 429 ? 60 : 5), 1), 3600)
            restsUntil = Date().addingTimeInterval(wait * (1 + Double.random(in: 0 ... 0.3)))
            return .failure
        default:
            noteFailure()
            return .failure
        }
    }

    /// Three requests in a row that came to nothing: LRCLIB is left alone for ten minutes.
    private func noteFailure() {
        failuresInARow += 1
        if failuresInARow >= 3 {
            failuresInARow = 0
            restsUntil = Date().addingTimeInterval(600)
        }
    }

    // MARK: - What is kept

    private struct Kept: Codable {
        var key: String
        var saved: Date
        var lines: [KeptLine]
    }

    private struct KeptLine: Codable {
        var time: Double?
        var text: String
    }

    /// The folder lyrics are kept in: among the files the system may clear away when it is
    /// short of room.
    private static var keptFolder: URL? {
        var base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if FirstRowHarness.isActive, let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            base = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Caches", isDirectory: true)
        }
        return base?.appendingPathComponent("First Row", isDirectory: true).appendingPathComponent("Lyrics", isDirectory: true)
    }

    /// A name for a song's file, made of its key (FNV-1a, 64 bits).
    private static func fileName(for key: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16) + ".json"
    }

    private func readKept(_ key: String) -> MusicLyrics? {
        guard let file = Self.keptFolder?.appendingPathComponent(Self.fileName(for: key)),
              let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode(Kept.self, from: data), kept.key == key
        else { return nil }
        guard Date().timeIntervalSince(kept.saved) < Self.keptFor, !kept.lines.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return MusicLyrics(lines: kept.lines.map { MusicLyrics.Line(time: $0.time, text: $0.text) })
    }

    private func writeKept(_ lyrics: MusicLyrics, for key: String) {
        guard let folder = Self.keptFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = Kept(key: key, saved: Date(), lines: lyrics.lines.map { KeptLine(time: $0.time, text: $0.text) })
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.fileName(for: key)), options: .atomic)
        // No more than so many songs' worth: the ones kept longest go first.
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > Self.keptSongs
        else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - Self.keptSongs) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension MenuView {
    /// What LRCLIB is asked by for a song, or nil for something it isn't asked about: a song
    /// with no title or artist to ask by, or no length to tell it by, a preview of a song.
    func lyricsLookupQuery(for song: MusicLibrarySongEntry) -> LyricsLookupQuery? {
        let title = song.title.trimmingCharacters(in: .whitespaces)
        let artist = song.artist.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !artist.isEmpty, artist != L("Unknown Artist") else { return nil }
        // (The store's previews are half a minute of a song, under the chart's name.)
        if thirdMenuMode == .musicITunesTopSongs || musicNowPlayingArtist == L("iTunes Top Songs") || isPlayingSpotifyAdvert { return nil }
        var duration = song.durationSeconds
        if !(duration > 0), activeMusicPlaybackSongID == song.id { duration = musicNowPlayingDurationSeconds }
        guard duration.isFinite, duration > 0 else { return nil }
        return LyricsLookupQuery(title: title, artist: artist, album: song.album.trimmingCharacters(in: .whitespaces), duration: duration)
    }

    /// Lyrics from LRCLIB for a song that has none of its own. Ones found before come at
    /// once; otherwise it is asked once the song has been on for a moment (`stillWanted`
    /// says whether it still is), so that going through songs asks about none of them.
    func lookedUpLyrics(for song: MusicLibrarySongEntry, stillWanted: @escaping @MainActor () -> Bool) async -> MusicLyrics? {
        guard let query = lyricsLookupQuery(for: song) else { return nil }
        if let known = await LyricsLookupService.shared.known(for: query) {
            if case let .found(lyrics) = known { return lyrics }
            return nil
        }
        try? await firstRowSleep(2)
        guard stillWanted() else { return nil }
        if case let .found(lyrics) = await LyricsLookupService.shared.lookUp(query) { return lyrics }
        return nil
    }
}
