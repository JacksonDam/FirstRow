import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
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

    /// The disc there is to play: the folder that holds its VIDEO_TS.
    private(set) var disc: URL?
    /// Called when a disc has come or gone.
    var onChange: (() -> Void)?
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
            DispatchQueue.main.async {
                MainActor.assumeIsolatedIfPossible {
                    self.isLooking = false
                    guard found?.standardizedFileURL != self.disc?.standardizedFileURL else { return }
                    self.disc = found
                    self.onChange?()
                }
            }
        }
    }

    /// The first connected disc that holds a DVD's files.
    private nonisolated static func findDisc() -> URL? {
        if FirstRowHarness.isActive {
            // (A test names its own disc, and nothing that is connected is looked at.)
            guard let path = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_DVD"] else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return holdsDVD(url) ? url : nil
        }
        return candidateVolumes().first(where: holdsDVD)
    }

    private nonisolated static func holdsDVD(_ volume: URL) -> Bool {
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
    /// other drive's files are looked at for this), elsewhere every drive that is connected.
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
        #elseif FIRSTROW_PORTABLE
            return portableExternalVolumeURLs()
        #else
            return []
        #endif
    }

    /// Whether a DVD's pictures are scrambled against copying, told from the first of them:
    /// such a disc can't be played here.
    nonisolated static func isCopyProtected(_ disc: URL) -> Bool {
        let fileManager = FileManager.default
        let folder = ["VIDEO_TS", "video_ts"].map { disc.appendingPathComponent($0, isDirectory: true) }.first { fileManager.fileExists(atPath: $0.path) }
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
            // A pack, then a packet of pictures or sound: its header says whether it's scrambled.
            guard bytes[0] == 0, bytes[1] == 0, bytes[2] == 1, bytes[3] == 0xBA else { continue }
            let start = 14 + Int(bytes[13] & 0x07)
            guard start + 7 < sector, bytes[start] == 0, bytes[start + 1] == 0, bytes[start + 2] == 1 else { continue }
            let stream = bytes[start + 3]
            guard stream == 0xBD || (0xC0 ... 0xEF).contains(stream) else { continue }
            if bytes[start + 6] & 0x30 != 0 { return true }
        }
        return false
    }
}

extension MenuView {
    /// A disc has come or gone: DVD joins the head of the main menu or leaves it, and the
    /// selection stays on the item it was on.
    func discDidChange() {
        let selectedID = menuItems.indices.contains(selectedIndex) ? menuItems[selectedIndex].id : nil
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
            #else
                _ = isProtected
            #endif
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
