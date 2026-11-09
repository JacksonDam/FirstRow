import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

// Talking to Jellyfin servers: the saved sign-ins, the HTTP API and the items it returns.

/// A server and the account First Row signed in to it with.
struct JellyfinServerRecord: Codable, Equatable, Sendable {
    var serverID: String
    var serverName: String
    var url: String
    var userID: String
    var userName: String
    var accessToken: String

    var key: String { "\(serverID)|\(userID)" }
    var baseURL: URL? { URL(string: url) }
}

/// A server found on the network or typed in, before signing in.
struct JellyfinServerInfo: Equatable, Sendable {
    var id: String
    var name: String
    var url: String
}

enum JellyfinError: LocalizedError {
    case unreachable
    case notJellyfin
    case badResponse(Int)
    case signInFailed
    case quickConnectDisabled
    case nothingPlayable

    var errorDescription: String? {
        switch self {
        case .unreachable: "Can't Reach the Server"
        case .notJellyfin: "Not a Jellyfin Server"
        case let .badResponse(code): code == 401 ? "Signed Out by the Server" : "Server Error (\(code))"
        case .signInFailed: "Wrong User Name or Password"
        case .quickConnectDisabled: "Quick Connect Is Turned Off"
        case .nothingPlayable: "Can't Play This"
        }
    }
}

// MARK: - Saved servers

/// The servers First Row is signed in to, and this device's Jellyfin id, in a file only this user can read.
@MainActor
final class JellyfinStore {
    static let shared = JellyfinStore()
    static let didChangeNotification = Notification.Name("FirstRowJellyfinServersDidChange")

    private(set) var servers: [JellyfinServerRecord] = []
    private(set) var deviceID = ""

    private struct Contents: Codable {
        var deviceID: String
        var servers: [JellyfinServerRecord]
    }

    private init() {
        load()
    }

    static var fileURL: URL? {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if FirstRowHarness.isActive, let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            base = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return base?.appendingPathComponent("First Row", isDirectory: true).appendingPathComponent("Jellyfin.json")
    }

    func server(withKey key: String) -> JellyfinServerRecord? {
        servers.first { $0.key == key }
    }

    func save(_ record: JellyfinServerRecord) {
        if let index = servers.firstIndex(where: { $0.key == record.key }) {
            servers[index] = record
        } else {
            servers.append(record)
        }
        write()
    }

    func remove(_ record: JellyfinServerRecord) {
        servers.removeAll { $0.key == record.key }
        write()
    }

    private func load() {
        if let url = Self.fileURL, let data = try? Data(contentsOf: url),
           let contents = try? JSONDecoder().decode(Contents.self, from: data)
        {
            deviceID = contents.deviceID
            servers = contents.servers
        }
        if deviceID.isEmpty {
            deviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            write()
        }
    }

    private func write() {
        guard let url = Self.fileURL else { return }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Contents(deviceID: deviceID, servers: servers)) else { return }
        // Written with no permissions for anyone else from the start, since it holds access tokens.
        if FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

/// The name Jellyfin shows for this device in its dashboard.
@MainActor
var jellyfinDeviceName: String {
    #if os(macOS)
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #elseif FIRSTROW_PORTABLE
        let name = portableDeviceName
    #else
        let name = UIDevice.current.name
    #endif
    // The header value is quoted, so keep to characters that can't break it.
    let kept = name.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " -_.'".unicodeScalars.contains($0)) }
    let cleaned = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "First Row" : cleaned
}

// MARK: - Items

struct JellyfinUserData: Decodable, Equatable, Sendable {
    var playbackPositionTicks: Int64?
    var played: Bool?
    var unplayedItemCount: Int?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case unplayedItemCount = "UnplayedItemCount"
    }
}

