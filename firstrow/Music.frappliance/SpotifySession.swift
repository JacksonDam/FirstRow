import Foundation

/// The page Spotify's web player runs in: a hidden web view on the Mac, a hidden Chrome or Edge
/// window on Linux and Windows. It shows itself only to sign in.
@MainActor
protocol SpotifyPageHost: AnyObject {
    /// Called with each message the bridge sends, as JSON text.
    var messageHandler: ((String) -> Void)? { get set }
    /// Called when the page can't be shown at all, with the reason.
    var failureHandler: ((String) -> Void)? { get set }
    func load(_ url: URL)
    func evaluate(_ script: String)
    /// Shows Spotify's sign-in page. `closed` runs if the person closes it before signing in.
    func presentSignIn(_ url: URL, closed: @escaping () -> Void)
    func dismissSignIn()
    /// Forgets the signed-in account (cookies and stored data), then runs `completion`.
    func forgetAccount(_ completion: @escaping () -> Void)
}

struct SpotifyTrack {
    let uri: String
    let name: String
    let artist: String
    let album: String
    let imageURL: URL?
    let durationSeconds: Double
    let trackNumber: Int
    let discNumber: Int
    let isPlayable: Bool
}

/// A playlist, saved album or followed artist.
struct SpotifyCollection {
    enum Kind {
        case playlist
        case album
        case artist
    }

    let kind: Kind
    let uri: String
    let name: String
    let subtitle: String
    let imageURL: URL?
}

struct SpotifyPlayerState {
    let trackURI: String
    let name: String
    let artist: String
    let album: String
    let imageURL: URL?
    let isAdvert: Bool
    let advertiser: String
    let isPaused: Bool
    let isBuffering: Bool
    let durationSeconds: Double
    let contextURI: String?
    /// The position the page reported, and when it was true (in this machine's time).
    let positionSeconds: Double
    let positionDate: Date

    /// Where playback is now, counting on from the last report while it plays.
    func currentPositionSeconds(at date: Date = Date()) -> Double {
        let position = isPaused || isBuffering
            ? positionSeconds
            : positionSeconds + max(0, date.timeIntervalSince(positionDate))
        return durationSeconds > 0 ? min(position, durationSeconds) : position
    }

    /// How long a report of "playing from the very start" is taken at its word before the
    /// time counts on from it.
    static let startHoldSeconds: TimeInterval = 2

    /// The time to show. While a song loads, Spotify says it's playing from 0:00 again and
    /// again, so counting on from each report made the time flick between 0:00 and 0:01. A
    /// report at the very start stays at 0:00 until a newer one shows it moving, or until none
    /// has come for a couple of seconds (then it really is playing, from that report).
    func displayedPositionSeconds(at date: Date = Date()) -> Double {
        if !isPaused, positionSeconds < 0.05, date.timeIntervalSince(positionDate) < Self.startHoldSeconds {
            return positionSeconds
        }
        return currentPositionSeconds(at: date)
    }
}

enum SpotifySessionSupport {
    /// Spotify plays on the Mac, Linux and Windows. The iPhone, iPad and Apple TV apps don't have it.
    static var isAvailable: Bool {
        #if os(macOS) || FIRSTROW_PORTABLE
            true
        #else
            false
        #endif
    }
}

#if !os(macOS) && !FIRSTROW_PORTABLE
    @MainActor
    func makeSpotifyPageHost() -> SpotifyPageHost? {
        nil
    }

    func spotifyPageHostUnavailableReason() -> String {
        "Spotify Isn't Available Here"
    }
#endif

struct SpotifyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// First Row's connection to Spotify: the hidden web player page, its sign-in and what it plays.
@MainActor
final class SpotifySession {
    static let shared = SpotifySession()
    static let didChangeNotification = Notification.Name("FirstRowSpotifyDidChange")

    enum Status: Equatable {
        /// Not started yet: Spotify loads the first time its menu is opened.
        case idle
        case loading
        case signedOut
        case signedIn
        case unavailable(String)
    }

    private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    private(set) var accountName = ""
    private(set) var username = ""
    private(set) var playerState: SpotifyPlayerState?
    /// Called on every change of what Spotify is playing (nil when it has nothing).
    var playerStateHandler: ((SpotifyPlayerState?) -> Void)?

    private static let playerURL = URL(string: "https://open.spotify.com/")!
    private static let signInURL = URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!

