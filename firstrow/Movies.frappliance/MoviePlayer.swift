import AVFoundation
import CoreGraphics
import Foundation

/// A track of a movie's sound or of its subtitles, as the options panel lists it.
struct MovieTrack: Equatable {
    let id: Int
    let title: String
    var isChosen: Bool
}

enum MovieTrackKind {
    case subtitles
    case audio
}

/// A file of subtitles kept beside a movie.
struct MovieSubtitleFile: Equatable {
    let url: URL
    var language: String?
    var name: String?
}

/// A chapter of a movie: its name and where it starts, in seconds.
struct MovieChapter: Equatable {
    let title: String
    let start: Double
}

/// A subtitle the movie's player has First Row draw: words, or a picture with its place.
struct MovieCaption {
    struct Run: Equatable {
        var text: String
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        /// 0xRRGGBBAA, when the subtitle gives its words a colour.
        var color: Int?
    }

    var text: String?
    var runs: [Run] = []
    /// Where the words ask to go, as on a number pad (2 the middle of the foot, 8 of the top).
    var alignment: Int?
    var image: CGImage?
    /// A picture's place in its canvas, each from 0 to 1, from the top left.
    var frame = CGRect.zero
    /// The canvas's shape in the movie's own pixels (zero when it is the movie's).
    var canvas = CGSize.zero
}

/// What plays the movie on the movie screen, as that screen and its controls use it. It is the
/// system's player for what that can open, and for the rest First Row's own engine, where the
/// system is new enough for it (see `MediaEngine`). On Linux and Windows the one player, which
/// plays through mpv, is both.
@MainActor
protocol MoviePlayer: AnyObject {
    var isMuted: Bool { get set }
    /// Above zero while it's playing, or has been asked to and is waiting to.
    var rate: Float { get }
    func play()
    func pause()
    /// Asked to play, it's waiting for something to show: the movie still opening, another
    /// place in it still being moved to, more of a stream still to come.
    var isWaitingToPlay: Bool { get }
    var positionSeconds: Double { get }
    /// The movie's length, 0 until it's known.
    var lengthSeconds: Double { get }
    func seek(toSeconds seconds: Double, exactly: Bool, then done: (@MainActor (Bool) -> Void)?)
    /// Plays at a speed (1 is normal), now if it's playing and whenever it plays again.
    func setSpeed(_ speed: Double)

    /// Says where the movie has got to, every so many seconds while it plays.
    func observeTime(every seconds: Double, _ block: @escaping @MainActor (Double) -> Void) -> Any
    func stopObservingTime(_ observer: Any)
    /// Says when the movie has played to its end.
    func observeEnd(_ block: @escaping @MainActor () -> Void) -> Any?
    func stopObservingEnd(_ observer: Any)
    /// Says if the movie can't be played: it wouldn't open, or it broke off.
    func observeFailure(_ block: @escaping @MainActor () -> Void) -> Any?
    func stopObservingFailure(_ observer: Any)

    func tracks(_ kind: MovieTrackKind) async -> [MovieTrack]
    /// Chooses a track by its id; subtitles are turned off with nil.
    func chooseTrack(_ kind: MovieTrackKind, id: Int?) async
    func chapters() async -> [MovieChapter]
}

extension MoviePlayer {
    func seek(toSeconds seconds: Double, exactly: Bool) {
        seek(toSeconds: seconds, exactly: exactly, then: nil)
    }
}

#if !FIRSTROW_PORTABLE
    /// Names a track for the options panel: its language in full, then what the file calls it
    /// if that says anything more.
    enum MovieTrackNaming {
        static func languageName(_ code: String?) -> String? {
            guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty, code.lowercased() != "und" else { return nil }
            if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty, name.lowercased() != code.lowercased() {
                return name.prefix(1).uppercased() + name.dropFirst()
            }
            return code.uppercased()
        }

        /// `name` as the file gives it, `language` as a code, and for sound how many channels.
        static func title(name: String?, language: String?, channels: Int = 0, position: Int) -> String {
            var parts: [String] = []
            if let languageName = languageName(language) { parts.append(languageName) }
            if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !isPlaceholder(name, language: language),
               !parts.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            {
                parts.append(name)
            }
            var title = parts.joined(separator: ": ")
            if title.isEmpty { title = L("Track %@", position + 1) }
            if let layout = channelLayout(channels), !title.localizedCaseInsensitiveContains(layout) {
                title += " (\(layout))"
            }
            return title
        }

        /// A name made up from the language and the kind of track ("ENG (srt)"), which says
        /// nothing the language doesn't.
        private static func isPlaceholder(_ name: String, language: String?) -> Bool {
            guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else { return false }
            let head = name[..<open].trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty, head.count <= 3, head == head.uppercased() else { return false }
            return language == nil || head.lowercased() == language?.lowercased()
        }

        private static func channelLayout(_ channels: Int) -> String? {
            switch channels {
            case 1: L("Mono")
            case 2: L("Stereo")
            case 6: "5.1"
            case 7: "6.1"
            case 8: "7.1"
            default: nil
            }
        }
    }
