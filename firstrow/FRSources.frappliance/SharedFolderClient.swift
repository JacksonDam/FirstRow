import Foundation
#if FIRSTROW_PORTABLE
    import AVFoundation
    import CPortable
#endif

/// The folders a computer or a network drive shares (SMB: a Windows PC's, a Mac's File
/// Sharing, most network drives). On the Mac, iPhone, iPad and Apple TV, First Row's own
/// engine reads them, where there is one. On Linux the system's own libsmbclient does, and on
/// Windows the system itself.
struct SharedFolderClient: MediaServerClient {
    /// The computer: its name or address, with ":port" if it's an unusual one.
    let server: String
    let user: String?
    let password: String?

    init?(record: MediaServerRecord) {
        guard let server = Self.server(in: record.address) else { return nil }
        self.server = server
        user = record.user
        password = record.password
    }

    /// Whether shared folders can be read here.
    @MainActor
    static var isAvailable: Bool {
        #if FIRSTROW_PORTABLE
            fr_smb_available() != 0
        #else
            MediaEngine.isMainEngine
        #endif
    }

    /// "nas.local" from "smb://nas.local/", "\\\\nas\\share" or "nas.local".
    static func server(in typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if text.lowercased().hasPrefix("smb://") { text.removeFirst(6) }
        while text.hasPrefix("/") { text.removeFirst() }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        return text.isEmpty ? nil : text
    }

    // MARK: - Asking what is there

