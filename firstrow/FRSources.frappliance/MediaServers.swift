import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// The media servers and shared folders First Row plays from, other than Jellyfin and Emby
// (which have menus of their own): Plex, Kodi, anything that speaks UPnP (Windows Media
// Center and Windows Media Player, most network drives, many televisions' recorders) and
// folders shared from another computer or a network drive. Each kind has a client that
// answers the same few questions, and one set of menus shows them all (see
// `MenuView+Servers.swift`).

/// The kinds of server.
enum MediaServerKind: String, Codable, Sendable, CaseIterable {
    case plex
    case kodi
    case upnp
    case sharedFolder

    /// What a server of this kind is called where one is being added.
    var title: String {
        switch self {
        case .plex: "Plex"
        case .kodi: "Kodi"
        case .upnp: "Media Server (UPnP)"
        case .sharedFolder: "Shared Folder"
        }
    }
}

/// A server First Row has been told of, and what it signs in to it with.
struct MediaServerRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: MediaServerKind
    var name: String
    /// Where it is: "http://host:port" for a server, "smb://host" for a shared folder's.
    var address: String
    var user: String?
    var password: String?
    /// A Plex server's token.
    var token: String?
    /// Whatever else its client needs to find it again (a UPnP server's control address).
    var details: [String: String]?
}

/// A server found on the network, or typed in, before it's kept.
struct FoundMediaServer: Equatable, Sendable {
    var kind: MediaServerKind
    var name: String
    var address: String
    var details: [String: String] = [:]
}

enum MediaServerError: LocalizedError {
    case unreachable
    case notAServer(MediaServerKind)
    case signInNeeded
    case signInFailed
    case badAnswer(Int)
    case nothingPlayable
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: "Can't Reach the Server"
        case let .notAServer(kind):
            switch kind {
            case .plex: "Not a Plex Server"
            case .kodi: "Not Kodi (Is Its Remote Control Turned On?)"
            case .upnp: "Not a Media Server"
            case .sharedFolder: "No Shared Folders There"
            }
        case .signInNeeded: "A Name and Password Are Needed"
        case .signInFailed: "Wrong Name or Password"
        case let .badAnswer(code): "Server Error (\(code))"
        case .nothingPlayable: "Can't Play This"
        case let .unsupported(why): why
        }
    }
}

/// Something on a server: a thing to open (a folder, a show, an album) or to play (a movie,
/// an episode, a song).
struct ServerItem: Equatable, Sendable {
    enum Kind: String, Sendable {
        case folder
        case show
        case season
        case movie
        case episode
        case video
        case artist
        case album
        case song
        case playlist
        case photo
    }

    var id: String
    var kind: Kind
    var title: String
    /// Short text at the right of its row ("S2 E3").
    var trailing: String?
    var overview: String?
    var year: Int?
    var rating: String?
    var durationSeconds: Double = 0
    /// Where it was stopped, as the server remembers it.
    var resumeSeconds: Double = 0
    /// A movie or episode the server says hasn't been watched, or a show with some that haven't.
    var isUnwatched = false
    var imageURL: URL?
    /// A show's name, for an episode.
    var showTitle: String?
    var artist: String?
    var album: String?
    var trackNumber = 0
    var discNumber = 0
    /// For a song or a photo: where the file itself is.
    var mediaURL: URL?
    /// What its client needs to find it again.
    var details: [String: String] = [:]

    var isVideo: Bool { kind == .movie || kind == .episode || kind == .video }
    var opens: Bool { !isVideo && kind != .song && kind != .photo }
}

/// How to play a movie that is on a server.
struct ServerVideo: Sendable {
    var url: URL
    /// Sent with each request for it.
    var headers: [String: String] = [:]
    /// Who to sign in to a shared folder as.
    var user: String?
    var password: String?
    var subtitleFiles: [MovieSubtitleFile] = []
}

enum ServerPlaybackMoment: Sendable {
    case started
    case playing
    case paused
    case stopped
    case ended
}

/// One server, as the menus use it.
protocol MediaServerClient: Sendable {
    /// What the server shows first: its libraries, its shared folders.
    func top() async throws -> [ServerItem]
    func children(of item: ServerItem) async throws -> [ServerItem]
    func video(for item: ServerItem) async throws -> ServerVideo
    /// Tells the server where a movie has got to, for servers that keep track.
    func note(_ moment: ServerPlaybackMoment, of item: ServerItem, seconds: Double) async
}

extension MediaServerClient {
    func note(_: ServerPlaybackMoment, of _: ServerItem, seconds _: Double) async {}
}

/// The servers First Row has been told of, in a file only this user can read.
@MainActor
final class MediaServerStore {
    static let shared = MediaServerStore()

    private(set) var servers: [MediaServerRecord] = []
    /// What First Row calls itself to servers that ask who is calling.
    private(set) var clientID = ""

    private struct Contents: Codable {
        var clientID: String
        var servers: [MediaServerRecord]
    }

    private init() {
        load()
    }

    static var fileURL: URL? {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if FirstRowHarness.isActive, let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            base = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return base?.appendingPathComponent("First Row", isDirectory: true).appendingPathComponent("Servers.json")
    }

    func server(withID id: String) -> MediaServerRecord? {
        servers.first { $0.id == id }
    }

    /// Keeps a server, in place of one of the same kind at the same address.
    func save(_ record: MediaServerRecord) {
        if let index = servers.firstIndex(where: { $0.id == record.id || ($0.kind == record.kind && $0.address == record.address && $0.user == record.user) }) {
            var kept = record
            kept.id = servers[index].id
            servers[index] = kept
        } else {
            servers.append(record)
        }
        write()
    }

    func remove(_ record: MediaServerRecord) {
        servers.removeAll { $0.id == record.id }
        write()
    }

    private func load() {
        if let url = Self.fileURL, let data = try? Data(contentsOf: url),
           let contents = try? JSONDecoder().decode(Contents.self, from: data)
        {
            clientID = contents.clientID
            servers = contents.servers
        }
        if clientID.isEmpty {
            clientID = UUID().uuidString.lowercased()
        }
    }

    private func write() {
        guard let url = Self.fileURL else { return }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Contents(clientID: clientID, servers: servers)) else { return }
        // Written with no permissions for anyone else from the start, since it holds passwords.
        if FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Fetching from servers over HTTP.
enum ServerHTTP {
    /// The answer to a request, or an error a person can be shown.
    static func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MediaServerError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw MediaServerError.unreachable }
        if http.statusCode == 401 || http.statusCode == 403 { throw MediaServerError.signInNeeded }
        guard (200 ..< 300).contains(http.statusCode) else { throw MediaServerError.badAnswer(http.statusCode) }
        return (data, http)
    }

    /// What someone typed, as addresses to try: with "http://" and the kind's usual port
    /// where they're left out.
    static func candidates(for typed: String, port: Int, securePort: Int? = nil) -> [URL] {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return [] }
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            return URL(string: text).map { [$0] } ?? []
        }
        let hasPort: Bool = {
            guard let colon = text.lastIndex(of: ":"), text.filter({ $0 == ":" }).count == 1 else { return false }
            return Int(text[text.index(after: colon)...]) != nil
        }()
        if hasPort {
            return [URL(string: "http://\(text)"), URL(string: "https://\(text)")].compactMap { $0 }
        }
        var urls = [URL(string: "http://\(text):\(port)")]
        if let securePort { urls.append(URL(string: "https://\(text):\(securePort)")) }
        return urls.compactMap { $0 }
    }
}
