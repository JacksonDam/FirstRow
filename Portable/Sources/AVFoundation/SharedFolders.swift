import CMPV
import CPortable
import Foundation

// How a movie in a shared folder ("smb://server/share/folder/file") is handed to mpv.
//
// On Windows the system itself reaches shared folders, so once it has been signed in to the
// share the movie is a file like any other, by the name the system knows it by
// ("\\\\server\\share\\folder\\file"). On Linux, First Row reads the file for mpv with the
// system's libsmbclient (see `fr_smb.c`): the movie is given to mpv at an address of First
// Row's own ("frsmb://server/share/folder/file"), which each mpv is taught to ask for here.

public extension AVPlayer {
    private struct SharedFolderNotes {
        /// Who to sign in as on each computer, by its name as it is in a movie's address.
        var signIns: [String: (user: String, password: String)] = [:]
        /// The subtitle files kept beside each movie, by the movie's address.
        var subtitles: [String: [URL]] = [:]
    }

    nonisolated(unsafe) private static var sharedFolderNotes = SharedFolderNotes()
    private static let sharedFolderLock = NSLock()

    /// Says who to sign in as on a computer whose shared folders are about to be played from.
    static func noteSharedFolderSignIn(server: String, user: String?, password: String?) {
        sharedFolderLock.lock()
        sharedFolderNotes.signIns[server.lowercased()] = (user ?? "", password ?? "")
        sharedFolderLock.unlock()
    }

    /// Says which subtitle files are kept beside a movie in a shared folder.
    static func noteSharedFolderSubtitles(_ files: [URL], for movie: URL) {
        sharedFolderLock.lock()
        sharedFolderNotes.subtitles[movie.absoluteString] = files
        sharedFolderLock.unlock()
    }

    internal static func sharedFolderSignIn(for server: String) -> (user: String, password: String) {
        sharedFolderLock.lock()
        defer { sharedFolderLock.unlock() }
        return sharedFolderNotes.signIns[server.lowercased()] ?? ("", "")
    }

    /// A movie in a shared folder as its three parts: the computer, the share, the file's
    /// place in it. Nil for an address that isn't one.
    internal static func sharedFolderParts(of url: URL) -> (server: String, share: String, path: String)? {
        guard url.scheme?.lowercased() == "smb", let host = url.host, !host.isEmpty else { return nil }
        let server = url.port.map { "\(host):\($0)" } ?? host
        let names = url.path.split(separator: "/").map(String.init)
        guard names.count >= 2 else { return nil }
        return (server, names[0], names.dropFirst().joined(separator: "/"))
    }

    /// What mpv is asked to open for a movie in a shared folder, and with what options, or
    /// nil for any other address.
    internal static func sharedFolderTarget(for url: URL) -> (target: String, options: [String])? {
        guard let parts = sharedFolderParts(of: url) else { return nil }
        #if os(Windows)
            let who = sharedFolderSignIn(for: parts.server)
            _ = fr_smb_connect(parts.server, parts.share, who.user, who.password)
            let host = parts.server.split(separator: ":").first.map(String.init) ?? parts.server
            // (mpv finds the subtitle files beside it itself, as it does for any file.)
            return ("\\\\" + host + "\\" + parts.share + "\\" + parts.path.replacingOccurrences(of: "/", with: "\\"), [])
        #else
            func ownAddress(_ address: URL) -> String { "frsmb://" + String(address.absoluteString.dropFirst("smb://".count)) }
            sharedFolderLock.lock()
            let subtitles = sharedFolderNotes.subtitles[url.absoluteString] ?? []
            sharedFolderLock.unlock()
            // (Each value is given with its length, as mpv takes one that may hold any character.)
            let options = subtitles.map(ownAddress).map { "sub-files-append=%\($0.utf8.count)%\($0)" }
            return (ownAddress(url), options)
        #endif
    }
}

#if !os(Windows)
    /// Teaches an mpv to ask First Row for movies in shared folders.
    func registerSharedFolderReading(on handle: OpaquePointer) {
        mpv_stream_cb_add_ro(handle, "frsmb", nil) { _, address, info in
            guard let address, let info,
                  let url = URL(string: "smb://" + String(String(cString: address).dropFirst("frsmb://".count))),
                  let parts = AVPlayer.sharedFolderParts(of: url)
            else { return Int32(MPV_ERROR_LOADING_FAILED.rawValue) }
            let who = AVPlayer.sharedFolderSignIn(for: parts.server)
            guard let file = fr_smb_open(parts.server, parts.share, parts.path, who.user, who.password) else {
                return Int32(MPV_ERROR_LOADING_FAILED.rawValue)
            }
            info.pointee.cookie = file
            info.pointee.read_fn = { file, buffer, count in fr_smb_read(file, buffer, count) }
            info.pointee.seek_fn = { file, offset in fr_smb_seek(file, offset) }
            info.pointee.size_fn = { file in fr_smb_size(file) }
            info.pointee.close_fn = { file in fr_smb_close(file) }
            return 0
        }
    }
#endif
