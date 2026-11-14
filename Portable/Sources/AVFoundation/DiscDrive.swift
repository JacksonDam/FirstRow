import Foundation
#if os(Windows)
    import WinSDK
#endif

// How a DVD is handed to mpv.
//
// On Linux, a disc in a drive is played from the drive itself, as a disc: the system's mpv
// reads it with the system's own DVD libraries, and plays its main title from start to end.
//
// On Windows, First Row carries mpv's own LGPL build, which has nothing in it that reads
// DVDs. So an unprotected DVD's files are read here instead: a DVD's pictures and sound are
// kept as one long MPEG stream cut into files of a gigabyte ("VTS_01_1.VOB", "VTS_01_2.VOB"
// and so on, a set for each title or group of titles), and the largest set, joined end to
// end, is the movie. That is all a disc made at home needs. Nothing here unscrambles
// anything: a disc that is protected against copying isn't played (see DVDMenuFeature.swift).

public extension AVPlayer {
    /// The disc drive an address stands for ("/dev/sr0" on Linux, "D:" on Windows), or nil
    /// if it isn't one: a file, a folder, a drive of another kind.
    static func discDrive(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        #if os(Windows)
            // ("D:\\", or the disc's own folder at its top, "D:\\VIDEO_TS": the top of a drive is an
            // address Foundation can't be trusted with here, so a disc goes by its folder.)
            let path = (url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path)
                .replacingOccurrences(of: "/", with: "\\")
            var rest = Array(path)
            guard rest.count >= 2, rest[0].isLetter, rest[1] == ":" else { return nil }
            let letter = rest[0]
            rest.removeFirst(2)
            while rest.last == "\\" { rest.removeLast() }
            guard rest.isEmpty || String(rest).uppercased() == "\\VIDEO_TS" else { return nil }
            let kind = "\(letter):\\".withCString(encodedAs: UTF16.self) { GetDriveTypeW($0) }
            return kind == UINT(DRIVE_CDROM) ? "\(letter):" : nil
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

    /// What mpv is asked to open for a DVD, and with what options, or nil for anything mpv
    /// opens by its address as it is.
    static func discTarget(for url: URL) -> (target: String, options: [String])? {
        guard url.isFileURL else { return nil }
        #if os(Linux)
            guard let drive = discDrive(for: url) else { return nil }
            // (The value is given with its length, as mpv takes one that may hold any character.)
            return ("dvd://", ["dvd-device=%\(drive.utf8.count)%\(drive)"])
        #elseif os(Windows)
            let parts = movieFiles(ofDVDIn: url)
            guard !parts.isEmpty else { return nil }
            // (FFmpeg's own way of reading files end to end as one, which mpv passes on to it.)
            return ("lavf://concat:" + parts.joined(separator: "|"), [])
        #else
            return nil
        #endif
    }

    /// The files of a DVD's main title, in order, as paths: those of the largest set of title
    /// files in its VIDEO_TS folder. Empty if `folder` isn't a DVD (or the top of one).
    static func movieFiles(ofDVDIn folder: URL) -> [String] {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return [] }
        let places = [folder.appendingPathComponent("VIDEO_TS", isDirectory: true), folder.appendingPathComponent("video_ts", isDirectory: true), folder]
        guard let videoFolder = places.first(where: { place in
            fileManager.fileExists(atPath: place.appendingPathComponent("VIDEO_TS.IFO").path)
                || fileManager.fileExists(atPath: place.appendingPathComponent("video_ts.ifo").path)
        }), let names = try? fileManager.contentsOfDirectory(atPath: videoFolder.path)
        else { return [] }
        // "VTS_03_2.VOB": title set 3, its second file. (File 0 of a set holds its menus.)
        var sets: [Int: [(part: Int, name: String, size: Int)]] = [:]
        for name in names {
            let pieces = name.uppercased().split(separator: ".").first?.split(separator: "_") ?? []
            guard name.uppercased().hasSuffix(".VOB"), pieces.count == 3, pieces[0] == "VTS",
                  let set = Int(pieces[1]), let part = Int(pieces[2]), part >= 1
            else { continue }
            let size = (try? fileManager.attributesOfItem(atPath: videoFolder.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? 0
            sets[set, default: []].append((part, name, size))
        }
        func size(_ set: Int) -> Int { sets[set]?.reduce(0) { $0 + $1.size } ?? 0 }
        guard let largest = sets.keys.sorted().max(by: { size($0) < size($1) }) else { return [] }
        return (sets[largest] ?? []).sorted { $0.part < $1.part }.map { part in
            let file = videoFolder.appendingPathComponent(part.name)
            return file.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? file.path
        }
    }
}