#endif

#if FIRSTROW_PORTABLE
    extension AVPlayer: MoviePlayer {
        var isWaitingToPlay: Bool { timeControlStatus == .waitingToPlayAtSpecifiedRate }

        var positionSeconds: Double {
            let seconds = currentTime().seconds
            return seconds.isFinite ? max(0, seconds) : 0
        }

        var lengthSeconds: Double {
            guard let seconds = currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return 0 }
            return seconds
        }

        func seek(toSeconds seconds: Double, exactly: Bool, then done: (@MainActor (Bool) -> Void)?) {
            let tolerance = exactly ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
            seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                MainActor.assumeIsolatedIfPossible { done?(finished) }
            }
        }

        func setSpeed(_ speed: Double) {
            playbackSpeed = speed
        }

        func observeTime(every seconds: Double, _ block: @escaping @MainActor (Double) -> Void) -> Any {
            addPeriodicTimeObserver(forInterval: CMTime(seconds: seconds, preferredTimescale: 600), queue: .main) { time in
                MainActor.assumeIsolatedIfPossible { block(time.seconds.isFinite ? max(0, time.seconds) : 0) }
            }
        }

        func stopObservingTime(_ observer: Any) {
            removeTimeObserver(observer)
        }

        func observeEnd(_ block: @escaping @MainActor () -> Void) -> Any? {
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolatedIfPossible {
                    guard let self, let item = note.object as? AVPlayerItem, item === self.currentItem else { return }
                    block()
                }
            }
        }

        func stopObservingEnd(_ observer: Any) {
            NotificationCenter.default.removeObserver(observer)
        }

        func observeFailure(_ block: @escaping @MainActor () -> Void) -> Any? {
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolatedIfPossible {
                    guard let self, let item = note.object as? AVPlayerItem, item === self.currentItem else { return }
                    block()
                }
            }
        }

        func stopObservingFailure(_ observer: Any) {
            NotificationCenter.default.removeObserver(observer)
        }

        func tracks(_ kind: MovieTrackKind) async -> [MovieTrack] {
            tracks(ofType: kind == .subtitles ? "sub" : "audio").map { MovieTrack(id: $0.id, title: $0.title, isChosen: $0.isSelected) }
        }

        func chooseTrack(_ kind: MovieTrackKind, id: Int?) async {
            selectTrack(ofType: kind == .subtitles ? "sub" : "audio", id: id)
        }

        func chapters() async -> [MovieChapter] {
            chapterList().enumerated().map { MovieChapter(title: $0.element.title.isEmpty ? L("Chapter %@", $0.offset + 1) : $0.element.title, start: $0.element.start) }
        }
    }