struct JellyfinItem: Decodable, Equatable, Sendable {
    var id: String
    var name: String?
    var type: String?
    var collectionType: String?
    var isFolder: Bool?
    var overview: String?
    var productionYear: Int?
    var runTimeTicks: Int64?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var seriesName: String?
    var seriesID: String?
    var seasonID: String?
    var album: String?
    var albumID: String?
    var albumArtist: String?
    var artists: [String]?
    var genres: [String]?
    var albumPrimaryImageTag: String?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentBackdropItemID: String?
    var parentBackdropImageTags: [String]?
    var seriesPrimaryImageTag: String?
    var officialRating: String?
    var communityRating: Double?
    var mediaType: String?
    var childCount: Int?
    var userData: JellyfinUserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case collectionType = "CollectionType"
        case isFolder = "IsFolder"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesName = "SeriesName"
        case seriesID = "SeriesId"
        case seasonID = "SeasonId"
        case album = "Album"
        case albumID = "AlbumId"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case genres = "Genres"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropItemID = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case mediaType = "MediaType"
        case childCount = "ChildCount"
        case userData = "UserData"
    }

    var title: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var durationSeconds: Double {
        guard let runTimeTicks, runTimeTicks > 0 else { return 0 }
        return Double(runTimeTicks) / 10_000_000
    }

    var resumeSeconds: Double {
        guard let ticks = userData?.playbackPositionTicks, ticks > 0 else { return 0 }
        return Double(ticks) / 10_000_000
    }

    var isVideo: Bool {
        ["Movie", "Episode", "Video", "MusicVideo", "Trailer", "TvChannel"].contains(type ?? "")
    }

    var isUnplayedVideo: Bool {
        isVideo && userData?.played != true && resumeSeconds < 1
    }

    /// "Episode 3" style text for an episode row.
    var episodeLabel: String? {
        guard type == "Episode", let indexNumber else { return nil }
        if let parentIndexNumber {
            return "S\(parentIndexNumber) E\(indexNumber)"
        }
        return "E\(indexNumber)"
    }
}

private struct JellyfinItemsResponse: Decodable {
    var items: [JellyfinItem]
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct JellyfinPublicInfo: Decodable, Sendable {
    var serverName: String?
    var id: String?
    var version: String?
    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case id = "Id"
        case version = "Version"
    }
}

struct JellyfinAuthResult: Decodable, Sendable {
    struct User: Decodable, Sendable {
        var id: String
        var name: String?
        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
        }
    }

    var user: User
    var accessToken: String
    var serverID: String?
    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverID = "ServerId"
    }
}

struct JellyfinQuickConnect: Decodable, Sendable {
    var secret: String
    var code: String
    var authenticated: Bool
    enum CodingKeys: String, CodingKey {
        case secret = "Secret"
        case code = "Code"
        case authenticated = "Authenticated"
    }
}

struct JellyfinMediaSource: Decodable, Sendable {
    var id: String
    var container: String?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var transcodingURL: String?
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case transcodingURL = "TranscodingUrl"
    }
}

private struct JellyfinPlaybackInfo: Decodable {
    var mediaSources: [JellyfinMediaSource]
    var playSessionID: String?
    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
    }
}

/// Where to stream an item from, and how the server was asked to send it.
struct JellyfinStream: Sendable {
    enum Method: String, Sendable {
        case directPlay = "DirectPlay"
        case directStream = "DirectStream"
        case transcode = "Transcode"
    }

    var url: URL
    var method: Method
    var mediaSourceID: String
    var playSessionID: String
}

// MARK: - The API

/// One server's HTTP API, signed in or not.
struct JellyfinClient: Sendable {
    let baseURL: URL
    let deviceID: String
    let deviceName: String
    var accessToken: String?
    var userID: String?

    static let clientName = "First Row"
    static let clientVersion = "2.0.1"

    @MainActor
    init(baseURL: URL, accessToken: String? = nil, userID: String? = nil) {
        self.baseURL = baseURL
        deviceID = JellyfinStore.shared.deviceID
        deviceName = jellyfinDeviceName
        self.accessToken = accessToken
        self.userID = userID
    }

