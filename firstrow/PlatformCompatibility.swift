import Foundation

#if os(iOS) || os(tvOS)
    let firstRowRegularFontName = "Helvetica Neue"
    let firstRowBoldFontName = "Helvetica Neue Bold"
#else
    let firstRowRegularFontName = "Lucida Grande"
    let firstRowBoldFontName = "Lucida Grande Bold"
#endif

/// A file shipped with the app, like `Bundle.main.url(forResource:withExtension:)`.
func bundledResourceURL(_ name: String, _ fileExtension: String?) -> URL? {
    #if FIRSTROW_PORTABLE
        AppResources.url(forResource: name, withExtension: fileExtension)
    #else
        Bundle.main.url(forResource: name, withExtension: fileExtension)
    #endif
}

/// The folder holding the app's bundled resources.
var bundledResourceFolderURL: URL? {
    #if FIRSTROW_PORTABLE
        AppResources.resourceURL
    #else
        Bundle.main.resourceURL
    #endif
}

#if FIRSTROW_PORTABLE
    /// The computer's name, as Settings and Sources show it.
    var portableDeviceName: String {
        let environment = ProcessInfo.processInfo.environment
        if let name = environment["COMPUTERNAME"], !name.isEmpty { return name }
        let host = ProcessInfo.processInfo.hostName
        return host.split(separator: ".").first.map(String.init) ?? host
    }
#endif

#if FIRSTROW_PORTABLE
    /// What the computer's own media folders are called in lists of sources.
    var portableComputerTitle: String {
        #if os(Windows)
            "My PC"
        #else
            "My Computer"
        #endif
    }

    /// A media folder in the home folder: the Mac's name if it exists, else the system's own
    /// (Videos, Music, Pictures), as XDG user dirs or Windows name it.
    func portableUserFolder(named macName: String, standardName: String, xdgKey: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let macStyle = home.appendingPathComponent(macName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: macStyle.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return macStyle
        }
        #if !os(Windows)
            // ~/.config/user-dirs.dirs has lines like XDG_VIDEOS_DIR="$HOME/Videos".
            let config = home.appendingPathComponent(".config/user-dirs.dirs")
            if let text = try? String(contentsOf: config, encoding: .utf8) {
                for line in text.split(separator: "\n") where line.hasPrefix(xdgKey + "=") {
                    let value = line.dropFirst(xdgKey.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let path = value.replacingOccurrences(of: "$HOME", with: home.path)
                    if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
                }
            }
        #endif
        return home.appendingPathComponent(standardName, isDirectory: true)
    }

    /// Removable and other drives with media on them: /media and /run/media on Linux, the
    /// other drive letters on Windows.
    func portableExternalVolumeURLs() -> [URL] {
        let fileManager = FileManager.default
        var volumes: [URL] = []
        #if os(Windows)
            for letter in "DEFGHIJKLMNOPQRSTUVWXYZ" {
                let root = URL(fileURLWithPath: "\(letter):\\", isDirectory: true)
                if fileManager.fileExists(atPath: root.path) { volumes.append(root) }
            }
        #else
            let user = ProcessInfo.processInfo.environment["USER"] ?? ""
            for base in ["/media/\(user)", "/run/media/\(user)", "/media", "/mnt"] {
                guard let names = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
                for name in names where !name.hasPrefix(".") && name != user {
                    let url = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(name, isDirectory: true)
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue, !volumes.contains(url) {
                        volumes.append(url)
                    }
                }
            }
        #endif
        return volumes
    }
#endif

func firstRowSleep(_ seconds: Double) async throws {
    if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
        try await Task.sleep(for: .seconds(seconds))
    } else {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

#if FIRSTROW_PORTABLE
    import FirstRowPortable
#endif

#if os(iOS) || os(tvOS)
    import UIKit

    typealias NSImage = UIImage
    typealias NSSize = CGSize
    typealias NSFont = UIFont
    extension NSImage {
        convenience init?(contentsOf url: URL) {
            self.init(contentsOfFile: url.path)
        }

        convenience init?(cgImage: CGImage, size _: NSSize) {
            self.init(cgImage: cgImage)
        }
    }
#endif
