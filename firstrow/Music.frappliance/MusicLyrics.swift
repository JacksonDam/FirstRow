import AVFoundation
import Foundation
#if os(iOS)
    import MediaPlayer
#endif

/// A song's words: timed line by line when they came with times (LRC files, synced Jellyfin
/// lyrics), or plain lines otherwise.
struct MusicLyrics: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        /// Seconds into the song, or nil for lyrics without times.
        let time: Double?
        let text: String
    }

    let lines: [Line]

    /// Every line with words in it has a time.
    var isSynced: Bool {
        let worded = lines.filter { !$0.text.isEmpty }
        return !worded.isEmpty && worded.allSatisfy { $0.time != nil }
    }

    /// The line being sung `seconds` into the song: the last one that has started. Nil before the
    /// first line, and for lyrics without times.
    func currentLineIndex(at seconds: Double) -> Int? {
        guard isSynced else { return nil }
        var current: Int?
        for (index, line) in lines.enumerated() {
            guard let time = line.time else { continue }
            if time > seconds { break }
            current = index
        }
        return current
    }

    // MARK: - Reading lyrics text

    /// Lyrics from text: LRC when its lines carry [mm:ss] times, plain lines otherwise. Nil when
    /// there are no words.
    static func parse(_ text: String) -> MusicLyrics? {
        let rawLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if rawLines.contains(where: { leadingTimestamp(in: Substring($0).drop { $0 == " " || $0 == "\t" }) != nil }) {
            return parseLRC(rawLines)
        }
        return parsePlain(rawLines)
    }

    /// The tags an LRC file describes itself with, as opposed to section names like [Chorus].
    private static let lrcInfoTags: Set<String> = ["ar", "al", "ti", "au", "by", "length", "offset", "re", "ve", "tool", "la", "#"]

    private static func isInfoTagLine(_ line: String) -> Bool {
        guard line.hasPrefix("["), line.hasSuffix("]"), let colon = line.firstIndex(of: ":") else { return false }
        let name = line[line.index(after: line.startIndex) ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
        return lrcInfoTags.contains(name)
    }

    private static func parsePlain(_ rawLines: [String]) -> MusicLyrics? {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isInfoTagLine($0) }
            .map { Line(time: nil, text: $0) }
        while lines.first?.text.isEmpty == true { lines.removeFirst() }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        // Runs of blank lines count as one gap.
        var collapsed: [Line] = []
        for line in lines where !(line.text.isEmpty && collapsed.last?.text.isEmpty == true) {
            collapsed.append(line)
        }
        return collapsed.isEmpty ? nil : MusicLyrics(lines: collapsed)
    }

    private static func parseLRC(_ rawLines: [String]) -> MusicLyrics? {
        var offset = 0.0
        var timed: [(time: Double, order: Int, text: String)] = []
        for raw in rawLines {
            var rest = Substring(raw).drop { $0 == " " || $0 == "\t" }
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex) ..< close]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if let colon = tag.firstIndex(of: ":") {
                    // [ar:], [ti:], [length:] and the like describe the file; [offset:] moves every line.
                    let name = tag[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    if name == "offset", let milliseconds = Double(tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                        offset = milliseconds / 1000
                    }
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let text = stripWordTimes(String(rest)).trimmingCharacters(in: .whitespaces)
            for time in times {
                timed.append((time, timed.count, text))
            }
        }
        guard timed.contains(where: { !$0.text.isEmpty }) else { return nil }
        // A positive offset brings the words in sooner.
        let sorted = timed.sorted { ($0.time, $0.order) < ($1.time, $1.order) }
        var lines: [Line] = []
        for entry in sorted where !(entry.text.isEmpty && (lines.isEmpty || lines.last?.text.isEmpty == true)) {
            lines.append(Line(time: max(0, entry.time - offset), text: entry.text))
        }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? nil : MusicLyrics(lines: lines)
    }

    /// The time of a line's first [mm:ss] tag, if it starts with one.
    private static func leadingTimestamp(in line: Substring) -> Double? {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        return timestamp(line[line.index(after: line.startIndex) ..< close])
    }

    /// "mm:ss", "mm:ss.xx", "mm:ss.xxx" or "mm:ss:xx" in seconds.
    private static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0].trimmingCharacters(in: .whitespaces)), minutes >= 0
        else { return nil }
        var secondsText = parts[1].trimmingCharacters(in: .whitespaces)
        if parts.count == 3 { secondsText += "." + parts[2] }
        guard !secondsText.isEmpty, secondsText.allSatisfy({ $0.isNumber || $0 == "." }),
              let seconds = Double(secondsText), seconds < 60
        else { return nil }
        return Double(minutes) * 60 + seconds
    }

    /// Enhanced LRC times words with <mm:ss.xx> inside the line; only the words are kept.
    private static func stripWordTimes(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">"),
               timestamp(text[text.index(after: index) ..< close]) != nil
            {
                index = text.index(after: close)
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result.replacingOccurrences(of: "  ", with: " ")
    }
}