    #if FIRSTROW_PORTABLE
        /// What a computer shares, or what a folder of a share holds, as the system's own
        /// means of reading shared folders answer (see `fr_smb.c`).
        private func list(share: String?, path: String) async throws -> [(name: String, isFolder: Bool)] {
            let server = server, user = user ?? "", password = password ?? ""
            let (count, text): (Int32, String) = await Task.detached(priority: .userInitiated) {
                var buffer = [CChar](repeating: 0, count: 1 << 20)
                let count = fr_smb_list(server, share ?? "", path, user, password, &buffer, Int32(buffer.count))
                return (count, count > 0 ? String(cString: buffer) : "")
            }.value
            if count == -2 { throw MediaServerError.signInNeeded }
            if count == -3 { throw MediaServerError.unsupported(L("Shared Folders Can't Be Read Here")) }
            if count == -4 { throw MediaServerError.unsupported(L("Windows Is Signed In There as Someone Else")) }
            if count < 0 { throw MediaServerError.unreachable }
            return text.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[1]), parts[0] != "f")
            }
        }

        private func shares() async throws -> [String] {
            try await list(share: nil, path: "").map(\.name)
        }

        /// What a folder holds, without what the computer lists and then won't open: each
        /// folder, and each file of the `kinds` First Row would open, is opened and closed
        /// again (for four seconds at most: what is left then is listed untried).
        private func contents(share: String, path: String, opening kinds: Set<String>) async throws -> [(name: String, isFolder: Bool)] {
            let listed = try await list(share: share, path: path)
            let server = server, user = user ?? "", password = password ?? ""
            return await Task.detached(priority: .userInitiated) {
                let started = Date()
                return listed.filter { entry in
                    guard entry.isFolder || kinds.contains((entry.name as NSString).pathExtension.lowercased()),
                          Date().timeIntervalSince(started) < 4 else { return true }
                    return fr_smb_reachable(server, share, path.isEmpty ? entry.name : path + "/" + entry.name, entry.isFolder ? 1 : 0, user, password) != 0
                }
            }.value
        }
    #else
        private static func ask(_ question: String, _ details: [String: Any]) async throws -> [String: Any] {
            let answer = await MediaEngine.ask(question, details)
            if let error = answer[MediaEngineKey.error] as? String {
                if (answer[MediaEngineKey.needsSignIn] as? Bool) == true { throw MediaServerError.signInNeeded }
                if (answer[MediaEngineKey.isUnreachable] as? Bool) == true { throw MediaServerError.unreachable }
                throw MediaServerError.unsupported(error.count > 60 ? L("Can't Open the Shared Folder") : error)
            }
            return answer
        }

        private func details(_ more: [String: Any] = [:]) -> [String: Any] {
            var details: [String: Any] = [MediaEngineKey.server: server]
            if let user { details[MediaEngineKey.user] = user }
            if let password { details[MediaEngineKey.password] = password }
            return details.merging(more) { $1 }
        }

        private func shares() async throws -> [String] {
            let answer = try await Self.ask(MediaEngineQuestion.sharedFolders, details())
            return (answer[MediaEngineKey.names] as? [String]) ?? []
        }

        private func contents(share: String, path: String, opening kinds: Set<String>) async throws -> [(name: String, isFolder: Bool)] {
            let answer = try await Self.ask(
                MediaEngineQuestion.sharedFolderContents,
                details([MediaEngineKey.share: share, MediaEngineKey.path: path, MediaEngineKey.opens: Array(kinds)]),
            )
            return ((answer[MediaEngineKey.entries] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let name = entry[MediaEngineKey.name] as? String else { return nil }
                return (name, (entry[MediaEngineKey.isFolder] as? Bool) == true)
            }
        }
    #endif

    // MARK: - The menus' questions

    static func find(at typed: String, user: String?, password: String?) async throws -> FoundMediaServer {
        guard let server = server(in: typed) else { throw MediaServerError.notAServer(.sharedFolder) }
        let client = SharedFolderClient(server: server, user: user, password: password)
        let shares = try await client.top()
        guard !shares.isEmpty else { throw MediaServerError.notAServer(.sharedFolder) }
        let host = server.split(separator: ":").first.map(String.init) ?? server
        return FoundMediaServer(kind: .sharedFolder, name: host.hasSuffix(".local") ? String(host.dropLast(6)) : host, address: "smb://" + server)
    }

    private init(server: String, user: String?, password: String?) {
        self.server = server
        self.user = user
        self.password = password
    }

    func top() async throws -> [ServerItem] {
        try await shares().map { share in
            ServerItem(id: "smb:\(share)", kind: .folder, title: share, details: ["share": share, "path": ""])
        }
    }

    func children(of item: ServerItem) async throws -> [ServerItem] {
        guard let share = item.details["share"] else { return [] }
        let path = item.details["path"] ?? ""
        let movieKinds = await MainActor.run { MenuView.furtherMovieFileExtensions.union(["mov", "mp4", "m4v", "mkv", "avi", "mpg", "mpeg", "ts", "m2ts", "wmv", "webm"]) }
        // (Only what can be reached: the folders and movies the computer lists and then
        // won't open are left out.)
        let entries = try await contents(share: share, path: path, opening: movieKinds)
        let names = entries.map(\.name)
        var folders: [ServerItem] = []
        var movies: [ServerItem] = []
        for entry in entries {
            let name = entry.name
            let place = path.isEmpty ? name : path + "/" + name
            if entry.isFolder {
                folders.append(ServerItem(id: "smb:\(share)/\(place)", kind: .folder, title: name, details: ["share": share, "path": place]))
                continue
            }
            let kind = (name as NSString).pathExtension.lowercased()
            guard movieKinds.contains(kind) else { continue }
            var movie = ServerItem(id: "smb:\(share)/\(place)", kind: .video, title: name, details: ["share": share, "path": place])
            // The subtitle files beside it, by name ("Film.srt", "Film.en.srt").
            let base = (name as NSString).deletingPathExtension.lowercased()
            let beside = names.filter { other in
                let otherBase = (other as NSString).deletingPathExtension.lowercased()
                return MenuView.subtitleFileExtensions.contains((other as NSString).pathExtension.lowercased()) && (otherBase == base || otherBase.hasPrefix(base + "."))
            }
            if !beside.isEmpty { movie.details["subtitles"] = beside.joined(separator: "\n") }
            movies.append(movie)
        }
        let byName: (ServerItem, ServerItem) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return movies.sorted(by: byName) + folders.sorted(by: byName)
    }

    /// A file's address: "smb://server/share/folder/file".
    private func address(share: String, path: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%;")
        let parts = ([share] + path.split(separator: "/").map(String.init)).compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        return URL(string: "smb://" + server + "/" + parts.joined(separator: "/"))
    }

    func video(for item: ServerItem) async throws -> ServerVideo {
        guard let share = item.details["share"], let path = item.details["path"], let url = address(share: share, path: path) else {
            throw MediaServerError.nothingPlayable
        }
        var video = ServerVideo(url: url, user: user, password: password)
        let folder = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        for name in (item.details["subtitles"] ?? "").split(separator: "\n").map(String.init) {
            guard let file = address(share: share, path: folder.isEmpty ? name : folder + "/" + name) else { continue }
            let words = (name as NSString).deletingPathExtension.lowercased().dropFirst(base.count).split(separator: ".").map(String.init)
            let language = words.first { ($0.count == 2 || $0.count == 3) && $0.allSatisfy(\.isLetter) }
            video.subtitleFiles.append(MovieSubtitleFile(url: file, language: language, name: language == nil ? (name as NSString).pathExtension.uppercased() : nil))
        }
        #if FIRSTROW_PORTABLE
            // (The player there has only the movie's address to go by, so what goes with it
            // is left for it under that address.)
            AVPlayer.noteSharedFolderSignIn(server: server, user: user, password: password)
            AVPlayer.noteSharedFolderSubtitles(video.subtitleFiles.map(\.url), for: url)
        #endif
        return video
    }
}