    private var host: SpotifyPageHost?
    private var nextCallID = 0
    private var pendingCalls: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var statusWaiters: [CheckedContinuation<Void, Never>] = []
    private var isSigningIn = false
    private var loadTimeoutTask: Task<Void, Never>?

    private init() {}

    // MARK: - Loading and signing in

    /// Loads the web player in the background if it isn't already.
    func start() {
        guard status == .idle || isUnavailable else { return }
        guard let host = host ?? makeSpotifyPageHost() else {
            status = .unavailable(spotifyPageHostUnavailableReason())
            return
        }
        if self.host == nil {
            host.messageHandler = { [weak self] text in self?.handleMessage(text) }
            host.failureHandler = { [weak self] reason in self?.handleHostFailure(reason) }
            self.host = host
        }
        status = .loading
        host.load(Self.playerURL)
        armLoadTimeout()
    }

    /// Waits until Spotify is signed in, signed out or unavailable.
    func waitUntilSettled() async {
        start()
        guard status == .loading else { return }
        await withCheckedContinuation { statusWaiters.append($0) }
    }

    func signIn() {
        guard let host else {
            start()
            guard self.host != nil else { return }
            signIn()
            return
        }
        isSigningIn = true
        loadTimeoutTask?.cancel()
        host.presentSignIn(Self.signInURL) { [weak self] in
            guard let self else { return }
            isSigningIn = false
            // Back to the player page, still signed out (or signed in, if that finished as it closed).
            status = .loading
            host.load(Self.playerURL)
            armLoadTimeout()
        }
    }

    func signOut() {
        guard let host else { return }
        playerState = nil
        playerStateHandler?(nil)
        failPendingCalls("Signed out of Spotify")
        status = .loading
        host.forgetAccount { [weak self] in
            guard let self else { return }
            accountName = ""
            username = ""
            host.load(Self.playerURL)
            armLoadTimeout()
        }
    }

    // MARK: - Calls

    func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        guard let host, status == .signedIn || name == "account" else {
            throw SpotifyError(message: "Spotify isn't signed in")
        }
        let id = nextCallID
        nextCallID += 1
        let argumentText = (try? JSONSerialization.data(withJSONObject: arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let nameText = (try? JSONSerialization.data(withJSONObject: [name])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            pendingCalls[id] = continuation
            host.evaluate("window.firstRowSpotify && window.firstRowSpotify.call(\(id), \(nameText), \(argumentText))")
            Task { @MainActor [weak self] in
                try? await firstRowSleep(60)
                self?.finishCall(id, .failure(SpotifyError(message: "Spotify didn't answer")))
            }
        }
    }

    func playlists() async throws -> [SpotifyCollection] {
        try Self.collections(from: await call("playlists"), kind: .playlist)
    }

    func savedAlbums() async throws -> [SpotifyCollection] {
        try Self.collections(from: await call("library", ["filter": "Albums"]), kind: .album)
    }

    func followedArtists() async throws -> [SpotifyCollection] {
        try Self.collections(from: await call("library", ["filter": "Artists"]), kind: .artist)
    }

    func likedSongs() async throws -> [SpotifyTrack] {
        try Self.tracks(from: await call("likedSongs"))
    }

    func tracks(in collection: SpotifyCollection) async throws -> [SpotifyTrack] {
        switch collection.kind {
        case .playlist: try Self.tracks(from: await call("playlistTracks", ["uri": collection.uri]))
        case .album: try Self.tracks(from: await call("albumTracks", ["uri": collection.uri]))
        case .artist: try Self.tracks(from: await call("artistTracks", ["uri": collection.uri]))
        }
    }

    /// Plays `uris` in this order from `index`, as the context `contextURI` (a playlist or album).
    func play(uris: [String], index: Int, contextURI: String?) async throws {
        var arguments: [String: Any] = ["uris": uris, "index": index]
        if let contextURI { arguments["contextUri"] = contextURI }
        _ = try await call("play", arguments)
    }

    func pause() async throws {
        _ = try await call("pause")
    }

    func resume() async throws {
        _ = try await call("resume")
    }

    func seek(toSeconds seconds: Double) async throws {
        _ = try await call("seek", ["ms": max(0, seconds) * 1000])
    }

    // MARK: - Messages from the page

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["type"] as? String
        else { return }
        if type != "result" {
            spotifyDebugLog("page: \(text.prefix(160))")
        }
        switch type {
        case "ready":
            loadTimeoutTask?.cancel()
            let signedIn = message["signedIn"] as? Bool ?? false
            accountName = message["name"] as? String ?? ""
            username = message["username"] as? String ?? ""
            if signedIn {
                if isSigningIn {
                    isSigningIn = false
                    host?.dismissSignIn()
                }
                status = .signedIn
            } else if !isSigningIn {
                status = .signedOut
            }
            resumeStatusWaiters()
        case "state":
            playerState = Self.playerState(from: message["state"])
            playerStateHandler?(playerState)
        case "result":
            guard let id = message["id"] as? Int else { return }
            if message["ok"] as? Bool == true {
                finishCall(id, .success(message["value"] is NSNull ? nil : message["value"]))
            } else {
                finishCall(id, .failure(SpotifyError(message: message["error"] as? String ?? "Spotify failed")))
            }
        case "failed":
            handleHostFailure(message["error"] as? String ?? "Spotify did not load")
        case "playerError":
            spotifyDebugLog("player error: \(message["error"] ?? "")")
        default:
            break
        }
    }