#else
    /// What watches the system's player for a movie it can't play.
    private final class SystemPlayerFailureWatch {
        var breakingOff: NSObjectProtocol?
        var status: NSKeyValueObservation?
    }

    extension AVPlayer: MoviePlayer {
        var isWaitingToPlay: Bool { timeControlStatus == .waitingToPlayAtSpecifiedRate }

        var positionSeconds: Double {
            let seconds = currentTime().seconds
            return seconds.isFinite ? max(0, seconds) : 0
        }

        var lengthSeconds: Double {
            guard let seconds = currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return 0 }
            return seconds
        }

        func seek(toSeconds seconds: Double, exactly: Bool, then done: (@MainActor (Bool) -> Void)?) {
            let tolerance = exactly ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let done else {
                seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
                return
            }
            seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                if Thread.isMainThread {
                    MainActor.assumeIsolatedIfPossible { done(finished) }
                } else {
                    Task { @MainActor in done(finished) }
                }
            }
        }

        func setSpeed(_ speed: Double) {
            if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
                defaultRate = Float(speed)
            }
            if rate > 0.01 {
                rate = Float(speed)
            }
        }

        func observeTime(every seconds: Double, _ block: @escaping @MainActor (Double) -> Void) -> Any {
            addPeriodicTimeObserver(forInterval: CMTime(seconds: seconds, preferredTimescale: 600), queue: .main) { time in
                MainActor.assumeIsolatedIfPossible { block(time.seconds.isFinite ? max(0, time.seconds) : 0) }
            }
        }

        func stopObservingTime(_ observer: Any) {
            removeTimeObserver(observer)
        }

        func observeEnd(_ block: @escaping @MainActor () -> Void) -> Any? {
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolatedIfPossible {
                    guard let self, let item = note.object as? AVPlayerItem, item === self.currentItem else { return }
                    block()
                }
            }
        }

        func stopObservingEnd(_ observer: Any) {
            NotificationCenter.default.removeObserver(observer)
        }

        func observeFailure(_ block: @escaping @MainActor () -> Void) -> Any? {
            let watch = SystemPlayerFailureWatch()
            watch.breakingOff = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolatedIfPossible {
                    guard let self, let item = note.object as? AVPlayerItem, item === self.currentItem else { return }
                    block()
                }
            }
            // (An item that won't open says so by its status, with no notice.)
            watch.status = observe(\.currentItem?.status, options: [.initial, .new]) { player, _ in
                guard player.currentItem?.status == .failed else { return }
                MainActor.assumeIsolatedIfPossible { block() }
            }
            return watch
        }

        func stopObservingFailure(_ observer: Any) {
            guard let watch = observer as? SystemPlayerFailureWatch else { return }
            if let breakingOff = watch.breakingOff { NotificationCenter.default.removeObserver(breakingOff) }
            watch.status?.invalidate()
            watch.breakingOff = nil
            watch.status = nil
        }

        /// The file's choices of subtitles or of sound, and the one in use.
        private func choices(_ kind: MovieTrackKind) async -> (item: AVPlayerItem, group: AVMediaSelectionGroup, options: [AVMediaSelectionOption])? {
            guard let item = currentItem else { return nil }
            let characteristic: AVMediaCharacteristic = kind == .subtitles ? .legible : .audible
            let group: AVMediaSelectionGroup?
            if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
                group = try? await item.asset.loadMediaSelectionGroup(for: characteristic)
            } else {
                group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
            }
            guard let group else { return nil }
            let options = kind == .subtitles ? group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } : group.options
            return (item, group, options)
        }

        func tracks(_ kind: MovieTrackKind) async -> [MovieTrack] {
            guard let found = await choices(kind) else { return [] }
            let current = found.item.currentMediaSelection.selectedMediaOption(in: found.group)
            return found.options.enumerated().map { MovieTrack(id: $0.offset, title: $0.element.displayName, isChosen: $0.element == current) }
        }

        func chooseTrack(_ kind: MovieTrackKind, id: Int?) async {
            guard let found = await choices(kind) else { return }
            if let id {
                guard found.options.indices.contains(id) else { return }
                found.item.select(found.options[id], in: found.group)
            } else if kind == .subtitles {
                found.item.select(nil, in: found.group)
            }
        }

        func chapters() async -> [MovieChapter] {
            guard let asset = currentItem?.asset else { return [] }
            let languages = Locale.preferredLanguages
            let groups: [AVTimedMetadataGroup]
            if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
                groups = await (try? asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)) ?? []
            } else {
                groups = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: languages)
            }
            var chapters: [MovieChapter] = []
            for (index, group) in groups.enumerated() {
                let start = group.timeRange.start.seconds
                guard start.isFinite else { continue }
                var title: String?
                if let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first {
                    if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
                        title = try? await item.load(.stringValue)
                    } else {
                        title = item.stringValue
                    }
                }
                let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                chapters.append(MovieChapter(title: trimmed.isEmpty ? L("Chapter %@", index + 1) : trimmed, start: max(0, start)))
            }
            return chapters
        }
    }
#endif
