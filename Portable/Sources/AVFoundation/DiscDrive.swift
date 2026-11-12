import Foundation
#if os(Windows)
    import WinSDK
#endif

// A DVD in a drive is played from the drive itself, as a disc, rather than as the files on
// it: mpv then plays its main title from start to end, and where the disc is protected
// against copying the drive is asked for it in the way such discs need (which works only
// where the libraries mpv uses for that are installed).

public extension AVPlayer {
    /// The disc drive an address stands for, as mpv is told of one ("/dev/sr0" on Linux, "D:"
    /// on Windows), or nil if it isn't a drive: a file, a folder, a drive of another kind.
    static func discDrive(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        #if os(Windows)
            let path = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
            // ("D:\", "D:/" or "D:": the top of a drive, not a folder on it.)
            let letters = Array(path)
            guard letters.count == 2 || letters.count == 3, letters[0].isLetter, letters[1] == ":",
                  letters.count == 2 || letters[2] == "\\" || letters[2] == "/"
            else { return nil }
            let root = "\(letters[0]):\\"
            let kind = root.withCString(encodedAs: UTF16.self) { GetDriveTypeW($0) }
            return kind == UINT(DRIVE_CDROM) ? "\(letters[0]):" : nil
        #elseif os(Linux)
            let path = url.path
            guard path.hasPrefix("/dev/") else { return nil }
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFBLK else { return nil }
            return path
        #else
            return nil
        #endif
    }
}
