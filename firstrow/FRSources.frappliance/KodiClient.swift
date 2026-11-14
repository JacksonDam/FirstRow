import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A computer running Kodi, through the remote control over HTTP that Kodi offers when it's
/// turned on in its settings (Services, Control): its movie, show and music libraries, the
/// folders it has been pointed at, and each file through Kodi itself, wherever Kodi keeps it.
struct KodiClient: MediaServerClient {
    let baseURL: URL
    let user: String?
    let password: String?

    init?(record: MediaServerRecord) {
        guard let url = URL(string: record.address) else { return nil }
        self.init(baseURL: url, user: record.user, password: record.password)
    }

    init(baseURL: URL, user: String?, password: String?) {
        self.baseURL = baseURL
        self.user = user
        self.password = password
    }

    // MARK: Asking Kodi

    private var signInHeader: String? {
        guard let user, !user.isEmpty else { return nil }
        return "Basic " + Data("\(user):\(password ?? "")".utf8).base64EncodedString()
    }

    private var base: String {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let url = URL(string: base + "/jsonrpc") else { throw MediaServerError.unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let signInHeader { request.setValue(signInHeader, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let (data, _) = try await ServerHTTP.data(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MediaServerError.notAServer(.kodi) }
        if object["error"] != nil { throw MediaServerError.nothingPlayable }
        if let result = object["result"] as? [String: Any] { return result }
        // (An answer that is a word, not a list.)
        return ["value": object["result"] ?? ""]
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// One of Kodi's files, fetched through Kodi.
    private func file(_ path: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: base + "/vfs/" + encoded)
    }

    private func picture(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: base + "/image/" + encoded)
    }

    // MARK: Finding Kodi

    static func find(at typed: String, user: String?, password: String?) async throws -> FoundMediaServer {
        var lastError: Error = MediaServerError.unreachable
        for candidate in ServerHTTP.candidates(for: typed, port: 8080) {
            let client = KodiClient(baseURL: candidate, user: user, password: password)
            do {
                let answer = try await client.call("JSONRPC.Ping", timeout: 6)
                guard (answer["value"] as? String) == "pong" else { throw MediaServerError.notAServer(.kodi) }
                let labels = try? await client.call("XBMC.GetInfoLabels", ["labels": ["System.FriendlyName"]], timeout: 6)
                var address = candidate.absoluteString
                while address.hasSuffix("/") { address.removeLast() }
                return FoundMediaServer(kind: .kodi, name: text(labels?["System.FriendlyName"]) ?? "Kodi", address: address)
            } catch {
                lastError = error
                if case MediaServerError.signInNeeded = error { break }
            }
        }
        throw lastError
    }

    // MARK: Looking in Kodi

    func top() async throws -> [ServerItem] {
        // (Asked for one of each, to leave out what Kodi has none of.)
        async let movies = call("VideoLibrary.GetMovies", ["limits": ["end": 1]])
        async let shows = call("VideoLibrary.GetTVShows", ["limits": ["end": 1]])
        async let artists = call("AudioLibrary.GetArtists", ["limits": ["end": 1]])
        async let folders = call("Files.GetSources", ["media": "video"])
        var items: [ServerItem] = []
        func has(_ answer: [String: Any]?, _ key: String) -> Bool {
            !((answer?[key] as? [Any]) ?? []).isEmpty
        }
        // (Kodi must answer the first of these at least: the rest may fail one by one.)
        let foundMovies = try await movies
        if has(foundMovies, "movies") { items.append(ServerItem(id: "kodi:movies", kind: .folder, title: L("Movies"), details: ["list": "movies"])) }
        if has(try? await shows, "tvshows") { items.append(ServerItem(id: "kodi:shows", kind: .folder, title: L("TV Shows"), details: ["list": "shows"])) }
        if has(try? await artists, "artists") { items.append(ServerItem(id: "kodi:music", kind: .folder, title: L("Music"), details: ["list": "artists"])) }
        if has(try? await folders, "sources") { items.append(ServerItem(id: "kodi:files", kind: .folder, title: L("Folders"), details: ["list": "sources"])) }
        return items
    }

    func children(of item: ServerItem) async throws -> [ServerItem] {
        let byTitle: [String: Any] = ["method": "sorttitle", "order": "ascending", "ignorearticle": true]
        switch item.details["list"] ?? "" {
        case "movies":
            let answer = try await call("VideoLibrary.GetMovies", ["properties": ["title", "year", "plot", "runtime", "file", "thumbnail", "resume", "playcount", "mpaa"], "sort": byTitle])
            return ((answer["movies"] as? [[String: Any]]) ?? []).compactMap { video($0, kind: .movie, idKey: "movieid") }
        case "shows":
            let answer = try await call("VideoLibrary.GetTVShows", ["properties": ["title", "year", "plot", "thumbnail", "episode", "watchedepisodes"], "sort": byTitle])
            return ((answer["tvshows"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let id = Self.number(entry["tvshowid"]).map({ Int($0) }) else { return nil }
                var show = ServerItem(id: "kodi:show:\(id)", kind: .show, title: Self.text(entry["title"]) ?? Self.text(entry["label"]) ?? L("Untitled"), details: ["list": "seasons", "show": "\(id)"])
                show.year = Self.number(entry["year"]).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
                show.overview = Self.text(entry["plot"])
                show.imageURL = picture(Self.text(entry["thumbnail"]))
                show.isUnwatched = (Self.number(entry["watchedepisodes"]) ?? 0) < (Self.number(entry["episode"]) ?? 0)
                return show
            }
        case "seasons":
            guard let show = item.details["show"].flatMap({ Int($0) }) else { return [] }
            let answer = try await call("VideoLibrary.GetSeasons", ["tvshowid": show, "properties": ["season", "thumbnail", "episode", "watchedepisodes"]])
            return ((answer["seasons"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let number = Self.number(entry["season"]).map({ Int($0) }) else { return nil }
                var season = ServerItem(id: "kodi:show:\(show):\(number)", kind: .season, title: Self.text(entry["label"]) ?? "Season \(number)", details: ["list": "episodes", "show": "\(show)", "season": "\(number)"])
                season.imageURL = picture(Self.text(entry["thumbnail"])) ?? item.imageURL
                season.isUnwatched = (Self.number(entry["watchedepisodes"]) ?? 0) < (Self.number(entry["episode"]) ?? 0)
                return season
            }
        case "episodes":
            guard let show = item.details["show"].flatMap({ Int($0) }), let season = item.details["season"].flatMap({ Int($0) }) else { return [] }
            let answer = try await call("VideoLibrary.GetEpisodes", [
                "tvshowid": show, "season": season,
                "properties": ["title", "plot", "runtime", "file", "thumbnail", "resume", "playcount", "episode", "season", "showtitle"],
                "sort": ["method": "episode", "order": "ascending"],
            ])
            return ((answer["episodes"] as? [[String: Any]]) ?? []).compactMap { video($0, kind: .episode, idKey: "episodeid") }
        case "artists":
            let answer = try await call("AudioLibrary.GetArtists", ["albumartistsonly": true, "properties": ["thumbnail"], "sort": ["method": "artist", "order": "ascending", "ignorearticle": true]])
            return ((answer["artists"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let id = Self.number(entry["artistid"]).map({ Int($0) }) else { return nil }
                var artist = ServerItem(id: "kodi:artist:\(id)", kind: .artist, title: Self.text(entry["artist"]) ?? Self.text(entry["label"]) ?? L("Unknown Artist"), details: ["list": "albums", "artist": "\(id)"])
                artist.imageURL = picture(Self.text(entry["thumbnail"]))
                return artist
            }
        case "albums":
            guard let artist = item.details["artist"].flatMap({ Int($0) }) else { return [] }
            let answer = try await call("AudioLibrary.GetAlbums", ["filter": ["artistid": artist], "properties": ["title", "year", "thumbnail", "artist"], "sort": ["method": "year", "order": "ascending"]])
            return ((answer["albums"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let id = Self.number(entry["albumid"]).map({ Int($0) }) else { return nil }
                var album = ServerItem(id: "kodi:album:\(id)", kind: .album, title: Self.text(entry["title"]) ?? Self.text(entry["label"]) ?? L("Unknown Album"), details: ["list": "songs", "album": "\(id)"])
                album.year = Self.number(entry["year"]).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
                album.artist = (entry["artist"] as? [String])?.first
                album.imageURL = picture(Self.text(entry["thumbnail"]))
                return album
            }
        case "songs":
            guard let album = item.details["album"].flatMap({ Int($0) }) else { return [] }
            let answer = try await call("AudioLibrary.GetSongs", ["filter": ["albumid": album], "properties": ["title", "artist", "album", "duration", "track", "disc", "file", "thumbnail"], "sort": ["method": "track", "order": "ascending"]])
            return ((answer["songs"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let id = Self.number(entry["songid"]).map({ Int($0) }), let path = Self.text(entry["file"]), let url = file(path) else { return nil }
                var song = ServerItem(id: "kodi:song:\(id)", kind: .song, title: Self.text(entry["title"]) ?? Self.text(entry["label"]) ?? L("Untitled"))
                song.artist = (entry["artist"] as? [String])?.first
                song.album = Self.text(entry["album"])
                song.durationSeconds = Self.number(entry["duration"]) ?? 0
                song.trackNumber = Self.number(entry["track"]).map { Int($0) } ?? 0
                song.discNumber = Self.number(entry["disc"]).map { Int($0) } ?? 0
                song.imageURL = picture(Self.text(entry["thumbnail"])) ?? item.imageURL
                song.mediaURL = url
                return song
            }
        case "sources":
            let answer = try await call("Files.GetSources", ["media": "video"])
            return ((answer["sources"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let path = Self.text(entry["file"]) else { return nil }
                return ServerItem(id: "kodi:dir:\(path)", kind: .folder, title: Self.text(entry["label"]) ?? path, details: ["list": "directory", "directory": path])
            }
        case "directory":
            guard let directory = item.details["directory"] else { return [] }
            let answer = try await call("Files.GetDirectory", ["directory": directory, "media": "video", "properties": ["title", "file", "runtime", "resume", "playcount", "thumbnail"], "sort": ["method": "label", "order": "ascending", "ignorearticle": true]])
            return ((answer["files"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let path = Self.text(entry["file"]) else { return nil }
                let label = Self.text(entry["label"]) ?? path
                if (entry["filetype"] as? String) == "directory" {
                    return ServerItem(id: "kodi:dir:\(path)", kind: .folder, title: label, details: ["list": "directory", "directory": path])
                }
                var movie = video(entry, kind: .video, idKey: "id")
                movie?.id = "kodi:file:\(path)"
                movie?.title = label
                movie?.details["id"] = nil
                return movie
            }
        default:
            return []
        }
    }

    private func video(_ entry: [String: Any], kind: ServerItem.Kind, idKey: String) -> ServerItem? {
        guard let path = Self.text(entry["file"]) else { return nil }
        let id = Self.number(entry[idKey]).map { Int($0) }
        var item = ServerItem(id: "kodi:\(kind.rawValue):\(id.map(String.init) ?? path)", kind: kind, title: Self.text(entry["title"]) ?? Self.text(entry["label"]) ?? L("Untitled"))
        item.details["file"] = path
        if let id { item.details["id"] = "\(id)" }
        item.year = Self.number(entry["year"]).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        item.overview = Self.text(entry["plot"])
        item.rating = Self.text(entry["mpaa"])
        item.durationSeconds = Self.number(entry["runtime"]) ?? 0
        let resume = entry["resume"] as? [String: Any]
        item.resumeSeconds = Self.number(resume?["position"]) ?? 0
        if item.durationSeconds <= 0, let total = Self.number(resume?["total"]), total > 0 { item.durationSeconds = total }
        item.isUnwatched = (Self.number(entry["playcount"]) ?? 0) < 1 && item.resumeSeconds < 1
        item.imageURL = picture(Self.text(entry["thumbnail"]))
        if kind == .episode {
            item.showTitle = Self.text(entry["showtitle"])
            if let number = Self.number(entry["episode"]).map({ Int($0) }), number > 0 { item.title = "\(number). \(item.title)" }
        }
        return item
    }

    // MARK: Playing

    func video(for item: ServerItem) async throws -> ServerVideo {
        guard let path = item.details["file"], let url = file(path) else { throw MediaServerError.nothingPlayable }
        var video = ServerVideo(url: url)
        if let signInHeader { video.headers["Authorization"] = signInHeader }
        return video
    }

    func note(_ moment: ServerPlaybackMoment, of item: ServerItem, seconds: Double) async {
        // Kodi is told once, as the movie is left: where it was stopped, or that it was watched.
        guard moment == .stopped || moment == .ended, let id = item.details["id"].flatMap({ Int($0) }) else { return }
        let method: String
        let key: String
        switch item.kind {
        case .movie: (method, key) = ("VideoLibrary.SetMovieDetails", "movieid")
        case .episode: (method, key) = ("VideoLibrary.SetEpisodeDetails", "episodeid")
        default: return
        }
        var params: [String: Any] = [key: id]
        if moment == .ended {
            params["resume"] = ["position": 0, "total": 0]
            if let details = try? await call(item.kind == .movie ? "VideoLibrary.GetMovieDetails" : "VideoLibrary.GetEpisodeDetails", [key: id, "properties": ["playcount"]]),
               let entry = (details["moviedetails"] ?? details["episodedetails"]) as? [String: Any]
            {
                params["playcount"] = Int(Self.number(entry["playcount"]) ?? 0) + 1
            } else {
                params["playcount"] = 1
            }
        } else {
            params["resume"] = ["position": Int(max(0, seconds)), "total": Int(max(0, item.durationSeconds))]
        }
        _ = try? await call(method, params, timeout: 8)
    }
}