    @MainActor
    init?(record: JellyfinServerRecord) {
        guard let url = record.baseURL else { return nil }
        self.init(baseURL: url, accessToken: record.accessToken, userID: record.userID)
    }

    var authorization: String {
        var parts = [
            "Client=\"\(Self.clientName)\"",
            "Device=\"\(deviceName)\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"\(Self.clientVersion)\"",
        ]
        if let accessToken { parts.append("Token=\"\(accessToken)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    func url(_ path: String, _ query: [(String, String)] = []) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + path) ?? URLComponents()
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        // "+" in a query value would otherwise reach the server as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? baseURL
    }

    /// A URL for a player or image loader, which can't send headers, so the token rides along.
    func mediaURL(_ path: String, _ query: [(String, String)] = []) -> URL {
        var query = query
        // Newer servers read ApiKey, older ones api_key.
        if let accessToken { query += [("ApiKey", accessToken), ("api_key", accessToken)] }
        return url(path, query)
    }

    func data(_ method: String, _ path: String, query: [(String, String)] = [], json: Any? = nil, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method == "POST" {
            request.httpBody = Data()
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw JellyfinError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.unreachable }
        guard (200 ..< 300).contains(http.statusCode) else { throw JellyfinError.badResponse(http.statusCode) }
        return data
    }

    func decode<T: Decodable>(_: T.Type, _ method: String = "GET", _ path: String, query: [(String, String)] = [], json: Any? = nil) async throws -> T {
        let data = try await data(method, path, query: query, json: json)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JellyfinError.notJellyfin
        }
    }

    // MARK: Server and sign-in

    func publicInfo() async throws -> JellyfinPublicInfo {
        let info = try await decode(JellyfinPublicInfo.self, "GET", "/System/Info/Public")
        guard info.id != nil else { throw JellyfinError.notJellyfin }
        return info
    }

    func authenticate(username: String, password: String) async throws -> JellyfinAuthResult {
        do {
            return try await decode(JellyfinAuthResult.self, "POST", "/Users/AuthenticateByName", json: ["Username": username, "Pw": password])
        } catch JellyfinError.badResponse(let code) where code == 401 || code == 400 {
            throw JellyfinError.signInFailed
        }
    }

    func quickConnectEnabled() async -> Bool {
        guard let data = try? await data("GET", "/QuickConnect/Enabled"),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    func initiateQuickConnect() async throws -> JellyfinQuickConnect {
        do {
            return try await decode(JellyfinQuickConnect.self, "POST", "/QuickConnect/Initiate")
        } catch JellyfinError.badResponse(let code) where code == 405 || code == 404 {
            // Servers before 10.9 start it with a GET.
            return try await decode(JellyfinQuickConnect.self, "GET", "/QuickConnect/Initiate")
        } catch JellyfinError.badResponse(let code) where code == 401 || code == 403 {
            throw JellyfinError.quickConnectDisabled
        }
    }

    func quickConnectState(secret: String) async throws -> JellyfinQuickConnect {
        try await decode(JellyfinQuickConnect.self, "GET", "/QuickConnect/Connect", query: [("secret", secret)])
    }

    func authenticate(quickConnectSecret secret: String) async throws -> JellyfinAuthResult {
        try await decode(JellyfinAuthResult.self, "POST", "/Users/AuthenticateWithQuickConnect", json: ["Secret": secret])
    }

    func signOut() async {
        _ = try? await data("POST", "/Sessions/Logout", timeout: 5)
    }

    // MARK: Browsing

    static let itemFields = "Overview,PrimaryImageAspectRatio,ChildCount,Genres,ParentId"

    func items(_ path: String, _ query: [(String, String)]) async throws -> [JellyfinItem] {
        var query = query
        if !query.contains(where: { $0.0 == "fields" }) { query.append(("fields", Self.itemFields)) }
        if !query.contains(where: { $0.0 == "enableImageTypes" }) { query.append(("enableImageTypes", "Primary,Backdrop,Thumb")) }
        return try await decode(JellyfinItemsResponse.self, "GET", path, query: query).items
    }

    func views() async throws -> [JellyfinItem] {
        try await items("/Users/\(userID ?? "")/Views", [])
    }

    func resumeItems(limit: Int = 50) async throws -> [JellyfinItem] {
        try await items("/Users/\(userID ?? "")/Items/Resume", [("limit", "\(limit)"), ("mediaTypes", "Video")])
    }

    func nextUp(limit: Int = 50) async throws -> [JellyfinItem] {
        try await items("/Shows/NextUp", [("userId", userID ?? ""), ("limit", "\(limit)")])
    }

    func children(of parentID: String?, types: String? = nil, recursive: Bool = false, sortBy: String = "SortName", extra: [(String, String)] = []) async throws -> [JellyfinItem] {
        var query: [(String, String)] = [("userId", userID ?? ""), ("sortBy", sortBy), ("sortOrder", "Ascending")]
        if let parentID { query.append(("parentId", parentID)) }
        if let types { query.append(("includeItemTypes", types)) }
        if recursive { query.append(("recursive", "true")) }
        return try await items("/Items", query + extra)
    }

    func seasons(seriesID: String) async throws -> [JellyfinItem] {
        try await items("/Shows/\(seriesID)/Seasons", [("userId", userID ?? "")])
    }

    func episodes(seriesID: String, seasonID: String?) async throws -> [JellyfinItem] {
        var query: [(String, String)] = [("userId", userID ?? "")]
        if let seasonID { query.append(("seasonId", seasonID)) }
        return try await items("/Shows/\(seriesID)/Episodes", query)
    }

    /// The episode after this one in its series, if there is one.
    func episode(after item: JellyfinItem) async -> JellyfinItem? {
        guard let seriesID = item.seriesID,
              let list = try? await items("/Shows/\(seriesID)/Episodes", [("userId", userID ?? ""), ("startItemId", item.id), ("limit", "2")]),
              list.count > 1, list[0].id == item.id
        else { return nil }
        return list[1]
    }

    func albumArtists(libraryID: String?) async throws -> [JellyfinItem] {
        var query: [(String, String)] = [("userId", userID ?? ""), ("sortBy", "SortName")]
        if let libraryID { query.append(("parentId", libraryID)) }
        return try await items("/Artists/AlbumArtists", query)
    }

    func playlistItems(_ playlistID: String) async throws -> [JellyfinItem] {
        try await items("/Playlists/\(playlistID)/Items", [("userId", userID ?? "")])
    }

    func item(_ id: String) async throws -> JellyfinItem {
        try await decode(JellyfinItem.self, "GET", "/Users/\(userID ?? "")/Items/\(id)")
    }

    // MARK: Pictures

    /// The item's poster or cover, or the one of the album, season or series it belongs to.
    func primaryImageURL(for item: JellyfinItem, maxHeight: Int = 900) -> URL? {
        // Episodes show their series' poster, which suits the preview better than a wide still.
        if item.type == "Episode", let seriesID = item.seriesID, let tag = item.seriesPrimaryImageTag {
            return url("/Items/\(seriesID)/Images/Primary", [("maxHeight", "\(maxHeight)"), ("quality", "90"), ("tag", tag)])
        }
        if let tag = item.imageTags?["Primary"] {
            return url("/Items/\(item.id)/Images/Primary", [("maxHeight", "\(maxHeight)"), ("quality", "90"), ("tag", tag)])
        }
        if let albumID = item.albumID, let tag = item.albumPrimaryImageTag {
            return url("/Items/\(albumID)/Images/Primary", [("maxHeight", "\(maxHeight)"), ("quality", "90"), ("tag", tag)])
        }
        if let seriesID = item.seriesID {
            // Seasons often come without their series' picture tag; the series' own poster still loads.
            var query: [(String, String)] = [("maxHeight", "\(maxHeight)"), ("quality", "90")]
            if let tag = item.seriesPrimaryImageTag { query.append(("tag", tag)) }
            return url("/Items/\(seriesID)/Images/Primary", query)
        }
        return nil
    }

    /// A wide picture for behind the resume prompt.
    func backdropImageURL(for item: JellyfinItem) -> URL? {
        if let tag = item.backdropImageTags?.first {
            return url("/Items/\(item.id)/Images/Backdrop/0", [("maxWidth", "1920"), ("quality", "85"), ("tag", tag)])
        }
        if let parent = item.parentBackdropItemID, let tag = item.parentBackdropImageTags?.first {
            return url("/Items/\(parent)/Images/Backdrop/0", [("maxWidth", "1920"), ("quality", "85"), ("tag", tag)])
        }
        return nil
    }

    func imageData(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode), !data.isEmpty
        else { return nil }
        return data
    }

    // MARK: Playback

    /// Asks the server how to play a video here: straight from the file when this platform's
    /// player can, or converted on the fly when it can't.
    func videoStream(for item: JellyfinItem, startSeconds: Double = 0) async throws -> JellyfinStream {
        let body: [String: Any] = [
            "UserId": userID ?? "",
            "DeviceProfile": Self.deviceProfile,
            "MaxStreamingBitrate": 120_000_000,
            "StartTimeTicks": Int64(startSeconds * 10_000_000),
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": true,
        ]
        let info = try await decode(JellyfinPlaybackInfo.self, "POST", "/Items/\(item.id)/PlaybackInfo", query: [("userId", userID ?? "")], json: body)
        guard let source = info.mediaSources.first else { throw JellyfinError.nothingPlayable }
        let session = info.playSessionID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        if source.supportsDirectPlay == true || source.supportsDirectStream == true {
            let containers = (source.container ?? "").split(separator: ",").map { String($0) }
            #if FIRSTROW_PORTABLE
                let ext = containers.first.map { ".\($0)" } ?? ""
            #else
                let ext = containers.contains("mp4") ? ".mp4" : containers.contains("mov") ? ".mov" : containers.first.map { ".\($0)" } ?? ""
            #endif
            let streamURL = mediaURL("/Videos/\(item.id)/stream\(ext)", [
                ("static", "true"), ("mediaSourceId", source.id), ("deviceId", deviceID), ("playSessionId", session),
            ])
            return JellyfinStream(url: streamURL, method: source.supportsDirectPlay == true ? .directPlay : .directStream, mediaSourceID: source.id, playSessionID: session)
        }
        guard let transcoding = source.transcodingURL, let streamURL = transcodedURL(transcoding) else {
            throw JellyfinError.nothingPlayable
        }
        return JellyfinStream(url: streamURL, method: .transcode, mediaSourceID: source.id, playSessionID: session)
    }

    private func transcodedURL(_ path: String) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: base + (path.hasPrefix("/") ? path : "/" + path)) else { return nil }
        var items = components.queryItems ?? []
        let names = Set(items.map { $0.name.lowercased() })
        if let accessToken, !names.contains("api_key"), !names.contains("apikey") {
            items += [URLQueryItem(name: "ApiKey", value: accessToken), URLQueryItem(name: "api_key", value: accessToken)]
        }
        components.queryItems = items
        return components.url
    }

    /// A song's stream: the file itself where the player can read it, otherwise AAC.
    func audioURL(for item: JellyfinItem) -> URL {
        #if FIRSTROW_PORTABLE
            return mediaURL("/Audio/\(item.id)/stream", [("static", "true"), ("deviceId", deviceID)])
        #else
            return mediaURL("/Audio/\(item.id)/universal", [
                ("userId", userID ?? ""),
                ("deviceId", deviceID),
                ("maxStreamingBitrate", "140000000"),
                ("container", "mp3,aac,m4a|aac,m4b|aac,m4a|alac,flac,wav"),
                ("transcodingContainer", "aac"),
                ("transcodingProtocol", "http"),
                ("audioCodec", "aac"),
            ])
        #endif
    }

    func reportStart(itemID: String, stream: JellyfinStream?, positionSeconds: Double) async {
        _ = try? await data("POST", "/Sessions/Playing", json: reportBody(itemID: itemID, stream: stream, positionSeconds: positionSeconds, isPaused: false), timeout: 8)
    }

    func reportProgress(itemID: String, stream: JellyfinStream?, positionSeconds: Double, isPaused: Bool) async {
        var body = reportBody(itemID: itemID, stream: stream, positionSeconds: positionSeconds, isPaused: isPaused)
        body["EventName"] = isPaused ? "Pause" : "TimeUpdate"
        _ = try? await data("POST", "/Sessions/Playing/Progress", json: body, timeout: 8)
    }

    func reportStopped(itemID: String, stream: JellyfinStream?, positionSeconds: Double) async {
        _ = try? await data("POST", "/Sessions/Playing/Stopped", json: reportBody(itemID: itemID, stream: stream, positionSeconds: positionSeconds, isPaused: false), timeout: 8)
        if let stream, stream.method == .transcode {
            // Stops the server's converter for this session.
            _ = try? await data("DELETE", "/Videos/ActiveEncodings", query: [("deviceId", deviceID), ("playSessionId", stream.playSessionID)], timeout: 8)
        }
    }

    private func reportBody(itemID: String, stream: JellyfinStream?, positionSeconds: Double, isPaused: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "ItemId": itemID,
            "PositionTicks": Int64(max(0, positionSeconds) * 10_000_000),
            "IsPaused": isPaused,
            "CanSeek": true,
            "PlayMethod": stream?.method.rawValue ?? "DirectPlay",
        ]
        if let stream {
            body["MediaSourceId"] = stream.mediaSourceID
            body["PlaySessionId"] = stream.playSessionID
        }
        return body
    }

    /// What this platform's player can play without the server converting it.
    static var deviceProfile: [String: Any] {
        #if FIRSTROW_PORTABLE
            // mpv plays nearly anything, so the files are sent as they are.
            let directPlay: [[String: Any]] = [["Type": "Video"], ["Type": "Audio"]]
        #else
            let directPlay: [[String: Any]] = [
                ["Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,mp3,alac,flac"],
                ["Type": "Audio", "Container": "mp3,aac,m4a,m4b,flac,alac,wav"],
            ]
        #endif
        return [
            "Name": "First Row",
            "MaxStreamingBitrate": 120_000_000,
            "MaxStaticBitrate": 120_000_000,
            "MusicStreamingTranscodingBitrate": 256_000,
            "DirectPlayProfiles": directPlay,
            "TranscodingProfiles": [
                [
                    "Type": "Video", "Container": "ts", "VideoCodec": "h264", "AudioCodec": "aac,ac3,eac3",
                    "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "6", "MinSegments": "1", "BreakOnNonKeyFrames": true,
                ],
                ["Type": "Audio", "Container": "aac", "AudioCodec": "aac", "Protocol": "http", "Context": "Streaming"],
            ],
            "ContainerProfiles": [],
            "CodecProfiles": [],
            "SubtitleProfiles": [],
        ]
    }

    // MARK: Addresses

    /// Turns what someone typed into server addresses to try, most likely first.
    static func candidateURLs(for typed: String) -> [URL] {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return [] }
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            return URL(string: text).map { [$0] } ?? []
        }
        let hostAndPort = text
        let hasPort: Bool = {
            // "host:port", but not a bare IPv6 address.
            guard let colon = hostAndPort.lastIndex(of: ":"), hostAndPort.filter({ $0 == ":" }).count == 1 else { return false }
            return Int(hostAndPort[hostAndPort.index(after: colon)...]) != nil
        }()
        if hasPort {
            return [URL(string: "http://\(hostAndPort)"), URL(string: "https://\(hostAndPort)")].compactMap { $0 }
        }
        return [URL(string: "http://\(hostAndPort):8096"), URL(string: "https://\(hostAndPort)"), URL(string: "https://\(hostAndPort):8920")].compactMap { $0 }
    }
}