    private func handleHostFailure(_ reason: String) {
        spotifyDebugLog("unavailable: \(reason)")
        loadTimeoutTask?.cancel()
        guard !isSigningIn else { return }
        failPendingCalls(reason)
        status = .unavailable(reason)
        resumeStatusWaiters()
    }

    private var isUnavailable: Bool {
        if case .unavailable = status { return true }
        return false
    }

    private func armLoadTimeout() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = Task { @MainActor [weak self] in
            try? await firstRowSleep(45)
            guard !Task.isCancelled, let self, self.status == .loading, !self.isSigningIn else { return }
            self.handleHostFailure("Spotify did not load. Check your internet connection.")
        }
    }

    private func finishCall(_ id: Int, _ result: Result<Any?, Error>) {
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failPendingCalls(_ reason: String) {
        let calls = pendingCalls
        pendingCalls.removeAll()
        for continuation in calls.values {
            continuation.resume(throwing: SpotifyError(message: reason))
        }
    }

    private func resumeStatusWaiters() {
        let waiters = statusWaiters
        statusWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - Reading answers

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func url(_ value: Any?) -> URL? {
        (value as? String).flatMap { URL(string: $0) }
    }

    private static func tracks(from value: Any?) throws -> [SpotifyTrack] {
        guard let rows = value as? [[String: Any]] else { throw SpotifyError(message: "Spotify sent no songs") }
        return rows.map { row in
            SpotifyTrack(
                uri: string(row["uri"]),
                name: string(row["name"]),
                artist: string(row["artist"]),
                album: string(row["album"]),
                imageURL: url(row["image"]),
                durationSeconds: number(row["durationMs"]) / 1000,
                trackNumber: Int(number(row["trackNumber"])),
                discNumber: max(1, Int(number(row["discNumber"]))),
                isPlayable: row["playable"] as? Bool ?? true,
            )
        }
    }

    private static func collections(from value: Any?, kind: SpotifyCollection.Kind) throws -> [SpotifyCollection] {
        guard let rows = value as? [[String: Any]] else { throw SpotifyError(message: "Spotify sent nothing") }
        return rows.compactMap { row in
            let uri = string(row["uri"])
            guard !uri.isEmpty else { return nil }
            return SpotifyCollection(kind: kind, uri: uri, name: string(row["name"]), subtitle: string(row["subtitle"]), imageURL: url(row["image"]))
        }
    }

    private static func playerState(from value: Any?) -> SpotifyPlayerState? {
        guard let state = value as? [String: Any] else { return nil }
        // The page's clock and this one can differ: count from when the page sent it.
        let reportedAgo = max(0, number(state["now"]) - number(state["timestamp"])) / 1000
        return SpotifyPlayerState(
            trackURI: string(state["uri"]),
            name: string(state["name"]),
            artist: string(state["artist"]),
            album: string(state["album"]),
            imageURL: url(state["image"]),
            isAdvert: state["advert"] as? Bool ?? false,
            advertiser: string(state["advertiser"]),
            isPaused: state["paused"] as? Bool ?? true,
            isBuffering: state["buffering"] as? Bool ?? false,
            durationSeconds: number(state["durationMs"]) / 1000,
            contextURI: state["contextUri"] as? String,
            positionSeconds: number(state["positionMs"]) / 1000,
            positionDate: Date().addingTimeInterval(-reportedAgo),
        )
    }
}

func spotifyDebugLog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_SPOTIFY"] == "1" {
        FileHandle.standardError.write(Data("[spotify] \(message())\n".utf8))
    }
}
