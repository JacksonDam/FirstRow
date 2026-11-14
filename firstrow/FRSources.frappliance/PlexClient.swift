import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What First Row calls itself to a Plex server and to plex.tv.
struct PlexCaller: Sendable {
    var clientID: String
    var deviceName: String

    @MainActor
    static var current: PlexCaller {
        PlexCaller(clientID: MediaServerStore.shared.clientID, deviceName: jellyfinDeviceName)
    }

    var headers: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Product": "First Row",
            "X-Plex-Version": FirstRowVersion.number,
            "X-Plex-Device-Name": deviceName,
            "X-Plex-Platform": Self.platform,
        ]
    }

    static var platform: String {
        #if os(macOS)
            "macOS"
        #elseif os(tvOS)
            "tvOS"
        #elseif os(iOS)
            "iOS"
        #elseif os(Windows)
            "Windows"
        #else
            "Linux"
        #endif
    }
}

/// A Plex Media Server: its libraries, what is in them, and where each movie's file is.
struct PlexClient: MediaServerClient {
    let baseURL: URL
    let token: String?
    let caller: PlexCaller

    @MainActor
    init?(record: MediaServerRecord) {
        guard let url = URL(string: record.address) else { return nil }
        baseURL = url
        token = record.token
        caller = .current
    }

    init(baseURL: URL, token: String?, caller: PlexCaller) {
        self.baseURL = baseURL
        self.token = token
        self.caller = caller
    }

    // MARK: Asking the server