/// Lyrics already looked up, by song id, and lookups under way.
@MainActor
private enum MusicLyricsCache {
    /// nil inside means the song was found to have none.
    static var results: [String: MusicLyrics?] = [:]
    static var loading: [String: Task<(lyrics: MusicLyrics?, keep: Bool), Never>] = [:]

    static func store(_ lyrics: MusicLyrics?, for key: String) {
        if results.count > 300 { results.removeAll() }
        results[key] = lyrics
    }
}

extension MenuView {
    /// The song's lyrics, or nil when it has none. Cached per song id; safe to call repeatedly.
    ///
    /// Looks, in order, for an .lrc file beside a song's file, lyrics stored in the file, the
    /// library's lyrics for the song (iPhone), a Jellyfin server's lyrics, and Music's lyrics for
    /// the track (Mac, only while Music is open).
    func loadMusicLyrics(for song: MusicLibrarySongEntry) async -> MusicLyrics? {
        let key = song.id
        if let cached = MusicLyricsCache.results[key] { return cached }
        if let loading = MusicLyricsCache.loading[key] { return await loading.value.lyrics }
        let fileURL = song.url?.isFileURL == true ? song.url : nil
        let jellyfin = song.jellyfin
        let playsInMusicApp = fileURL == nil || song.prefersSystemMusicPlayerPlayback
        let task = Task { @MainActor () -> (lyrics: MusicLyrics?, keep: Bool) in
            if let fileURL, let lyrics = await Self.lyricsFromFile(fileURL) {
                return (lyrics, true)
            }
            #if os(iOS)
                if let lyrics = await Self.lyricsFromMediaLibrary(persistentID: key) {
                    return (lyrics, true)
                }
            #endif
            if let jellyfin {
                return await self.lyricsFromJellyfin(jellyfin)
            }
            #if os(macOS)
                if playsInMusicApp {
                    // Only while First Row is already driving Music, so asking can't bring up a
                    // permission prompt of its own; until then nothing is remembered.
                    guard self.isCurrentMusicPlaybackUsingAppleScript else { return (nil, false) }
                    return (await self.lyricsFromMusicApp(persistentID: key), true)
                }
            #else
                _ = playsInMusicApp
            #endif
            return (nil, true)
        }
        MusicLyricsCache.loading[key] = task
        let result = await task.value
        MusicLyricsCache.loading[key] = nil
        if result.keep { MusicLyricsCache.store(result.lyrics, for: key) }
        return result.lyrics
    }

    // MARK: - Files

    /// An .lrc file beside the song, then lyrics stored in the song's own tags.
    private nonisolated static func lyricsFromFile(_ url: URL) async -> MusicLyrics? {
        let sidecar = await Task.detached(priority: .utility) { () -> MusicLyrics? in
            let base = url.deletingPathExtension()
            for ext in ["lrc", "LRC"] {
                let candidate = base.appendingPathExtension(ext)
                guard let data = try? Data(contentsOf: candidate), !data.isEmpty else { continue }
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                if let lyrics = MusicLyrics.parse(text) { return lyrics }
            }
            return nil
        }.value
        if let sidecar { return sidecar }
        guard let text = await embeddedLyricsText(url) else { return nil }
        return MusicLyrics.parse(text)
    }

