import Foundation
#if os(Windows)
    import WinSDK
#endif
#if canImport(QuickLookThumbnailing)
    import QuickLookThumbnailing
#endif

// Dropbox, Google Drive, OneDrive and the like each keep a folder on a computer that has
// their app, and what is in it can be played like anything else on the computer: First Row
// signs in to nothing and talks to no service itself. This finds those folders, so that
// Settings > Media Folders can offer them by name, and tells a file whose contents are still
// with its service from one that is on the disk, so that looking through a folder doesn't
// fetch everything in it.

enum CloudFolders {
    struct Folder: Equatable, Sendable {
        /// The service's name, with whose it is where there are several ("Dropbox (Work)").
        var name: String
        var url: URL
    }

    /// The folders on this computer, in name order. This looks at the disk, so it isn't for
    /// the main thread.
    static func found() -> [Folder] {
        guard !FirstRowHarness.isActive else { return [] }
        return named(candidates())
    }

    private struct Candidate {
        var service: String
        /// What tells it from another folder of the same service: an account, "Work".
        var detail: String
        var url: URL
    }

    private static func named(_ candidates: [Candidate]) -> [Folder] {
        var seen = Set<String>()
        let distinct = candidates.filter { seen.insert($0.url.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        let folders = distinct.map { candidate -> Folder in
            let shared = distinct.filter { $0.service == candidate.service }.count > 1
            let name = shared && !candidate.detail.isEmpty ? "\(candidate.service) (\(candidate.detail))" : candidate.service
            return Folder(name: name, url: candidate.url)
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The home folder as the Finder shows it, which isn't the app's own when it is sandboxed.
    private static var home: URL {
        #if os(macOS)
            if let entry = getpwuid(getuid()), let folder = entry.pointee.pw_dir {
                return URL(fileURLWithPath: String(cString: folder), isDirectory: true)
            }
        #endif
        #if os(macOS) || FIRSTROW_PORTABLE
            return FileManager.default.homeDirectoryForCurrentUser
        #else
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    /// What a service's folder is called where the system keeps them ("GoogleDrive-name@gmail.com").
    static func service(ofFolderNamed name: String) -> (service: String, detail: String) {
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        let key = parts.first ?? name
        let known = [
            "GoogleDrive": "Google Drive",
            "ProtonDrive": "Proton Drive",
            "SynologyDrive": "Synology Drive",
            "pCloudDrive": "pCloud",
        ]
        let service = known[key] ?? key
        let detail = parts.count > 1 && parts[1] != key ? parts[1] : ""
        return (service, detail)
    }

    private static func candidates() -> [Candidate] {
        var found: [Candidate] = []
        let home = home
        #if os(macOS)
            // Where the system keeps the folders of the services that plug in to the Finder.
            let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []).sorted() where !name.hasPrefix(".") {
                let url = storage.appendingPathComponent(name, isDirectory: true)
                guard isFolder(url) else { continue }
                let (service, detail) = service(ofFolderNamed: name)
                found.append(Candidate(service: service, detail: detail, url: url))
            }
            let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            if isFolder(iCloud) {
                found.append(Candidate(service: "iCloud Drive", detail: "", url: iCloud))
            }
        #elseif os(Windows)
            let environment = ProcessInfo.processInfo.environment
            for base in [environment["LOCALAPPDATA"], environment["APPDATA"]].compactMap({ $0 }) {
                found += dropboxFolders(listedIn: URL(fileURLWithPath: base).appendingPathComponent("Dropbox").appendingPathComponent("info.json"))
            }
            // Google Drive is a drive of its own, unless it's set to keep a copy in the home folder.
            for letter in "DEFGHIJKLMNOPQRSTUVWXYZ" {
                let root = "\(letter):\\"
                let kind = root.withCString(encodedAs: UTF16.self) { GetDriveTypeW($0) }
                guard kind == UINT(DRIVE_FIXED) || kind == UINT(DRIVE_REMOTE) else { continue }
                if isFolder(URL(fileURLWithPath: root + "My Drive")) {
                    found.append(Candidate(service: "Google Drive", detail: "\(letter):", url: URL(fileURLWithPath: root)))
                }
            }
            let mirrored = home.appendingPathComponent("My Drive", isDirectory: true)
            if isFolder(mirrored) {
                found.append(Candidate(service: "Google Drive", detail: "", url: mirrored))
            }
            if let personal = environment["OneDriveConsumer"] ?? environment["OneDrive"], isFolder(URL(fileURLWithPath: personal)) {
                found.append(Candidate(service: "OneDrive", detail: "", url: URL(fileURLWithPath: personal)))
            }
            if let work = environment["OneDriveCommercial"], isFolder(URL(fileURLWithPath: work)) {
                found.append(Candidate(service: "OneDrive", detail: L("Work"), url: URL(fileURLWithPath: work)))
            }
            let iCloud = home.appendingPathComponent("iCloudDrive", isDirectory: true)
            if isFolder(iCloud) {
                found.append(Candidate(service: "iCloud Drive", detail: "", url: iCloud))
            }
        #elseif os(Linux)
            found += dropboxFolders(listedIn: home.appendingPathComponent(".dropbox/info.json"))
        #endif
        #if os(macOS) || os(Windows) || os(Linux)
            // And where they were kept before, or are kept by other apps for the same services.
            for (name, service) in [
                ("Dropbox", "Dropbox"), ("Google Drive", "Google Drive"), ("GoogleDrive", "Google Drive"),
                ("OneDrive", "OneDrive"), ("Box", "Box"), ("Nextcloud", "Nextcloud"), ("pCloudDrive", "pCloud"),
            ] where !found.contains(where: { $0.service == service }) {
                let url = home.appendingPathComponent(name, isDirectory: true)
                if isFolder(url) {
                    found.append(Candidate(service: service, detail: "", url: url))
                }
            }
        #endif
        return found
    }

    #if os(Windows) || os(Linux)
        /// Dropbox writes down where its folders are: one for each of a person's two accounts.
        private static func dropboxFolders(listedIn file: URL) -> [Candidate] {
            guard let data = try? Data(contentsOf: file),
                  let accounts = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            return accounts.keys.sorted().compactMap { account in
                guard let path = (accounts[account] as? [String: Any])?["path"] as? String,
                      isFolder(URL(fileURLWithPath: path))
                else { return nil }
                return Candidate(service: "Dropbox", detail: account == "business" ? L("Work") : L("Personal"), url: URL(fileURLWithPath: path, isDirectory: true))
            }
        }
    #endif

    /// What to call a folder in the menus: a service's own folder goes by the service's name
    /// ("Google Drive" for "GoogleDrive-name@gmail.com"), any other by its own.
    static func title(ofFolder url: URL) -> String {
        let folder = url.standardizedFileURL
        #if os(macOS)
            let parent = folder.deletingLastPathComponent()
            if parent.lastPathComponent == "CloudStorage", parent.deletingLastPathComponent().lastPathComponent == "Library" {
                return service(ofFolderNamed: folder.lastPathComponent).service
            }
            if folder.lastPathComponent == "com~apple~CloudDocs" {
                return "iCloud Drive"
            }
        #endif
        return FileManager.default.displayName(atPath: folder.path)
    }

    // MARK: - Files still with their service

    /// True for a file whose contents haven't been fetched: it has its name, its size and its
    /// place, and opening it fetches the rest, which for a movie can take a while.
    static func isStillInTheCloud(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        #if canImport(Darwin)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            return info.st_flags & UInt32(SF_DATALESS) != 0
        #elseif os(Windows)
            let path = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
            let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
            guard attributes != DWORD.max else { return false }
            let fetchedWhenRead = DWORD(FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS) | DWORD(FILE_ATTRIBUTE_RECALL_ON_OPEN) | DWORD(FILE_ATTRIBUTE_OFFLINE)
            return attributes & fetchedWhenRead != 0
        #else
            return false
        #endif
    }

    #if canImport(QuickLookThumbnailing)
        /// The picture its service has of a file that is still with it, if it has one. This
        /// asks the system, which asks the service: the file itself isn't fetched.
        static func picture(of url: URL, longestSide: CGFloat) async -> CGImage? {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: longestSide, height: longestSide),
                scale: 1,
                representationTypes: .thumbnail,
            )
            return await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { picture, _ in
                    continuation.resume(returning: picture?.cgImage)
                }
            }
        }
    #endif
}