    private func url(_ path: String, _ query: [(String, String)] = [], withToken: Bool = false) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + path) ?? URLComponents()
        var items = components.queryItems ?? []
        items += query.map { URLQueryItem(name: $0.0, value: $0.1) }
        if withToken, let token { items.append(URLQueryItem(name: "X-Plex-Token", value: token)) }
        if !items.isEmpty { components.queryItems = items }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? baseURL
    }

    /// The server's answer to a request, as the list of things inside it.
    private func container(_ path: String, _ query: [(String, String)] = [], timeout: TimeInterval = 20) async throws -> [String: Any] {
        var request = URLRequest(url: url(path, query))
        request.timeoutInterval = timeout
        for (name, value) in caller.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        let (data, _) = try await ServerHTTP.data(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = object["MediaContainer"] as? [String: Any]
        else { throw MediaServerError.notAServer(.plex) }
        return container
    }

    private static func entries(_ container: [String: Any]) -> [[String: Any]] {
        (container["Metadata"] as? [[String: Any]]) ?? (container["Directory"] as? [[String: Any]]) ?? []
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: Finding a server

    /// The server at an address someone typed, if it lets First Row in as it is.
    static func find(at typed: String, caller: PlexCaller) async throws -> FoundMediaServer {
        var lastError: Error = MediaServerError.unreachable
        for candidate in ServerHTTP.candidates(for: typed, port: 32400) {
            let client = PlexClient(baseURL: candidate, token: nil, caller: caller)
            do {
                let identity = try await client.container("/identity", timeout: 6)
                guard identity["machineIdentifier"] != nil else { throw MediaServerError.notAServer(.plex) }
                let root: [String: Any]
                do {
                    root = try await client.container("/", timeout: 8)
                } catch MediaServerError.signInNeeded {
                    throw MediaServerError.unsupported(L("This Server Needs You to Sign In to Plex"))
                }
                var address = candidate.absoluteString
                while address.hasSuffix("/") { address.removeLast() }
                return FoundMediaServer(kind: .plex, name: text(root["friendlyName"]) ?? candidate.host ?? "Plex", address: address)
            } catch {
                lastError = error
                if case MediaServerError.unsupported = error { break }
            }
        }
        throw lastError
    }

    // MARK: Looking in the server

    func top() async throws -> [ServerItem] {
        async let sections = container("/library/sections")
        async let onDeck = container("/library/onDeck", [("X-Plex-Container-Size", "1"), ("X-Plex-Container-Start", "0")])
        async let playlists = container("/playlists", [("playlistType", "audio"), ("X-Plex-Container-Size", "1"), ("X-Plex-Container-Start", "0")])
        var items: [ServerItem] = []
        if let deck = try? await onDeck, !Self.entries(deck).isEmpty {
            items.append(ServerItem(id: "plex:ondeck", kind: .folder, title: L("Continue Watching"), details: ["path": "/library/onDeck"]))
        }
        for section in try await Self.entries(sections) {
            guard let key = Self.text(section["key"]), let title = Self.text(section["title"]) else { continue }
            let kind: String
            switch Self.text(section["type"]) ?? "" {
            case "movie": kind = "1"
            case "show": kind = "2"
            case "artist": kind = "8"
            default: continue
            }
            var item = ServerItem(id: "plex:section:\(key)", kind: .folder, title: title, details: ["path": "/library/sections/\(key)/all", "type": kind])
            item.imageURL = picture(Self.text(section["composite"]) ?? Self.text(section["thumb"]))
            items.append(item)
        }
        if let lists = try? await playlists, !Self.entries(lists).isEmpty {
            items.append(ServerItem(id: "plex:playlists", kind: .folder, title: L("Playlists"), details: ["path": "/playlists", "playlists": "audio"]))
        }
        return items
    }

    func children(of item: ServerItem) async throws -> [ServerItem] {
        guard let path = item.details["path"] else { return [] }
        var query: [(String, String)] = []
        if let type = item.details["type"] { query += [("type", type), ("sort", "titleSort")] }
        if let kind = item.details["playlists"] { query.append(("playlistType", kind)) }
        let found = try await container(path, query, timeout: 40)
        let showsEpisodesByShow = path == "/library/onDeck"
        return Self.entries(found).compactMap { self.item(from: $0, namingShow: showsEpisodesByShow) }
    }

    private func item(from entry: [String: Any], namingShow: Bool) -> ServerItem? {
        guard let ratingKey = Self.text(entry["ratingKey"]), let title = Self.text(entry["title"]) else { return nil }
        let type = Self.text(entry["type"]) ?? ""
        var item = ServerItem(id: "plex:\(ratingKey)", kind: .folder, title: title)
        item.details["ratingKey"] = ratingKey
        item.overview = Self.text(entry["summary"])
        item.year = Self.number(entry["year"]).map { Int($0) }
        item.rating = Self.text(entry["contentRating"])
        item.durationSeconds = (Self.number(entry["duration"]) ?? 0) / 1000
        item.resumeSeconds = (Self.number(entry["viewOffset"]) ?? 0) / 1000
        let views = Self.number(entry["viewCount"]) ?? 0
        let media = (entry["Media"] as? [[String: Any]])?.first
        let part = (media?["Part"] as? [[String: Any]])?.first
        if let key = Self.text(part?["key"]) { item.details["part"] = key }
        switch type {
        case "movie", "clip":
            item.kind = type == "movie" ? .movie : .video
            item.isUnwatched = views < 1 && item.resumeSeconds < 1
            item.imageURL = picture(Self.text(entry["thumb"]))
        case "episode":
            item.kind = .episode
            item.isUnwatched = views < 1 && item.resumeSeconds < 1
            item.showTitle = Self.text(entry["grandparentTitle"])
            let season = Self.number(entry["parentIndex"]).map { Int($0) }
            let number = Self.number(entry["index"]).map { Int($0) }
            if namingShow {
                item.title = item.showTitle ?? title
                item.overview = [title, item.overview].compactMap { $0 }.joined(separator: "\n")
                if let number { item.trailing = season.map { "S\($0) E\(number)" } ?? "E\(number)" }
            } else if let number {
                item.title = "\(number). \(title)"
            }
            item.imageURL = picture(Self.text(entry["grandparentThumb"]) ?? Self.text(entry["parentThumb"]) ?? Self.text(entry["thumb"]))
        case "show":
            item.kind = .show
            item.details["path"] = "/library/metadata/\(ratingKey)/children"
            item.isUnwatched = (Self.number(entry["viewedLeafCount"]) ?? 0) < (Self.number(entry["leafCount"]) ?? 0)
            item.imageURL = picture(Self.text(entry["thumb"]))
        case "season":
            item.kind = .season
            item.details["path"] = "/library/metadata/\(ratingKey)/children"
            item.isUnwatched = (Self.number(entry["viewedLeafCount"]) ?? 0) < (Self.number(entry["leafCount"]) ?? 0)
            item.imageURL = picture(Self.text(entry["thumb"]) ?? Self.text(entry["parentThumb"]))
        case "artist":
            item.kind = .artist
            item.details["path"] = "/library/metadata/\(ratingKey)/children"
            item.imageURL = picture(Self.text(entry["thumb"]))
        case "album":
            item.kind = .album
            item.details["path"] = "/library/metadata/\(ratingKey)/children"
            item.artist = Self.text(entry["parentTitle"])
            item.imageURL = picture(Self.text(entry["thumb"]))
        case "track":
            item.kind = .song
            item.artist = Self.text(entry["originalTitle"]) ?? Self.text(entry["grandparentTitle"])
            item.album = Self.text(entry["parentTitle"])
            item.trackNumber = Self.number(entry["index"]).map { Int($0) } ?? 0
            item.discNumber = Self.number(entry["parentIndex"]).map { Int($0) } ?? 0
            item.imageURL = picture(Self.text(entry["thumb"]) ?? Self.text(entry["parentThumb"]))
            if let key = item.details["part"] { item.mediaURL = url(key, withToken: true) }
            if item.mediaURL == nil { return nil }
        case "playlist":
            item.kind = .playlist
            item.details["path"] = "/playlists/\(ratingKey)/items"
            item.imageURL = picture(Self.text(entry["composite"]) ?? Self.text(entry["thumb"]))
        default:
            return nil
        }
        return item
    }

    /// A picture of the server's, at a size for the menus.
    private func picture(_ path: String?) -> URL? {
        guard let path else { return nil }
        return url("/photo/:/transcode", [("width", "900"), ("height", "900"), ("minSize", "1"), ("upscale", "1"), ("url", path)], withToken: true)
    }

    // MARK: Playing

    func video(for item: ServerItem) async throws -> ServerVideo {
        guard let ratingKey = item.details["ratingKey"] else { throw MediaServerError.nothingPlayable }
        // (All of what the server knows of it: its file, and the subtitle files beside it.)
        let found = try? await container("/library/metadata/\(ratingKey)")
        let entry = found.flatMap { Self.entries($0).first }
        let part = ((entry?["Media"] as? [[String: Any]])?.first?["Part"] as? [[String: Any]])?.first
        guard let key = Self.text(part?["key"]) ?? item.details["part"] else { throw MediaServerError.nothingPlayable }
        var video = ServerVideo(url: url(key, withToken: true))
        for stream in (part?["Stream"] as? [[String: Any]]) ?? [] {
            // (A subtitle track with an address of its own is a file kept beside the movie.)
            guard Self.number(stream["streamType"]) == 3, let key = Self.text(stream["key"]) else { continue }
            video.subtitleFiles.append(MovieSubtitleFile(
                url: url(key, withToken: true),
                language: Self.text(stream["languageTag"]) ?? Self.text(stream["languageCode"]),
                name: Self.text(stream["title"]),
            ))
        }
        return video
    }

    func note(_ moment: ServerPlaybackMoment, of item: ServerItem, seconds: Double) async {
        guard let ratingKey = item.details["ratingKey"] else { return }
        let state = switch moment {
        case .started, .playing: "playing"
        case .paused: "paused"
        case .stopped, .ended: "stopped"
        }
        _ = try? await container("/:/timeline", [
            ("ratingKey", ratingKey),
            ("key", "/library/metadata/\(ratingKey)"),
            ("identifier", "com.plexapp.plugins.library"),
            ("state", state),
            ("time", "\(Int(max(0, seconds) * 1000))"),
            ("duration", "\(Int(max(0, item.durationSeconds) * 1000))"),
        ], timeout: 8)
        if moment == .ended {
            _ = try? await container("/:/scrobble", [("identifier", "com.plexapp.plugins.library"), ("key", ratingKey)], timeout: 8)
        }
    }
}

/// Signing in to Plex with a code typed at plex.tv/link, which is how a television does it,
/// and finding the servers the account can use.
enum PlexAccount {
    struct Code: Sendable {
        var id: Int
        var code: String
    }

    private static func request(_ method: String, _ address: String, caller: PlexCaller, token: String? = nil) -> URLRequest? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        for (name, value) in caller.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return request
    }

    /// Asks plex.tv for a code to show.
    static func requestCode(caller: PlexCaller) async throws -> Code {
        guard let request = request("POST", "https://plex.tv/api/v2/pins", caller: caller) else { throw MediaServerError.unreachable }
        let (data, _) = try await ServerHTTP.data(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.intValue, let code = object["code"] as? String
        else { throw MediaServerError.unreachable }
        return Code(id: id, code: code)
    }

    /// The account's token once the code has been typed in, nil until then.
    static func token(for code: Code, caller: PlexCaller) async -> String? {
        guard let request = request("GET", "https://plex.tv/api/v2/pins/\(code.id)", caller: caller),
              let (data, _) = try? await ServerHTTP.data(request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["authToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    /// The account's servers, each at the first of its addresses that answers: one on this
    /// network if there is one, then one over the internet, then Plex's relay.
    static func servers(token: String, caller: PlexCaller) async throws -> [FoundMediaServer] {
        guard let request = request("GET", "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", caller: caller, token: token) else { throw MediaServerError.unreachable }
        let (data, _) = try await ServerHTTP.data(request)
        guard let resources = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MediaServerError.unreachable }
        var found: [FoundMediaServer] = []
        for resource in resources {
            guard let provides = resource["provides"] as? String, provides.contains("server"),
                  let name = resource["name"] as? String,
                  let connections = resource["connections"] as? [[String: Any]]
            else { continue }
            let access = (resource["accessToken"] as? String) ?? token
            func rank(_ connection: [String: Any]) -> Int {
                if (connection["relay"] as? Bool) == true { return 2 }
                return (connection["local"] as? Bool) == true ? 0 : 1
            }
            for connection in connections.sorted(by: { rank($0) < rank($1) }) {
                guard let address = connection["uri"] as? String, let url = URL(string: address) else { continue }
                let client = PlexClient(baseURL: url, token: access, caller: caller)
                guard (try? await client.top()) != nil else { continue }
                found.append(FoundMediaServer(kind: .plex, name: name, address: address, details: ["token": access]))
                break
            }
        }
        return found
    }
}
