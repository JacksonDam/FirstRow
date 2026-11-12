import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import AVFoundation
    import CPortable
    import FirstRowPortable
#endif
#if os(Windows)
    import WinSDK
#endif

/// DVD: an item that heads the main menu while there is a DVD to play, a disc in a drive or a
/// picture of one opened as a disc, and plays it.
struct DVDMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "dvd", title: "DVD", iconAssetName: "dvd", leadsToMenu: false, actionID: nil)
    let submenuItems: [SubmenuItemConfig] = []
}

/// Watches for a DVD among the discs and drives that are connected.
@MainActor
final class DiscWatch {
    static let shared = DiscWatch()

    /// The disc there is to play: the folder that holds its VIDEO_TS (on Windows, that
    /// folder itself), or on Linux the drive itself ("/dev/sr0") when the system hasn't
    /// opened the disc in it.
    private(set) var disc: URL?
    /// Called when a disc has come or gone.
    var onChange: (() -> Void)?
    /// The disc that was last asked for, if it is protected against copying: said if it
    /// can't be played.
    var protectedDisc: URL?
    private var discName: String?
    private var isWatching = false
    private var isLooking = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Begins watching (once): told by the system as discs come and go on the Mac, by looking
    /// every few seconds elsewhere.
    func start() {
        guard !isWatching else { return }
        isWatching = true
        #if os(macOS)
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolatedIfPossible { self?.look() }
                })
            }
        #elseif FIRSTROW_PORTABLE
            let timer = Timer(after: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible { self?.look() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        #endif
        look()
    }

    /// Looks for a disc now, off the main thread, and says if what it finds has changed.
    func look() {
        guard !isLooking else { return }
        isLooking = true
        DispatchQueue.global(qos: .utility).async {
            let found = Self.findDisc()
            let name = found.flatMap { Self.name(ofDiscInDrive: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolatedIfPossible {
                    self.isLooking = false
                    // (A drive is the same address whatever disc is in it, so where a movie
                    // was stopped is kept under the disc's own name as well.)
                    MovieResumeStore.discInDrive = found.flatMap { disc in name.map { (disc.standardizedFileURL.path, $0) } }
                    guard found?.standardizedFileURL != self.disc?.standardizedFileURL || name != self.discName else { return }
                    self.disc = found
                    self.discName = name
                    self.onChange?()
                }
            }
        }
    }

    /// The first connected disc that holds a DVD's files.
    private nonisolated static func findDisc() -> URL? {
        // (A test looks at nothing that is connected.)
        guard !FirstRowHarness.isActive else { return nil }
        return candidateVolumes().first(where: holdsDVD).map(playable)
    }

    /// What a disc that has been found goes by. On Windows that is its folder of pictures,
    /// not the drive's own top ("D:\\"), which Foundation there doesn't keep whole.
    private nonisolated static func playable(_ volume: URL) -> URL {
        #if os(Windows)
            for name in ["VIDEO_TS", "video_ts"] {
                let folder = volume.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: folder.path) { return folder }
            }
        #endif
        return volume
    }

    private nonisolated static func holdsDVD(_ volume: URL) -> Bool {
        #if os(Linux)
            if volume.path.hasPrefix("/dev/") {
                return DriveDisc.look(at: volume.path).holdsMovie
            }
        #endif
        let fileManager = FileManager.default
        for name in ["VIDEO_TS", "video_ts"] {
            let folder = volume.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: folder.appendingPathComponent("VIDEO_TS.IFO").path)
                || fileManager.fileExists(atPath: folder.appendingPathComponent("video_ts.ifo").path)
            {
                return true
            }
        }
        return false
    }

    /// The volumes that could be discs: on the Mac, those in a disc's own format (so that no
    /// other drive's files are looked at for this), elsewhere every drive that is connected,
    /// the disc drives first. On Linux a disc is looked for in three places: opened by the
    /// system in a disc's own format, wherever that is; among the drives that are connected;
    /// and in a disc drive whose disc the system hasn't opened, which is read as it is.
    private nonisolated static func candidateVolumes() -> [URL] {
        #if os(macOS)
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            return volumes.filter { url in
                let path = url.standardizedFileURL.path
                guard path.hasPrefix("/Volumes/") else { return false }
                var info = statfs()
                guard statfs(path, &info) == 0 else { return false }
                let kind = withUnsafeBytes(of: &info.f_fstypename) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                return kind == "udf" || kind == "cd9660"
            }
        #elseif os(Linux)
            let opened = (try? String(contentsOfFile: "/proc/mounts", encoding: .utf8)) ?? ""
            var discs: [URL] = []
            var openedDrives = Set<String>()
            for line in opened.split(separator: "\n") {
                let fields = line.split(separator: " ").map(String.init)
                guard fields.count >= 3 else { continue }
                openedDrives.insert(fields[0])
                if fields[2] == "udf" || fields[2] == "iso9660" {
                    discs.append(URL(fileURLWithPath: unescaped(fields[1]), isDirectory: true))
                }
            }
            discs += portableExternalVolumeURLs().filter { !discs.contains($0) }
            let drives = ((try? FileManager.default.contentsOfDirectory(atPath: "/sys/block")) ?? []).filter { $0.hasPrefix("sr") }.sorted()
            for drive in drives where !openedDrives.contains("/dev/\(drive)") && mayHoldDisc(drive) {
                discs.append(URL(fileURLWithPath: "/dev/\(drive)"))
            }
            return discs
        #elseif os(Windows)
            let drives = portableExternalVolumeURLs()
            return drives.filter { AVPlayer.discDrive(for: $0) != nil } + drives.filter { AVPlayer.discDrive(for: $0) == nil }
        #else
            return []
        #endif
    }

    #if os(Linux)
        /// A place's name as the system's list of what it has opened writes it: a space is
        /// "\040" there.
        private nonisolated static func unescaped(_ name: String) -> String {
            guard name.contains("\\") else { return name }
            var bytes: [UInt8] = []
            let raw = Array(name.utf8)
            var at = 0
            while at < raw.count {
                if raw[at] == UInt8(ascii: "\\"), at + 3 < raw.count,
                   let value = UInt8(String(decoding: raw[(at + 1) ... (at + 3)], as: UTF8.self), radix: 8)
                {
                    bytes.append(value)
                    at += 4
                } else {
                    bytes.append(raw[at])
                    at += 1
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// False for a disc drive the system says is empty, which saves asking the drive
        /// itself every few seconds. (Where the system doesn't say, the drive is asked.)
        private nonisolated static func mayHoldDisc(_ drive: String) -> Bool {
            guard let number = try? String(contentsOfFile: "/sys/block/\(drive)/dev", encoding: .utf8),
                  let known = try? String(contentsOfFile: "/run/udev/data/b\(number.trimmingCharacters(in: .whitespacesAndNewlines))", encoding: .utf8)
            else { return true }
            return known.contains("E:ID_CDROM_MEDIA=1")
        }
    #endif

    /// What a disc in a drive calls itself, where the drive's address says nothing of which
    /// disc is in it (on Windows, and on Linux for a disc the system hasn't opened).
    private nonisolated static func name(ofDiscInDrive disc: URL) -> String? {
        #if os(Linux)
            guard disc.path.hasPrefix("/dev/") else { return nil }
            return DriveDisc.look(at: disc.path).name
        #elseif os(Windows)
            guard let drive = AVPlayer.discDrive(for: disc) else { return nil }
            var label = [WCHAR](repeating: 0, count: 262)
            var serial: DWORD = 0
            let found = (drive + "\\").withCString(encodedAs: UTF16.self) {
                GetVolumeInformationW($0, &label, DWORD(label.count - 1), &serial, nil, nil, nil, 0)
            }
            guard found else { return nil }
            return String(decodingCString: label, as: UTF16.self) + "-" + String(serial, radix: 16)
        #else
            return nil
        #endif
    }

    /// Whether a DVD's pictures are scrambled against copying, told from the first of them:
    /// such a disc can't be played here.
    nonisolated static func isCopyProtected(_ disc: URL) -> Bool {
        #if os(Linux)
            if disc.path.hasPrefix("/dev/") {
                return DriveDisc.look(at: disc.path).isScrambled
            }
        #endif
        let fileManager = FileManager.default
        // (The disc's folder of pictures: in the disc, or the disc's own address where it goes by that.)
        let folder = (["VIDEO_TS", "video_ts"].map { disc.appendingPathComponent($0, isDirectory: true) } + [disc]).first {
            fileManager.fileExists(atPath: $0.appendingPathComponent("VIDEO_TS.IFO").path) || fileManager.fileExists(atPath: $0.appendingPathComponent("video_ts.ifo").path)
        }
        guard let folder, let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return false }
        // The first part of each title's own pictures ("VTS_01_1.VOB"), the largest first.
        let parts = names.filter { $0.uppercased().hasPrefix("VTS_") && $0.uppercased().hasSuffix("_1.VOB") }
            .map { folder.appendingPathComponent($0) }
            .sorted { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard let first = parts.first else { return false }
        // (Read with the plain file calls: a disc that won't give its pictures up fails here, and
        // is taken for protected.)
        guard let file = fopen(first.path, "rb") else { return true }
        defer { fclose(file) }
        let sector = 2048
        var bytes = [UInt8](repeating: 0, count: sector)
        for _ in 0 ..< 400 {
            let got = fread(&bytes, 1, sector, file)
            if got < sector {
                if ferror(file) != 0 { return true }
                break
            }
            if isScrambled(bytes) { return true }
        }
        return false
    }

    /// Whether one of a DVD's 2048-byte sectors of pictures or sound says it is scrambled.
    fileprivate nonisolated static func isScrambled(_ bytes: [UInt8]) -> Bool {
        // A pack, then a packet of pictures or sound: its header says whether it's scrambled.
        guard bytes.count >= 2048, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1, bytes[3] == 0xBA else { return false }
        let start = 14 + Int(bytes[13] & 0x07)
        guard start + 7 < 2048, bytes[start] == 0, bytes[start + 1] == 0, bytes[start + 2] == 1 else { return false }
        let stream = bytes[start + 3]
        guard stream == 0xBD || (0xC0 ... 0xEF).contains(stream) else { return false }
        return bytes[start + 6] & 0x30 != 0
    }

    #if FIRSTROW_PORTABLE
        /// Whether the system has what its players use to play a disc that is protected
        /// against copying. (It isn't part of First Row, nor of most systems as they come.)
        nonisolated static var canPlayProtectedDiscs: Bool {
            #if os(Linux)
                for name in ["libdvdcss.so.2", "libdvdcss.so"] {
                    if let library = dlopen(name, RTLD_LAZY) {
                        dlclose(library)
                        return true
                    }
                }
            #endif
            return false
        }
    #endif
}

#if os(Linux)
    /// The disc in a drive, for one the system hasn't opened: whether it's a movie DVD, what
    /// tells it from other discs, and whether its pictures are scrambled. The library that
    /// mpv reads DVDs with is asked (it is there wherever mpv can play one), once for each
    /// disc: what it says is kept until the drive holds something else.
    struct DriveDisc {
        var holdsMovie = false
        var name: String?
        var isScrambled = false

        private static let lock = NSLock()
        nonisolated(unsafe) private static var known: [String: (disc: String, answer: DriveDisc)] = [:]

        static func look(at device: String) -> DriveDisc {
            // What the system knows of the disc that is in the drive now: its name and number.
            let number = (try? String(contentsOfFile: "/sys/block/\(URL(fileURLWithPath: device).lastPathComponent)/dev", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let disc = ((try? String(contentsOfFile: "/run/udev/data/b\(number)", encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { $0.hasPrefix("E:ID_FS_") || $0.hasPrefix("E:ID_CDROM_MEDIA") }.joined(separator: "\n")
            lock.lock()
            if !disc.isEmpty, let kept = known[device], kept.disc == disc {
                lock.unlock()
                return kept.answer
            }
            lock.unlock()
            let answer = read(device)
            lock.lock()
            known[device] = (disc, answer)
            lock.unlock()
            return answer
        }

        private typealias Open = @convention(c) (UnsafePointer<CChar>) -> OpaquePointer?
        private typealias Close = @convention(c) (OpaquePointer?) -> Void
        private typealias OpenFile = @convention(c) (OpaquePointer?, Int32, Int32) -> OpaquePointer?
        private typealias ReadBlocks = @convention(c) (OpaquePointer?, Int32, Int, UnsafeMutablePointer<UInt8>) -> Int
        private typealias DiscID = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>) -> Int32

        private static let library: UnsafeMutableRawPointer? = {
            for name in ["libdvdread.so.8", "libdvdread.so.7", "libdvdread.so.4", "libdvdread.so"] {
                if let library = dlopen(name, RTLD_LAZY) { return library }
            }
            return nil
        }()

        private static func function<T>(_ name: String, as _: T.Type) -> T? {
            guard let library, let symbol = dlsym(library, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }

        private static func read(_ device: String) -> DriveDisc {
            var answer = DriveDisc()
            guard let open = function("DVDOpen", as: Open.self), let close = function("DVDClose", as: Close.self),
                  let openFile = function("DVDOpenFile", as: OpenFile.self), let closeFile = function("DVDCloseFile", as: Close.self),
                  let disc = open(device)
            else { return answer }
            defer { close(disc) }
            // (0, 0: the disc's own table of contents, VIDEO_TS.IFO. It's a movie DVD if it has one.)
            guard let contents = openFile(disc, 0, 0) else { return answer }
            closeFile(contents)
            answer.holdsMovie = true
            if let discID = function("DVDDiscID", as: DiscID.self) {
                var bytes = [UInt8](repeating: 0, count: 16)
                if discID(disc, &bytes) == 0 {
                    answer.name = bytes.map { String(format: "%02x", $0) }.joined()
                }
            }
            // Scrambled pictures matter only where nothing is installed to unscramble them
            // (where it is, the library has already done so here). The first title's start
            // says: scrambled, or not given up by the drive at all.
            if !DiscWatch.canPlayProtectedDiscs, let readBlocks = function("DVDReadBlocks", as: ReadBlocks.self), let title = openFile(disc, 1, 3) {
                var bytes = [UInt8](repeating: 0, count: 2048)
                for block in 0 ..< 200 {
                    guard readBlocks(title, Int32(block), 1, &bytes) == 1 else {
                        answer.isScrambled = block == 0 || answer.isScrambled
                        break
                    }
                    if DiscWatch.isScrambled(bytes) {
                        answer.isScrambled = true
                        break
                    }
                }
                closeFile(title)
            }
            return answer
        }
    }
#endif

extension MenuView {
    /// A disc has come or gone: DVD joins the head of the main menu or leaves it, and the
    /// selection stays on the item it was on.
    func discDidChange() {
        let selectedID = menuItems.indices.contains(selectedIndex) ? menuItems[selectedIndex].id : nil
        #if FIRSTROW_PORTABLE
            // (The next disc in the same drive isn't the movie that was last stopped.)
            if let last = lastClosedMovieURL, AVPlayer.discDrive(for: last) != nil {
                lastClosedMovieURL = nil
            }
        #endif
        let items = Self.shownRootItems()
        guard items != menuItems else { return }
        menuItems = items
        if let index = menuItems.firstIndex(where: { $0.id == selectedID }) {
            if index != selectedIndex { withTransaction(.instant) { selectedIndex = index } }
        } else if selectedIndex >= menuItems.count || selectedID == "dvd" {
            withTransaction(.instant) { selectedIndex = 0 }
        }
        objectWillChange.send()
    }

    /// Plays the disc: here if it can be, in the system's own DVD player if it's protected
    /// against copying (or First Row has nothing to play it with).
    func playDisc() {
        guard let disc = DiscWatch.shared.disc, !isMovieTransitioning, !isMoviePlaybackVisible else {
            playLimitSoundOnceForCurrentHold()
            return
        }
        Task { @MainActor in
            let isProtected = await Task.detached(priority: .userInitiated) { DiscWatch.isCopyProtected(disc) }.value
            guard DiscWatch.shared.disc?.standardizedFileURL == disc.standardizedFileURL else { return }
            #if os(macOS)
                if isProtected || !MediaEngine.isAvailable {
                    if !self.openInSystemDVDPlayer(disc) {
                        self.playSound(named: "Limit")
                        self.presentFullscreenScene(key: self.featureErrorFullscreenKey, payload: [
                            "header": "This disc can't be played.",
                            "subcaption": isProtected ? "It's protected against copying." : MenuView.whyMovieCouldNotBePlayed(disc.appendingPathComponent("VIDEO_TS.VOB")),
                        ])
                    }
                    return
                }
            #elseif FIRSTROW_PORTABLE
                // First Row unscrambles nothing itself. On Linux a protected disc plays where
                // the system has what its players use for one, and says so where it hasn't. On
                // Windows it goes to the PC's own DVD player, an app licensed to play it, if
                // the PC has one, and says so if it hasn't.
                if isProtected, !DiscWatch.canPlayProtectedDiscs {
                    #if os(Windows)
                        if let drive = AVPlayer.discDrive(for: disc), fr_windows_open_dvd_player(drive + "\\") != 0 {
                            return
                        }
                    #endif
                    self.playSound(named: "Limit")
                    self.presentFullscreenScene(key: self.featureErrorFullscreenKey, payload: [
                        "header": "This disc can't be played.",
                        "subcaption": "It's protected against copying.",
                    ])
                    return
                }
            #endif
            DiscWatch.shared.protectedDisc = isProtected ? disc.standardizedFileURL : nil
            self.startMoviePlayback(from: disc)
        }
    }

    #if os(macOS)
        /// Hands a disc to the DVD player that comes with the Mac, where there is one.
        private func openInSystemDVDPlayer(_ disc: URL) -> Bool {
            let places = ["/System/Library/CoreServices/Applications/DVD Player.app", "/System/Applications/DVD Player.app", "/Applications/DVD Player.app"]
            guard let app = places.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([disc], withApplicationAt: URL(fileURLWithPath: app), configuration: configuration, completionHandler: nil)
            return true
        }
    #endif
}
