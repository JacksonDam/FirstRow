#if !FIRSTROW_PORTABLE
    import AVFoundation
    import Foundation
    import QuartzCore

    /// First Row's own engine for the kinds of movie the system's player can't open (see
    /// MediaEngine/README.md): a framework kept in the app, loaded the first time it's wanted,
    /// on the systems new enough for it.
    @MainActor
    enum MediaEngine {
        private static var engine: MediaEngineProviding?
        private static var hasLooked = false

        /// The engine, if this copy of First Row carries one that this system can run.
        static var shared: MediaEngineProviding? {
            if hasLooked { return engine }
            hasLooked = true
            guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, *) else { return nil }
            guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
            let url = frameworks.appendingPathComponent(MediaEngineInterface.frameworkName + ".framework", isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url), bundle.load(),
                  let made = (NSClassFromString(MediaEngineInterface.providerClassName) as? NSObject.Type)?.init(),
                  made.responds(to: #selector(getter: MediaEngineProviding.interfaceVersion))
            else { return nil }
            // (The class is the framework's own, known here by its name alone.)
            let found = (made as? MediaEngineProviding) ?? unsafeBitCast(made, to: MediaEngineProviding.self)
            guard found.interfaceVersion == MediaEngineInterface.version else { return nil }
            engine = found
            return found
        }

        static var isAvailable: Bool { shared != nil }

        /// The kinds of file the system's own player opens. Everything else is the engine's.
        static let systemPlayerExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8", "m3u", "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf"]

        /// Whether a movie is one for the engine: one it can be expected to open and the
        /// system's player can't.
        static func plays(_ url: URL) -> Bool {
            guard isAvailable else { return false }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "smb" { return true }
            guard url.isFileURL || scheme == "http" || scheme == "https" else { return false }
            let kind = url.pathExtension.lowercased()
            if url.isFileURL, kind.isEmpty || kind == "dvdmedia" {
                var isFolder: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
            }
            return !kind.isEmpty && !systemPlayerExtensions.contains(kind)
        }

        /// What a file is, as the engine reads it (see `MediaEngineKey`): nothing where there
        /// is no engine.
        static func describe(_ url: URL) async -> [String: Any] {
            guard let engine = shared else { return [:] }
            return await withCheckedContinuation { continuation in
                engine.describe(url) { continuation.resume(returning: $0) }
            }
        }

        /// A frame of a movie, from so many seconds in.
        static func picture(of url: URL, atSeconds seconds: Double, longestSide: Double = 1100) async -> CGImage? {
            guard let engine = shared else { return nil }
            return await withCheckedContinuation { continuation in
                engine.picture(of: url, details: [MediaEngineKey.seconds: seconds, MediaEngineKey.longestSide: longestSide]) {
                    continuation.resume(returning: $0)
                }
            }
        }
    }

    /// A movie the engine is playing, as the movie screen uses it.
    @MainActor
    final class EngineMoviePlayer: MoviePlayer {
        private let engine: MediaEnginePlaying
        /// The engine plays one movie at a time: which player's it is playing now.
        private static var turn = 0
        private let myTurn: Int
        private var wantsToPlay: Bool
        private var clock: Timer?
        private var timeObservers: [UUID: (every: Double, last: CFTimeInterval, lastTime: Double, block: @MainActor (Double) -> Void)] = [:]
        private var endObservers: [UUID: @MainActor () -> Void] = [:]
        private var hasToldOfEnd = false
        private var hasToldOfFailure = false
        private var captionsRevision = -1

        /// Called when the subtitles to show have changed.
        var onCaptions: (([MovieCaption]) -> Void)?
        /// Called once if the engine can't play the movie, with why.
        var onFailure: ((String) -> Void)?
        /// Called when what the movie offers may have changed: its tracks, its chapters.
        var onChange: (() -> Void)?

        /// Opens `url` with the engine, or returns nil where there is no engine.
        init?(url: URL, startSeconds: Double = 0, headers: [String: String] = [:], subtitleFiles: [MovieSubtitleFile] = [], paused: Bool = false) {
            guard let made = MediaEngine.shared?.player() else { return nil }
            engine = (made as? MediaEnginePlaying) ?? unsafeBitCast(made, to: MediaEnginePlaying.self)
            Self.turn += 1
            myTurn = Self.turn
            wantsToPlay = !paused
            var request: [String: Any] = [MediaEngineKey.url: url, MediaEngineKey.start: max(0, startSeconds), MediaEngineKey.paused: paused]
            if !headers.isEmpty { request[MediaEngineKey.headers] = headers }
            if !subtitleFiles.isEmpty {
                request[MediaEngineKey.subtitleFiles] = subtitleFiles.map { file -> [String: Any] in
                    var entry: [String: Any] = [MediaEngineKey.url: file.url]
                    if let language = file.language { entry[MediaEngineKey.language] = language }
                    if let name = file.name { entry[MediaEngineKey.name] = name }
                    return entry
                }
            }
            engine.onChange = { [weak self] in self?.engineChanged() }
            engine.open(request)
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        }

        deinit {
            clock?.invalidate()
            let engine = engine
            let turn = myTurn
            // (Unless another movie has been opened in its place since.)
            MainActor.assumeIsolatedIfPossible {
                if EngineMoviePlayer.turn == turn {
                    engine.onChange = nil
                    engine.close()
                }
            }
        }

        private var isMine: Bool { Self.turn == myTurn }

        /// The engine's own layer for the picture.
        var pictureLayer: CALayer { engine.pictureLayer }
        var pictureSize: CGSize { isMine ? engine.pictureSize : .zero }
        /// "sdr", "hdr10", "hdr10+", "dolbyvision" or "hlg".
        var pictureKind: String { isMine ? engine.pictureKind : "sdr" }
        var hasPicture: Bool { isMine && engine.hasPicture }
        /// The system's player, when the engine is showing the picture with it.
        var systemPlayer: AVPlayer? { isMine ? engine.systemPlayer : nil }

        // MARK: MoviePlayer

        var isMuted: Bool {
            get { engine.isMuted }
            set { if isMine { engine.isMuted = newValue } }
        }

        var rate: Float {
            guard isMine, wantsToPlay else { return 0 }
            switch engine.phase {
            case "opening", "playing": return 1
            default: return 0
            }
        }

        func play() {
            guard isMine else { return }
            wantsToPlay = true
            engine.play()
        }

        func pause() {
            guard isMine else { return }
            wantsToPlay = false
            engine.pause()
        }

        var isWaitingToPlay: Bool { isMine && wantsToPlay && engine.isWaiting }
        var positionSeconds: Double { isMine ? max(0, engine.position) : 0 }
        var lengthSeconds: Double { isMine ? max(0, engine.duration) : 0 }

        func seek(toSeconds seconds: Double, exactly: Bool, then done: (@MainActor (Bool) -> Void)?) {
            guard isMine else {
                done?(false)
                return
            }
            hasToldOfEnd = false
            engine.seek(to: seconds, exactly: exactly) { finished in
                MainActor.assumeIsolatedIfPossible { done?(finished) }
            }
        }

        func setSpeed(_ speed: Double) {
            if isMine { engine.speed = speed }
        }

        func observeTime(every seconds: Double, _ block: @escaping @MainActor (Double) -> Void) -> Any {
            let id = UUID()
            timeObservers[id] = (max(1.0 / 60, seconds), 0, -1, block)
            return id
        }

        func stopObservingTime(_ observer: Any) {
            if let id = observer as? UUID { timeObservers.removeValue(forKey: id) }
        }

        func observeEnd(_ block: @escaping @MainActor () -> Void) -> Any? {
            let id = UUID()
            endObservers[id] = block
            return id
        }

        func stopObservingEnd(_ observer: Any) {
            if let id = observer as? UUID { endObservers.removeValue(forKey: id) }
        }

        func tracks(_ kind: MovieTrackKind) async -> [MovieTrack] {
            guard isMine else { return [] }
            let found = kind == .subtitles ? engine.subtitleTracks : engine.audioTracks
            return found.enumerated().compactMap { position, entry in
                guard let id = entry[MediaEngineKey.id] as? Int else { return nil }
                let title = MovieTrackNaming.title(
                    name: entry[MediaEngineKey.name] as? String,
                    language: entry[MediaEngineKey.language] as? String,
                    channels: kind == .audio ? (entry[MediaEngineKey.channels] as? Int) ?? 0 : 0,
                    position: position,
                )
                return MovieTrack(id: id, title: title, isChosen: (entry[MediaEngineKey.isChosen] as? Bool) ?? false)
            }
        }

        func chooseTrack(_ kind: MovieTrackKind, id: Int?) async {
            guard isMine else { return }
            switch kind {
            case .subtitles: engine.chooseSubtitleTrack(id ?? -1)
            case .audio: if let id { engine.chooseAudioTrack(id) }
            }
        }

        func chapters() async -> [MovieChapter] {
            guard isMine else { return [] }
            return engine.chapters.enumerated().compactMap { index, entry in
                guard let start = entry[MediaEngineKey.start] as? Double else { return nil }
                let title = ((entry[MediaEngineKey.title] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return MovieChapter(title: title.isEmpty ? "Chapter \(index + 1)" : title, start: max(0, start))
            }
        }

        // MARK: What the engine says

        private func engineChanged() {
            guard isMine else { return }
            tellOfEndOrFailure()
            onChange?()
        }

        private func tellOfEndOrFailure() {
            switch engine.phase {
            case "ended":
                guard !hasToldOfEnd else { return }
                hasToldOfEnd = true
                for block in endObservers.values { block() }
            case "failed":
                guard !hasToldOfFailure else { return }
                hasToldOfFailure = true
                onFailure?(engine.failure ?? "")
            default:
                break
            }
        }

        /// Thirty times a second: the time for those watching it, and the subtitles.
        private func tick() {
            guard isMine else { return }
            let now = CACurrentMediaTime()
            let position = positionSeconds
            for (id, var observer) in timeObservers where now - observer.last >= observer.every - 0.004 {
                // (Told while it plays, and of any other move, as the system's player tells.)
                guard rate > 0 || position != observer.lastTime else { continue }
                observer.last = now
                observer.lastTime = position
                timeObservers[id] = observer
                observer.block(position)
            }
            let revision = engine.captionsRevision
            if revision != captionsRevision {
                captionsRevision = revision
                onCaptions?(engine.captions.map(Self.caption))
            }
        }

        private static func caption(from entry: [String: Any]) -> MovieCaption {
            var caption = MovieCaption()
            caption.text = entry[MediaEngineKey.text] as? String
            caption.alignment = entry[MediaEngineKey.alignment] as? Int
            if let runs = entry[MediaEngineKey.runs] as? [[String: Any]] {
                caption.runs = runs.map { run in
                    MovieCaption.Run(
                        text: (run[MediaEngineKey.text] as? String) ?? "",
                        isBold: (run[MediaEngineKey.isBold] as? Bool) ?? false,
                        isItalic: (run[MediaEngineKey.isItalic] as? Bool) ?? false,
                        isUnderlined: (run[MediaEngineKey.isUnderlined] as? Bool) ?? false,
                        color: run[MediaEngineKey.color] as? Int,
                    )
                }
            }
            if let image = entry[MediaEngineKey.image], CFGetTypeID(image as CFTypeRef) == CGImage.typeID {
                caption.image = (image as! CGImage)
                caption.frame = CGRect(
                    x: (entry[MediaEngineKey.x] as? Double) ?? 0,
                    y: (entry[MediaEngineKey.y] as? Double) ?? 0,
                    width: (entry[MediaEngineKey.width] as? Double) ?? 0,
                    height: (entry[MediaEngineKey.height] as? Double) ?? 0,
                )
                caption.canvas = CGSize(
                    width: (entry[MediaEngineKey.canvasWidth] as? Double) ?? 0,
                    height: (entry[MediaEngineKey.canvasHeight] as? Double) ?? 0,
                )
            }
            return caption
        }
    }
#endif
