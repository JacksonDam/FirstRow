import Foundation

/// The folders a computer or a network drive shares (SMB: a Windows PC's, a Mac's File
/// Sharing, most network drives). On the Mac, iPhone, iPad and Apple TV, First Row's own
/// engine reads them, where there is one.
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
            false
        #else
            MediaEngine.isAvailable
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

    #if FIRSTROW_PORTABLE
        static func find(at _: String, user _: String?, password _: String?) async throws -> FoundMediaServer {
            throw MediaServerError.notAServer(.sharedFolder)
        }

        func top() async throws -> [ServerItem] { [] }
        func children(of _: ServerItem) async throws -> [ServerItem] { [] }
        func video(for _: ServerItem) async throws -> ServerVideo { throw MediaServerError.nothingPlayable }
    #else
        private static func ask(_ question: String, _ details: [String: Any]) async throws -> [String: Any] {
            let answer = await MediaEngine.ask(question, details)
            if let error = answer[MediaEngineKey.error] as? String {
                if (answer[MediaEngineKey.needsSignIn] as? Bool) == true { throw MediaServerError.signInNeeded }
                throw MediaServerError.unsupported(error.count > 60 ? "Can't Open the Shared Folder" : error)
            }
            return answer
        }

        private func details(_ more: [String: Any] = [:]) -> [String: Any] {
            var details: [String: Any] = [MediaEngineKey.server: server]
            if let user { details[MediaEngineKey.user] = user }
            if let password { details[MediaEngineKey.password] = password }
            return details.merging(more) { $1 }
        }

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
            let answer = try await Self.ask(MediaEngineQuestion.sharedFolders, details())
            return ((answer[MediaEngineKey.names] as? [String]) ?? []).map { share in
                ServerItem(id: "smb:\(share)", kind: .folder, title: share, details: ["share": share, "path": ""])
            }
        }

        func children(of item: ServerItem) async throws -> [ServerItem] {
            guard let share = item.details["share"] else { return [] }
            let path = item.details["path"] ?? ""
            let answer = try await Self.ask(MediaEngineQuestion.sharedFolderContents, details([MediaEngineKey.share: share, MediaEngineKey.path: path]))
            let entries = (answer[MediaEngineKey.entries] as? [[String: Any]]) ?? []
            let names = entries.compactMap { $0[MediaEngineKey.name] as? String }
            let movieKinds = await MainActor.run { MenuView.furtherMovieFileExtensions.union(["mov", "mp4", "m4v", "mkv", "avi", "mpg", "mpeg", "ts", "m2ts", "wmv", "webm"]) }
            var folders: [ServerItem] = []
            var movies: [ServerItem] = []
            for entry in entries {
                guard let name = entry[MediaEngineKey.name] as? String else { continue }
                let place = path.isEmpty ? name : path + "/" + name
                if (entry[MediaEngineKey.isFolder] as? Bool) == true {
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
            return video
        }
    #endif
}