    /// Lyrics in the file's tags: iTunes ©lyr, ID3 USLT, or a Vorbis LYRICS comment.
    private nonisolated static func embeddedLyricsText(_ url: URL) async -> String? {
        #if FIRSTROW_PORTABLE
            return await Task.detached(priority: .utility) { () -> String? in
                let wanted: Set<String> = ["itsk/©lyr", "id3/USLT", "vorbis/LYRICS", "vorbis/UNSYNCEDLYRICS", "vorbis/UNSYNCED LYRICS"]
                for item in AVURLAsset(url: url).metadata {
                    guard let identifier = item.identifier?.rawValue, wanted.contains(identifier),
                          let text = item.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    return text
                }
                return nil
            }.value
        #else
            let asset = AVURLAsset(url: url)
            var items: [AVMetadataItem] = []
            if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
                if let text = try? await asset.load(.lyrics), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
                items = (try? await asset.load(.metadata)) ?? []
            } else {
                if let text = asset.lyrics, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
                items = asset.metadata
            }
            let wanted: Set<AVMetadataIdentifier> = [.iTunesMetadataLyrics, .id3MetadataUnsynchronizedLyric]
            for item in items {
                guard let identifier = item.identifier, wanted.contains(identifier) else { continue }
                let text: String?
                if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
                    text = try? await item.load(.stringValue)
                } else {
                    text = item.stringValue
                }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
            return nil
        #endif
    }

    // MARK: - iPhone library

    #if os(iOS)
        /// The library's own lyrics for a song, by its persistent id (songs with lyrics in them,
        /// or lyrics added in Music).
        private nonisolated static func lyricsFromMediaLibrary(persistentID: String) async -> MusicLyrics? {
            guard let id = UInt64(persistentID), MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
            return await Task.detached(priority: .utility) { () -> MusicLyrics? in
                let query = MPMediaQuery.songs()
                query.addFilterPredicate(MPMediaPropertyPredicate(
                    value: NSNumber(value: id),
                    forProperty: MPMediaItemPropertyPersistentID,
                    comparisonType: .equalTo,
                ))
                guard let text = query.items?.first?.lyrics else { return nil }
                return MusicLyrics.parse(text)
            }.value
        }
    #endif

    // MARK: - Jellyfin

    private struct JellyfinLyricsResponse: Decodable {
        struct Metadata: Decodable {
            let isSynced: Bool?
            enum CodingKeys: String, CodingKey { case isSynced = "IsSynced" }
        }

        struct Entry: Decodable {
            let text: String?
            /// Ticks of 100 ns.
            let start: Int64?
            enum CodingKeys: String, CodingKey {
                case text = "Text"
                case start = "Start"
            }
        }

        let metadata: Metadata?
        let lyrics: [Entry]?
        enum CodingKeys: String, CodingKey {
            case metadata = "Metadata"
            case lyrics = "Lyrics"
        }
    }

    /// The server's lyrics for a song (Jellyfin 10.9 and later, and 10.8's older address).
    /// A failure to reach the server isn't remembered, so a later look can try again.
    private func lyricsFromJellyfin(_ reference: JellyfinTrackReference) async -> (lyrics: MusicLyrics?, keep: Bool) {
        guard let client = JellyfinStore.shared.server(withKey: reference.serverKey).flatMap({ JellyfinClient(record: $0) }) else {
            return (nil, false)
        }
        var paths = ["/Audio/\(reference.itemID)/Lyrics"]
        if let userID = client.userID {
            paths.append("/Users/\(userID)/Items/\(reference.itemID)/Lyrics")
        }
        var reached = false
        for path in paths {
            let data: Data
            do {
                data = try await client.data("GET", path)
            } catch let JellyfinError.badResponse(status) {
                // 404: none here (or no such address on this version); try the next.
                reached = reached || status == 404
                continue
            } catch {
                continue
            }
            reached = true
            guard let response = try? JSONDecoder().decode(JellyfinLyricsResponse.self, from: data),
                  let entries = response.lyrics, !entries.isEmpty
            else { return (nil, true) }
            let synced = response.metadata?.isSynced ?? entries.contains { $0.start != nil }
            let lines = entries.map { entry in
                MusicLyrics.Line(
                    time: synced ? entry.start.map { Double($0) / 10_000_000 } : nil,
                    text: (entry.text ?? "").trimmingCharacters(in: .whitespaces),
                )
            }
            guard lines.contains(where: { !$0.text.isEmpty }) else { return (nil, true) }
            // Unsynced lyrics sometimes arrive as one entry holding every line.
            if !synced, lines.count == 1, let text = entries.first?.text {
                return (MusicLyrics.parse(text), true)
            }
            return (MusicLyrics(lines: lines), true)
        }
        return (nil, reached)
    }

    // MARK: - Music app

    #if os(macOS)
        /// Music's lyrics for a library track, by its persistent id, while Music is open (First
        /// Row never opens it for this).
        private func lyricsFromMusicApp(persistentID: String) async -> MusicLyrics? {
            guard !FirstRowHarness.isActive,
                  let hexID = Self.musicPersistentIDHexString(forDecimalString: persistentID)
            else { return nil }
            let source = """
            tell application "\(musicApplicationName)"
                if not running then
                    return ""
                end if
                set matches to (every track of library playlist 1 whose persistent ID is "\(hexID)")
                if (count of matches) is 0 then
                    return ""
                end if
                return lyrics of item 1 of matches
            end tell
            """
            let result = await musicAppleScriptExecutor.run {
                executeAppleScript(source)
            }
            guard result.succeeded else { return nil }
            return MusicLyrics.parse(result.standardOutput)
        }
    #endif
}
