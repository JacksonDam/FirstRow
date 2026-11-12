import AetherEngine
import AVFoundation
import Combine
import Foundation
import QuartzCore
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// The layer First Row is given for the picture. It says when it has been given a new size, so
/// the engine's own view can be kept filling it.
final class PictureLayer: CALayer {
    var onLayout: (() -> Void)?

    override func layoutSublayers() {
        super.layoutSublayers()
        onLayout?()
    }
}

/// The engine as First Row drives it: one movie after another, each opened, played, moved
/// about in and let go of (see `MediaEnginePlaying`).
@MainActor
final class EnginePlayer: NSObject, MediaEnginePlaying {
    private let engine: AetherEngine
    /// The engine's own view, which holds whichever layer is showing the picture. It is in no
    /// window: its layer is put in `picture`, which First Row places among its own.
    private let surface = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 16, height: 9))
    private let picture = PictureLayer()
    private var watches = Set<AnyCancellable>()
    private var changeIsDue = false

    /// Goes up with each movie opened or let go of: what's still under way for an earlier one
    /// then knows to stop.
    private var session = 0
    private var opening: Task<Void, Never>?
    private var isOpening = false
    private var openFailure: String?
    private var wantsToPlay = false
    private var chosenSpeed: Double = 1
    private var volumeBeforeMute: Float?

    /// The place being moved to, until the engine says it's there: it's where the movie is,
    /// for anyone asking meanwhile.
    private var seekingTo: Double?
    private var isSeekRunning = false
    private var nextSeek: (seconds: Double, exactly: Bool, done: [(Bool) -> Void])?

    /// The engine's clock ticks about ten times a second. Between ticks the time is counted
    /// on from the last one, so a bar drawn from it moves evenly.
    private var tick: (time: Double, source: Double, at: CFTimeInterval) = (0, 0, 0)

    private var shownCues: [Int] = []
    private var shownCaptions: [[String: Any]] = []
    private var revision = 0

    var onChange: (() -> Void)?

    init(engine: AetherEngine) {
        self.engine = engine
        super.init()
        picture.backgroundColor = CGColor(gray: 0, alpha: 1)
        picture.masksToBounds = true
        picture.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull(), "contents": NSNull()]
        #if canImport(AppKit) && !canImport(UIKit)
            surface.wantsLayer = true
            if let layer = surface.layer { picture.addSublayer(layer) }
        #else
            picture.addSublayer(surface.layer)
        #endif
        picture.onLayout = { [weak self] in
            MainActor.assumeIsolated { self?.fitSurface() }
        }
        engine.bind(view: surface)
        watchEngine()
    }

    var pictureLayer: CALayer { picture }

    /// Keeps the engine's view the size of the layer it's shown in.
    private func fitSurface() {
        let box = picture.bounds
        guard box.width > 0, box.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if canImport(AppKit) && !canImport(UIKit)
            if surface.frame != box { surface.frame = box }
            if let layer = surface.layer, layer.frame != box { layer.frame = box }
            surface.layout()
        #else
            if surface.frame != box { surface.frame = box }
            surface.setNeedsLayout()
            surface.layoutIfNeeded()
        #endif
        CATransaction.commit()
    }

    // MARK: - What the engine says

    private func watchEngine() {
        // (A published value is told of before it changes, so what's read on being told is
        // the old one: `noteChange` has First Row read a moment later.)
        func watch<Value>(_ publisher: Published<Value>.Publisher) {
            publisher.sink { [weak self] _ in self?.noteChange() }.store(in: &watches)
        }
        watch(engine.$state)
        watch(engine.$playbackPhase)
        watch(engine.$duration)
        watch(engine.$audioTracks)
        watch(engine.$subtitleTracks)
        watch(engine.$activeAudioTrackIndex)
        watch(engine.$activeSubtitleTrackIndex)
        watch(engine.$isSubtitleActive)
        watch(engine.$mediaChapters)
        watch(engine.$discChapters)
        watch(engine.$videoFormat)
        watch(engine.$hasFirstFrameReadyForDisplay)
        watch(engine.$currentAVPlayer)
        watch(engine.$sourceVideoWidth)
        watch(engine.$softwareDisplaySize)
        engine.$subtitleCues
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCaptions(force: true) }
            }
            .store(in: &watches)
        engine.clock.$currentTime
            .sink { [weak self] time in
                guard let self else { return }
                self.tick = (time, self.tick.source, CACurrentMediaTime())
            }
            .store(in: &watches)
        engine.clock.$sourceTime
            .sink { [weak self] time in
                guard let self else { return }
                self.tick = (self.tick.time, time, CACurrentMediaTime())
            }
            .store(in: &watches)
    }

    private func noteChange() {
        guard !changeIsDue else { return }
        changeIsDue = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeIsDue = false
            self.onChange?()
        }
    }

    // MARK: - Opening and letting go

    func open(_ request: [String: Any]) {
        session += 1
        let session = session
        opening?.cancel()
        openFailure = nil
        isOpening = true
        seekingTo = nil
        nextSeek = nil
        clearCaptions()
        guard let url = request[MediaEngineKey.url] as? URL else {
            isOpening = false
            openFailure = "There is nothing to open."
            noteChange()
            return
        }
        let start = (request[MediaEngineKey.start] as? Double) ?? 0
        let paused = (request[MediaEngineKey.paused] as? Bool) ?? false
        wantsToPlay = !paused
        var options = LoadOptions()
        options.autoplay = !paused
        if let headers = request[MediaEngineKey.headers] as? [String: String], !headers.isEmpty {
            options.httpHeaders = headers
        }
        let subtitleFiles: [(url: URL, name: String?, language: String?)] = ((request[MediaEngineKey.subtitleFiles] as? [[String: Any]]) ?? []).compactMap { file in
            guard let url = file[MediaEngineKey.url] as? URL else { return nil }
            return (url, file[MediaEngineKey.name] as? String, file[MediaEngineKey.language] as? String)
        }
        let user = request[MediaEngineKey.user] as? String
        let password = request[MediaEngineKey.password] as? String
        tick = (max(0, start), 0, CACurrentMediaTime())
        noteChange()
        opening = Task { [weak self] in
            do {
                // (A subtitle file on a shared folder is fetched whole first: such files are small.)
                var tracks: [ExternalSubtitleTrack] = []
                for file in subtitleFiles {
                    var place: URL? = file.url
                    if file.url.scheme?.lowercased() == "smb" {
                        place = await SharedFolders.copy(of: file.url, user: user, password: password)
                    }
                    if let place { tracks.append(ExternalSubtitleTrack(url: place, name: file.name, language: file.language)) }
                }
                var options = options
                options.externalSubtitles = tracks
                let source = try await MediaSources.source(for: url, user: user, password: password)
                guard let self, self.session == session, !Task.isCancelled else { return }
                _ = try await self.engine.load(source: source, startPosition: start > 0.05 ? start : nil, options: options)
                guard self.session == session else { return }
                self.isOpening = false
                if self.chosenSpeed != 1 { self.engine.setRate(Float(self.chosenSpeed)) }
                self.noteChange()
            } catch is CancellationError {
                // (Another movie was opened in its place.)
            } catch {
                guard let self, self.session == session else { return }
                self.isOpening = false
                self.openFailure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self.noteChange()
            }
        }
    }

    func close() {
        session += 1
        opening?.cancel()
        opening = nil
        isOpening = false
        openFailure = nil
        wantsToPlay = false
        seekingTo = nil
        nextSeek = nil
        chosenSpeed = 1
        clearCaptions()
        engine.stop()
        noteChange()
    }

    // MARK: - Playing

    func play() {
        wantsToPlay = true
        engine.play()
        if chosenSpeed != 1 { engine.setRate(Float(chosenSpeed)) }
    }

    func pause() {
        wantsToPlay = false
        // (Where it has got to, read while it still counts as playing.)
        tick = (position, tick.source, CACurrentMediaTime())
        engine.pause()
    }

    var phase: String {
        if openFailure != nil { return "failed" }
        if isOpening { return "opening" }
        switch engine.state {
        case .idle: return "idle"
        case .loading: return "opening"
        case .playing: return "playing"
        case .paused: return "paused"
        case .seeking: return wantsToPlay ? "playing" : "paused"
        case .ended: return "ended"
        case .error: return "failed"
        }
    }

    var isWaiting: Bool {
        guard openFailure == nil else { return false }
        if isOpening { return wantsToPlay }
        switch engine.playbackPhase {
        case .loading, .rebuffering, .stalled: return wantsToPlay
        case .seeking: return wantsToPlay && seekingTo == nil
        default: return false
        }
    }

    var failure: String? {
        if let openFailure { return openFailure }
        if case let .error(message) = engine.state { return message }
        return nil
    }

    var hasPicture: Bool { engine.hasFirstFrameReadyForDisplay }

    var position: Double {
        if let seekingTo { return seekingTo }
        var time = tick.time
        if engine.state == .playing, !engine.isBuffering {
            time += min(0.25, max(0, CACurrentMediaTime() - tick.at)) * chosenSpeed
        }
        let length = engine.duration
        if length > 0 { time = min(time, length) }
        return max(0, time)
    }

    var duration: Double {
        let length = engine.duration
        return length.isFinite && length > 0 ? length : 0
    }

    func seek(to seconds: Double, exactly: Bool, then done: ((Bool) -> Void)?) {
        let target = max(0, seconds)
        seekingTo = target
        var waiting = nextSeek?.done ?? []
        if let done { waiting.append(done) }
        nextSeek = (target, exactly, waiting)
        runNextSeek()
    }

    /// One move at a time: a scrub asks for a new place thirty times a second, and each is
    /// replaced by the next while the engine is still on its way to an earlier one.
    private func runNextSeek() {
        guard !isSeekRunning, let next = nextSeek else { return }
        nextSeek = nil
        isSeekRunning = true
        let session = session
        Task { [weak self] in
            guard let self else { return }
            await self.engine.seek(to: next.seconds, exact: next.exactly)
            self.isSeekRunning = false
            guard self.session == session else {
                next.done.forEach { $0(false) }
                return
            }
            if self.nextSeek == nil {
                self.tick = (next.seconds, self.tick.source, CACurrentMediaTime())
                self.seekingTo = nil
            }
            next.done.forEach { $0(true) }
            self.runNextSeek()
        }
    }

    var speed: Double {
        get { chosenSpeed }
        set {
            chosenSpeed = min(max(newValue, 0.25), Double(engine.maxSupportedRate))
            tick = (position, tick.source, CACurrentMediaTime())
            engine.setRate(Float(chosenSpeed))
        }
    }

    var isMuted: Bool {
        get { volumeBeforeMute != nil }
        set {
            if newValue, volumeBeforeMute == nil {
                volumeBeforeMute = engine.volume
                engine.volume = 0
            } else if !newValue, let volume = volumeBeforeMute {
                volumeBeforeMute = nil
                engine.volume = volume
            }
        }
    }

    // MARK: - Tracks and chapters

    var audioTracks: [[String: Any]] {
        let chosen = engine.activeAudioTrackIndex
        return engine.audioTracks.map { track in
            var entry = Self.entry(for: track)
            entry[MediaEngineKey.isChosen] = track.id == chosen
            return entry
        }
    }

    var subtitleTracks: [[String: Any]] {
        let chosen = engine.isSubtitleActive ? engine.activeSubtitleTrackIndex : nil
        return engine.subtitleTracks.map { track in
            var entry = Self.entry(for: track)
            entry[MediaEngineKey.isChosen] = track.id == chosen
            return entry
        }
    }

    private static func entry(for track: TrackInfo) -> [String: Any] {
        var entry: [String: Any] = [
            MediaEngineKey.id: track.id,
            MediaEngineKey.name: track.name,
            MediaEngineKey.codec: track.codec,
            MediaEngineKey.channels: track.channels,
            MediaEngineKey.isForced: track.isForced,
        ]
        if let language = track.language { entry[MediaEngineKey.language] = language }
        return entry
    }

    func chooseAudioTrack(_ id: Int) {
        guard engine.audioTracks.contains(where: { $0.id == id }), engine.activeAudioTrackIndex != id else { return }
        engine.selectAudioTrack(index: id)
    }

    func chooseSubtitleTrack(_ id: Int) {
        if id < 0 {
            engine.clearSubtitle()
            clearCaptions()
        } else if engine.subtitleTracks.contains(where: { $0.id == id }) {
            engine.selectSubtitleTrack(index: id)
        }
    }

    var chapters: [[String: Any]] {
        let found = engine.discChapters.isEmpty ? engine.mediaChapters : engine.discChapters
        return found.map { [MediaEngineKey.title: $0.name, MediaEngineKey.start: $0.startSeconds] }
    }

    // MARK: - Subtitles

    var captions: [[String: Any]] { shownCaptions }

    /// (Asked for as often as First Row draws, which is what keeps the subtitles to their
    /// times: the engine's own clock ticks only ten times a second.)
    var captionsRevision: Int {
        refreshCaptions(force: false)
        return revision
    }

    private func clearCaptions() {
        guard !shownCues.isEmpty || !shownCaptions.isEmpty else { return }
        shownCues = []
        shownCaptions = []
        revision += 1
    }

    /// Works out which subtitles show at a time on the movie's own clock (the last the engine
    /// told of, counted on from then while it plays).
    private func refreshCaptions(force: Bool) {
        guard engine.isSubtitleActive else {
            clearCaptions()
            return
        }
        var now = tick.source
        if engine.state == .playing, !engine.isBuffering {
            now += min(0.25, max(0, CACurrentMediaTime() - tick.at)) * chosenSpeed
        }
        let showing = engine.subtitleCues.filter { $0.startTime <= now && now < $0.endTime }
        let ids = showing.map(\.id)
        guard force || ids != shownCues else { return }
        shownCues = ids
        shownCaptions = showing.map(Self.caption)
        revision += 1
    }

    private static func caption(for cue: SubtitleCue) -> [String: Any] {
        var entry: [String: Any] = [:]
        switch cue.body {
        case let .text(text):
            entry[MediaEngineKey.text] = text
        case let .richText(runs):
            entry[MediaEngineKey.text] = runs.map(\.text).joined()
            entry[MediaEngineKey.runs] = runs.map { run -> [String: Any] in
                var piece: [String: Any] = [MediaEngineKey.text: run.text]
                if run.isBold { piece[MediaEngineKey.isBold] = true }
                if run.isItalic { piece[MediaEngineKey.isItalic] = true }
                if run.isUnderlined { piece[MediaEngineKey.isUnderlined] = true }
                if let color = run.color {
                    piece[MediaEngineKey.color] = Int(color.r) << 24 | Int(color.g) << 16 | Int(color.b) << 8 | 0xFF
                }
                return piece
            }
        case let .image(image):
            entry[MediaEngineKey.image] = image.cgImage
            entry[MediaEngineKey.x] = Double(image.position.minX)
            entry[MediaEngineKey.y] = Double(image.position.minY)
            entry[MediaEngineKey.width] = Double(image.position.width)
            entry[MediaEngineKey.height] = Double(image.position.height)
            entry[MediaEngineKey.canvasWidth] = Double(image.canvasSize.width)
            entry[MediaEngineKey.canvasHeight] = Double(image.canvasSize.height)
        }
        if let alignment = cue.placement?.alignment { entry[MediaEngineKey.alignment] = alignment }
        return entry
    }

    // MARK: - The picture

    var pictureKind: String {
        switch engine.videoFormat {
        case .sdr: "sdr"
        case .hdr10: "hdr10"
        case .hdr10Plus: "hdr10+"
        case .dolbyVision: "dolbyvision"
        case .hlg: "hlg"
        }
    }

    var pictureSize: CGSize {
        if let shown = engine.softwareDisplaySize, shown.width > 0, shown.height > 0 { return shown }
        let width = Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio
        let height = Double(engine.sourceVideoHeight)
        return width > 0 && height > 0 ? CGSize(width: width, height: height) : .zero
    }

    var systemPlayer: AVPlayer? { engine.currentAVPlayer }
}
