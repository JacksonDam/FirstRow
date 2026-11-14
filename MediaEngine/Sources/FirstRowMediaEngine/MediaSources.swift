import AetherEngine
import AetherEngineSMB
import Foundation

/// Turns what First Row asks to be opened into what the engine reads from.
enum MediaSources {
    struct NotFound: LocalizedError {
        let errorDescription: String?
    }

    static func source(for url: URL, user: String?, password: String?) async throws -> MediaSource {
        if url.scheme?.lowercased() == "smb" {
            return try await sharedFile(url, user: user, password: password)
        }
        if url.isFileURL {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                throw NotFound(errorDescription: "The file can't be found.")
            }
            if isFolder.boolValue {
                guard let disc = DiscFolderReader(folder: url) else {
                    throw NotFound(errorDescription: "The folder holds nothing to play.")
                }
                return .custom(disc)
            }
        }
        return .url(url)
    }

    /// A file on a shared folder: `smb://host/share/path`, signed in to as `user` (as a guest
    /// with none).
    private static func sharedFile(_ url: URL, user: String?, password: String?) async throws -> MediaSource {
        let parts = try SMBURL.parse(url.absoluteString)
        let connection = try await SMBConnection.connect(
            server: parts.server,
            share: parts.share,
            path: parts.path.removingPercentEncoding ?? parts.path,
            user: user ?? parts.user,
            password: password ?? parts.password,
        )
        let name = url.lastPathComponent.lowercased()
        let isDiscPicture = name.hasSuffix(".iso") || name.hasSuffix(".img")
        return .custom(SMBIOReader(source: connection, discImageProbeEnabled: isDiscPicture))
    }
}

/// A file on this device, read a piece at a time.
final class LocalFileReader: IOReader, @unchecked Sendable {
    private let path: String
    private let descriptor: Int32
    private let size: Int64
    private var offset: Int64 = 0
    private var isClosed = false
    private let lock = NSLock()

    init?(path: String) {
        let descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.path = path
        self.descriptor = descriptor
        size = Int64(info.st_size)
    }

    deinit {
        if !isClosed { Darwin.close(descriptor) }
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size count: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let buffer, count > 0 else { return -1 }
        let got = pread(descriptor, buffer, Int(count), offset)
        guard got >= 0 else { return -1 }
        offset += Int64(got)
        return Int32(got)
    }

    func seek(offset target: Int64, whence: Int32) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        switch whence {
        case 65536: return size
        case SEEK_SET: offset = target
        case SEEK_CUR: offset += target
        case SEEK_END: offset = size + target
        default: return -1
        }
        offset = max(0, offset)
        return offset
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    func makeIndependentReader() -> IOReader? { LocalFileReader(path: path) }

    var discImageProbeEnabled: Bool { false }
}

/// A disc kept as a folder of its files: a DVD's VIDEO_TS or a Blu-ray's BDMV, or the folder
/// that holds one of those.
final class DiscFolderReader: DiscDirectoryReader, @unchecked Sendable {
    private let root: URL
    private let files: [(path: String, size: Int64)]

    /// Whether a folder is a disc's, or holds one.
    static func isDisc(_ folder: URL) -> Bool {
        discRoot(of: folder) != nil
    }

    /// The folder that VIDEO_TS or BDMV is in.
    private static func discRoot(of folder: URL) -> URL? {
        let name = folder.lastPathComponent.uppercased()
        if name == "VIDEO_TS" || name == "BDMV" { return folder.deletingLastPathComponent() }
        let inside = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return inside.contains { ["VIDEO_TS", "BDMV"].contains($0.uppercased()) } ? folder : nil
    }

    init?(folder: URL) {
        guard let root = Self.discRoot(of: folder) else { return nil }
        self.root = root
        var found: [(path: String, size: Int64)] = []
        let top = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in top where ["VIDEO_TS", "BDMV"].contains(name.uppercased()) {
            let base = root.appendingPathComponent(name, isDirectory: true)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let file as URL in walk {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                found.append((relative, Int64(values.fileSize ?? 0)))
            }
        }
        guard !found.isEmpty else { return nil }
        files = found
    }

    private init(root: URL, files: [(path: String, size: Int64)]) {
        self.root = root
        self.files = files
    }

    var discFiles: [(path: String, size: Int64)] { files }

    func openDiscFile(_ path: String) -> IOReader? {
        guard let file = files.first(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) else { return nil }
        return LocalFileReader(path: root.appendingPathComponent(file.path).path)
    }

    var preferredPlaylist: String? { nil }

    func read(_: UnsafeMutablePointer<UInt8>?, size _: Int32) -> Int32 { -1 }
    func seek(offset _: Int64, whence _: Int32) -> Int64 { -1 }
    func close() {}

    func makeIndependentReader() -> IOReader? { DiscFolderReader(root: root, files: files) }
}
