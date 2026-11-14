import Foundation

/// What First Row keeps about YouTube between launches: the videos watched here, the
/// picture size last asked for and the size videos start at, in a file only this user can read.
@MainActor
final class YouTubeStore {
    static let shared = YouTubeStore()
    static let historyLimit = 60

    private(set) var history: [YouTubeVideo] = []
    /// The tallest picture to play, in lines; nil for whatever suits the screen.
    private(set) var maximumHeight: Int?
    /// The size a video starts at when none is asked for, in lines, as learned from how videos
    /// have played here; nil until one has had to come down from the largest that suits the screen.
    private(set) var startingHeight: Int?

    private struct Contents: Codable {
        var history: [YouTubeVideo]
        var maximumHeight: Int?
        var startingHeight: Int?
    }

    private init() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data)
        else { return }
        history = contents.history
        maximumHeight = contents.maximumHeight
        startingHeight = contents.startingHeight
        // (A test version kept a sign-in in this file. First Row has no use for one: the
        // file is written again without it.)
        if let whole = try? JSONSerialization.jsonObject(with: data) as? [String: Any], whole["account"] != nil { write() }
    }

    static var fileURL: URL? {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if FirstRowHarness.isActive, let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            base = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return base?.appendingPathComponent("First Row", isDirectory: true).appendingPathComponent("YouTube.json")
    }

    func setMaximumHeight(_ height: Int?) {
        maximumHeight = height
        write()
    }

    func setStartingHeight(_ height: Int?) {
        guard height != startingHeight else { return }
        startingHeight = height
        write()
    }

    /// Puts a video at the top of the history.
    func noteWatched(_ video: YouTubeVideo) {
        history.removeAll { $0.id == video.id }
        history.insert(video, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        write()
    }

    func clearHistory() {
        history = []
        write()
    }

    private func write() {
        guard let url = Self.fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Contents(history: history, maximumHeight: maximumHeight, startingHeight: startingHeight)) else { return }
        // Written with no permissions for anyone else from the start: what was watched is
        // nobody else's to read.
        if FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
