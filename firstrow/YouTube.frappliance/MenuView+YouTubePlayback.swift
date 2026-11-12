import AVFoundation
import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif
#if !FIRSTROW_PORTABLE
    import VideoToolbox
#endif

/// A YouTube video in the movie player.
struct YouTubePlaybackSession {
    var video: YouTubeVideo
    var playback: YouTubePlayback
    /// What the movie player was given to play.
    var url: URL
    /// The sizes its picture comes in, largest first, once they're known, and the playlist
    /// that names them.
    var variants: [YouTubeStreamVariant] = []
    var manifestText: String?
    /// The sounds the video comes with (the one it was made with first), and the one chosen
    /// in the options; none chosen plays the first.
    var audioTracks: [YouTubeAudioTrack] = []
    var audioTrackID: String?
    var hasStarted = false
    /// The caption track that's on (an index into the video's tracks) and its lines.
    var captionTrack: Int?
    var cues: [YouTubeCaptionCue] = []
    var captionRequestID = 0
    /// The size the video started at with none asked for (nil when one was, and for mpv,
    /// which is given one size and stays at it): how it plays against that is what the next
    /// video's start is learned from.
    var startHeight: Int?
}

#if !FIRSTROW_PORTABLE
    /// Gives the system's player a YouTube video's playlist as First Row has put it, under an
    /// address of First Row's own, and answers when the player asks for what is at that
    /// address. Handed the video's own playlist the player starts small and works up; it is
    /// handed one with only one size's streams left in (a size that was asked for), or with
    /// the size to start at first (see `YouTubeClient.playlist(_:startingAtHeight:)`). (The
    /// streams the playlist names are at YouTube's own addresses, which the player fetches
    /// as ever.)
    final class YouTubePlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        static let shared = YouTubePlaylistLoader()
        private static let scheme = "firstrow-youtube"
        private let lock = NSLock()
        private var playlists: [String: Data] = [:]
        private let queue = DispatchQueue(label: "firstrow.youtube.playlists")

        /// Keeps a playlist, and gives the address the player is to ask for it by.
        func address(for playlist: String, videoID: String, name: String) -> URL? {
            guard let url = URL(string: "\(Self.scheme)://playlist/\(videoID)/\(name).m3u8") else { return nil }
            lock.lock()
            // (Only the video being played, and the one before it, have any use for theirs.)
            if playlists.count > 16 { playlists.removeAll() }
            playlists[url.path] = Data(playlist.utf8)
            lock.unlock()
            return url
        }

        /// What the player plays for one of those addresses (nil for any other).
        func playerItem(for url: URL) -> AVPlayerItem? {
            guard url.scheme == Self.scheme else { return nil }
            let asset = AVURLAsset(url: url)
            asset.resourceLoader.setDelegate(self, queue: queue)
            let item = AVPlayerItem(asset: asset)
            // (The playlist's first stream is the one to start on: left to itself the player
            // starts on a small one and works up.)
            if #available(macOS 11.0, iOS 14.0, tvOS 14.0, *) { item.startsOnFirstEligibleVariant = true }
            return item
        }

        func resourceLoader(_: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            guard let url = loadingRequest.request.url, url.scheme == Self.scheme else { return false }
            lock.lock()
            let playlist = playlists[url.path]
            lock.unlock()
            guard let playlist else {
                loadingRequest.finishLoading(with: URLError(.fileDoesNotExist))
                return true
            }
            loadingRequest.dataRequest?.respond(with: playlist)
            loadingRequest.finishLoading()
            return true
        }
    }

    /// Videos above 1080p come as VP9 only, which the system plays once it's asked to.
    private enum YouTubeDecoders {
        static let prepared: Void = {
            #if os(macOS)
                if #available(macOS 11.0, *) {
                    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
                }
            #else
                if #available(iOS 26.2, tvOS 26.2, *) {
                    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
                }
            #endif
        }()
    }
#endif

/// Playing YouTube videos through the movie player.
extension MenuView {
    /// The sizes offered for a video's picture, in lines.
    static let youtubeHeights = [2160, 1440, 1080, 720, 480, 360, 240, 144]

    /// `seconds` is where it starts from (a video gone back to). `then` is told whether it
    /// came up, once it's over the menus (or once it's known that it won't be).
    func playYouTubeVideo(_ video: YouTubeVideo, from seconds: Double = 0, then: (@MainActor (Bool) -> Void)? = nil) {
        guard !isMovieTransitioning, !isMoviePlaybackVisible, !youtube.isStartingPlayback else { return }
        youtube.isStartingPlayback = true
        playSound(named: "Selection")
        resetScreenSaverIdleTimer()
        Task { @MainActor in
            defer { self.youtube.isStartingPlayback = false }
            do {
                let playback = try await YouTubeClient.shared.playback(of: video.id)
                let (url, variants, manifestText, startHeight, audioTracks) = try await self.youtubePlayerURL(for: playback, videoID: video.id, maximumHeight: YouTubeStore.shared.maximumHeight)
                guard self.thirdMenuMode == .youtube, !self.isMovieTransitioning, !self.isMoviePlaybackVisible else {
                    then?(false)
                    return
                }
                self.youtubeSession = YouTubePlaybackSession(video: video, playback: playback, url: url, variants: variants, manifestText: manifestText, audioTracks: audioTracks, startHeight: startHeight)
                // (Nothing to resume: what YouTube hands out to play is good for a few hours.)
                self.lastClosedMovieURL = nil
                self.lastClosedMovieTimestamp = 0
                self.removeCurrentMoviePlaybackTemporaryFileIfNeeded()
                self.isCurrentMoviePlaybackEphemeralPreview = true
                self.startMoviePlaybackWithStandardTransition(from: url, startSeconds: playback.isLive ? 0 : seconds)
                if let then {
                    Task { @MainActor in
                        for _ in 0 ..< 100 where self.isMovieTransitioning {
                            try? await firstRowSleep(0.05)
                        }
                        then(self.isMoviePlaybackVisible)
                    }
                }
            } catch {
                then?(false)
                guard self.thirdMenuMode == .youtube, !self.isMoviePlaybackVisible else { return }
                self.playSound(named: "Limit")
                var reason = error.localizedDescription
                if !reason.hasSuffix(".") { reason += "." }
                self.presentFullscreenScene(key: self.featureErrorFullscreenKey, payload: [
                    "header": "This video can't be played.",
                    "subcaption": reason,
                ])
            }
        }
    }

    /// What the movie player plays a video from, the sizes its picture comes in (with the
    /// playlist that names them) when they had to be looked up, and the size it starts at
    /// when that was First Row's choice and may change as it plays.
    private func youtubePlayerURL(for playback: YouTubePlayback, videoID: String, maximumHeight: Int?) async throws -> (URL, [YouTubeStreamVariant], String?, Int?, [YouTubeAudioTrack]) {
        #if FIRSTROW_PORTABLE
            // mpv is given one size of the picture and its sound, by their own addresses: left
            // to read the whole playlist, it opens all seventeen sizes before it starts. (The
            // sound is the one the video was made with, until another is chosen.)
            let manifest = try? await YouTubeClient.shared.manifest(of: playback.manifestURL)
            let variants = manifest?.variants ?? []
            let audioTracks = manifest.map { YouTubeClient.audioTracks(inPlaylist: $0.text) } ?? []
            let limit = maximumHeight ?? Self.youtubeHeightSuitingTheScreen
            if !playback.isLive, let chosen = Self.youtubeVariant(in: variants, maximumHeight: limit),
               let url = AVPlayer.pairedStreamsURL(video: chosen.url, audio: chosen.audioURL)
            {
                return (url, variants, nil, nil, audioTracks)
            }
            return (playback.manifestURL, variants, nil, nil, [])
        #else
            _ = YouTubeDecoders.prepared
            // A size that was asked for is played as that size. With none asked for the
            // player has every size, the one to start at first: the largest that suits the
            // screen, or the size videos have lately held.
            if !playback.isLive, let manifest = try? await YouTubeClient.shared.manifest(of: playback.manifestURL) {
                // (Of a video's sounds the player is given the one it was made with: left to
                // choose, it took the first named, which can be the picture described.)
                let audioTracks = YouTubeClient.audioTracks(inPlaylist: manifest.text)
                if let address = Self.youtubeAddress(
                    forHeight: maximumHeight, videoID: videoID, manifestText: manifest.text, variants: manifest.variants,
                    audio: audioTracks.count > 1 ? audioTracks[0].id : nil,
                ) {
                    return (address.url, manifest.variants, manifest.text, address.startHeight, audioTracks)
                }
            }
            return (playback.manifestURL, [], nil, nil, [])
        #endif
    }

    /// The sizes a video's picture can be asked for in.
    private static func youtubePictureHeights(in variants: [YouTubeStreamVariant]) -> Set<Int> {
        Set(variants.filter { !$0.isHighDynamicRange && $0.audioURL != nil && $0.height >= 144 }.map(\.height))
    }

    #if !FIRSTROW_PORTABLE
        /// The address the system's player is given for a video: for one size of its picture
        /// (the largest the video has that is no taller than `limit`), or with no limit for
        /// every size, starting at `startHeight`.
        private static func youtubeAddress(forHeight limit: Int?, videoID: String, manifestText: String, variants: [YouTubeStreamVariant], audio: String?) -> (url: URL, startHeight: Int?)? {
            let heights = youtubePictureHeights(in: variants)
            guard let smallest = heights.min() else { return nil }
            // With one of the video's sounds only, where it has several (`audio` names it).
            let manifestText = audio.map { YouTubeClient.playlist(manifestText, keepingAudio: $0) } ?? manifestText
            let sound = audio.map { "-" + $0.filter { $0.isLetter || $0.isNumber } } ?? ""
            if let limit {
                guard let height = heights.filter({ $0 <= max(limit, smallest) }).max(),
                      let playlist = YouTubeClient.playlist(manifestText, keepingHeight: height),
                      let url = YouTubePlaylistLoader.shared.address(for: playlist, videoID: videoID, name: String(height) + sound) else { return nil }
                return (url, nil)
            }
            let suited = youtubeHeightSuitingTheScreen
            let wanted = min(suited, YouTubeStore.shared.startingHeight ?? suited)
            let start = heights.filter { $0 <= wanted }.max() ?? smallest
            guard let playlist = YouTubeClient.playlist(manifestText, startingAtHeight: start),
                  let url = YouTubePlaylistLoader.shared.address(for: playlist, videoID: videoID, name: "from-\(start)" + sound) else { return nil }
            return (url, start)
        }
    #endif

    /// The largest size within the limit; of the kinds of picture at that size, the commonest
    /// (H.264, which every machine decodes without effort) if there is one, at the most frames
    /// a second.
    static func youtubeVariant(in variants: [YouTubeStreamVariant], maximumHeight: Int) -> YouTubeStreamVariant? {
        let usable = variants.filter { !$0.isHighDynamicRange && $0.audioURL != nil }
        guard let smallest = usable.map(\.height).min() else { return nil }
        let limit = max(maximumHeight, smallest)
        guard let height = usable.map(\.height).filter({ $0 <= limit }).max() else { return nil }
        return usable.filter { $0.height == height }.max { a, b in
            (a.framesPerSecond, a.codec.hasPrefix("avc1") ? 1 : 0, a.bandwidth) < (b.framesPerSecond, b.codec.hasPrefix("avc1") ? 1 : 0, b.bandwidth)
        }
    }

    /// The size of picture that fills the window First Row has, and no more.
    static var youtubeHeightSuitingTheScreen: Int {
        let lines = Int((1080 * DisplayArtworkSize.pixelsPerPoint).rounded())
        return youtubeHeights.reversed().first { $0 >= lines - 40 } ?? 2160
    }

    /// Called as the movie player starts a URL.
    func youtubeMoviePlaybackDidActivate(url: URL) {
        guard var session = youtubeSession else { return }
        guard session.url.standardizedFileURL == url.standardizedFileURL else {
            youtubeSession = nil
            return
        }
        guard !session.hasStarted else { return }
        session.hasStarted = true
        youtubeSession = session
        YouTubeStore.shared.noteWatched(session.video)
        #if !FIRSTROW_PORTABLE
            // Captions are First Row's to draw (see `selectYouTubeCaptions`): the player isn't
            // to turn the playlist's own on as well.
            moviePlayer?.appliesMediaSelectionCriteriaAutomatically = false
            watchYouTubePictureSize()
        #endif
        loadYouTubeVideoExtras()
    }

    /// Called as the movie player stops.
    func youtubeMoviePlaybackWillEnd() {
        guard youtubeSession != nil else { return }
        youtubeSession = nil
        youtubeStreamReloadTask?.cancel()
        youtubeStreamReloadTask = nil
        youtubeSizeWatchTask?.cancel()
        youtubeSizeWatchTask = nil
        youtubePanel = nil
        youtubePanelReveal = 0
        spreadYouTubePanel(to: 0, nil)
        // (The list under the player shows again: its rows' pictures, if they've gone since.)
        youtubeListAppeared()
        // The history has this video at its top now.
        if thirdMenuMode == .youtube, let index = youtube.pages.indices.last, case .history = youtube.pages[index].page {
            youtube.pages[index].videos = YouTubeStore.shared.history
            selectedThirdIndex = 0
            clearYouTubePreviewAfterPlayback()
        }
    }

    private func clearYouTubePreviewAfterPlayback() {
        youtube.previewVideoID = nil
        refreshDetailPreviewForCurrentContext()
    }
}

// MARK: - A video's options: captions, picture size, what it is, comments

extension MenuView {
    /// What a YouTube video offers in the movie's options.
    func youtubeOptionKinds() -> [MovieOptionRow.Kind] {
        guard let session = youtubeSession else { return [.speed] }
        var kinds: [MovieOptionRow.Kind] = []
        if !session.playback.captions.isEmpty { kinds.append(.subtitles) }
        if !youtubeOfferedHeights(session).isEmpty { kinds.append(.quality) }
        if session.audioTracks.count > 1 { kinds.append(.audio) }
        kinds.append(.speed)
        kinds.append(.info)
        kinds.append(.comments)
        return kinds
    }

    /// The sizes the video's picture comes in, largest first.
    private func youtubeOfferedHeights(_ session: YouTubePlaybackSession) -> [Int] {
        guard !session.playback.isLive else { return [] }
        return Self.youtubePictureHeights(in: session.variants).sorted(by: >)
    }

    /// Fills the options panel's rows for a YouTube video.
    func loadYouTubeOptionRows() {
        guard var state = movieOptions, let session = youtubeSession else { return }
        var rows: [MovieOptionRow] = []
        let tracks = session.playback.captions
        if !tracks.isEmpty {
            state.captionTracks = [nil] + tracks.indices.map { $0 }
            rows.append(MovieOptionRow(kind: .subtitles, title: "Subtitles", values: ["Off"] + tracks.map(\.name), selected: session.captionTrack.map { $0 + 1 } ?? 0))
        }
        let heights = youtubeOfferedHeights(session)
        if !heights.isEmpty {
            state.pictureHeights = [nil] + heights
            let chosen = YouTubeStore.shared.maximumHeight.flatMap { limit in heights.firstIndex { $0 <= limit } }
            rows.append(MovieOptionRow(kind: .quality, title: "Quality", values: ["Auto"] + heights.map { "\($0)p" }, selected: chosen.map { $0 + 1 } ?? 0))
        }
        // The video's sounds, where it has more than its own: the picture described, a dubbing.
        if session.audioTracks.count > 1 {
            let chosen = session.audioTracks.firstIndex { $0.id == session.audioTrackID } ?? 0
            rows.append(MovieOptionRow(kind: .audio, title: "Audio", values: session.audioTracks.map(\.name), selected: chosen))
        }
        rows += state.rows.filter { $0.kind == .speed }
        rows.append(MovieOptionRow(kind: .info, title: "Info", values: ["View"], selected: 0, opensMore: true))
        rows.append(MovieOptionRow(kind: .comments, title: "Comments", values: ["View"], selected: 0, opensMore: true))
        let focusedKind = state.preferredKind ?? (state.rows.indices.contains(state.focusedRow) ? state.rows[state.focusedRow].kind : .speed)
        state.rows = rows
        state.focusedRow = state.hasMoved ? (rows.firstIndex { $0.kind == focusedKind } ?? 0) : 0
        state.preferredKind = nil
        movieOptions = state
        let kinds = rows.map(\.kind)
        if kinds != movieOptionKinds { movieOptionKinds = kinds }
    }

    /// Finds out what the options need to know about the video that started: the sizes of
    /// its picture.
    func loadYouTubeVideoExtras() {
        guard let session = youtubeSession else { return }
        let videoID = session.video.id
        func update(_ change: (inout YouTubePlaybackSession) -> Void) {
            guard var current = youtubeSession, current.video.id == videoID else { return }
            change(&current)
            youtubeSession = current
            if movieOptions != nil { loadYouTubeOptionRows() } else if let player = moviePlayer { probeMovieOptionKinds(player) }
        }
        if session.variants.isEmpty {
            Task { @MainActor in
                guard let manifest = try? await YouTubeClient.shared.manifest(of: session.playback.manifestURL), !manifest.variants.isEmpty else { return }
                update {
                    $0.variants = manifest.variants
                    $0.manifestText = manifest.text
                    $0.audioTracks = YouTubeClient.audioTracks(inPlaylist: manifest.text)
                }
            }
        }
    }

    // MARK: Captions

    /// The caption line for where the video is now.
    var youtubeCaptionText: String? {
        guard let session = youtubeSession, session.captionTrack != nil, !session.cues.isEmpty else { return nil }
        let time = moviePlaybackCurrentSeconds
        var low = 0
        var high = session.cues.count - 1
        var found = -1
        while low <= high {
            let middle = (low + high) / 2
            if session.cues[middle].start <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard found >= 0, session.cues[found].end > time else { return nil }
        return session.cues[found].text
    }

    /// Turns captions on in one of the video's tracks, or off (nil).
    func selectYouTubeCaptions(_ track: Int?) {
        guard var session = youtubeSession else { return }
        session.captionTrack = track
        session.cues = []
        session.captionRequestID &+= 1
        let requestID = session.captionRequestID
        youtubeSession = session
        guard let track, session.playback.captions.indices.contains(track) else { return }
        let chosen = session.playback.captions[track]
        let videoID = session.video.id
        Task { @MainActor in
            let cues = try? await YouTubeClient.shared.cues(of: chosen)
            guard var current = self.youtubeSession, current.video.id == videoID, current.captionRequestID == requestID else { return }
            if let cues, !cues.isEmpty {
                current.cues = cues
            } else {
                // (None to show: the row goes back to Off.)
                current.captionTrack = nil
                self.playSound(named: "Limit")
            }
            self.youtubeSession = current
            if self.movieOptions != nil { self.loadYouTubeOptionRows() }
        }
    }

    // MARK: Picture size

    /// Keeps to a size of picture from now on (nil: whatever suits), this video included.
    func setYouTubeMaximumHeight(_ height: Int?) {
        YouTubeStore.shared.setMaximumHeight(height)
        // Once the choice has rested a moment: stepping through the sizes to reach one would
        // otherwise start, and drop, the playing of each on the way.
        youtubeStreamReloadTask?.cancel()
        youtubeStreamReloadTask = Task { @MainActor in
            try? await firstRowSleep(0.6)
            guard !Task.isCancelled else { return }
            await self.reloadYouTubeStream()
        }
    }

    /// Plays the video with another of its sounds (a row of the options' Audio), from where it is.
    func setYouTubeAudioTrack(_ index: Int) {
        guard var session = youtubeSession, session.audioTracks.indices.contains(index) else { return }
        let id = session.audioTracks[index].id
        guard id != (session.audioTrackID ?? session.audioTracks[0].id) else { return }
        session.audioTrackID = id
        youtubeSession = session
        // (Once the choice has rested a moment, as with the picture's size.)
        youtubeStreamReloadTask?.cancel()
        youtubeStreamReloadTask = Task { @MainActor in
            try? await firstRowSleep(0.6)
            guard !Task.isCancelled else { return }
            await self.reloadYouTubeStream()
        }
    }

    /// Has the player stop and play on from where it was at the size of picture, and with
    /// the sound, now asked for. (Left to change size as it went, it would first play out
    /// what it had already fetched at the old one.)
    private func reloadYouTubeStream() async {
        guard var session = youtubeSession, let player = moviePlayer, !session.playback.isLive else { return }
        #if FIRSTROW_PORTABLE
            let limit = YouTubeStore.shared.maximumHeight ?? Self.youtubeHeightSuitingTheScreen
            guard let chosen = Self.youtubeVariant(in: session.variants, maximumHeight: limit),
                  let url = AVPlayer.pairedStreamsURL(video: chosen.url, audio: session.audioTrackID.flatMap { chosen.audioURLs[$0] } ?? chosen.audioURL), url != session.url
            else { return }
            let item = AVPlayerItem(url: url)
        #else
            if session.manifestText == nil {
                // (Asked for before the video's sizes had been looked up.)
                let videoID = session.video.id
                guard let manifest = try? await YouTubeClient.shared.manifest(of: session.playback.manifestURL),
                      var current = youtubeSession, current.video.id == videoID, moviePlayer === player, !Task.isCancelled else { return }
                current.variants = manifest.variants
                current.manifestText = manifest.text
                current.audioTracks = YouTubeClient.audioTracks(inPlaylist: manifest.text)
                youtubeSession = current
                session = current
            }
            guard let text = session.manifestText,
                  let address = Self.youtubeAddress(
                      forHeight: YouTubeStore.shared.maximumHeight, videoID: session.video.id, manifestText: text, variants: session.variants,
                      audio: session.audioTracks.count > 1 ? (session.audioTrackID ?? session.audioTracks[0].id) : nil,
                  )
            else { return }
            let url = address.url
            guard url != session.url else { return }
            session.startHeight = address.startHeight
            youtubeSizeWatch = YouTubeSizeWatch()
            let item = YouTubePlaylistLoader.shared.playerItem(for: url) ?? AVPlayerItem(url: url)
        #endif
        let time = player.currentTime()
        let wasPlaying = player.rate > 0.01
        session.url = url
        youtubeSession = session
        currentMoviePlaybackURL = url.standardizedFileURL
        // The player isn't asked where it is until it's back where it was (for a moment it
        // says the start): the bar stays put while the picture comes back.
        removeMoviePlaybackObservation()
        player.replaceCurrentItem(with: item)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.moviePlayer === player, player.currentItem === item else { return }
                // (Watching the player again starts the options and the speed afresh.)
                let options = self.movieOptions
                let speed = self.movieSpeed
                let duration = self.moviePlaybackDurationSeconds
                self.configureMoviePlaybackObservation(for: player)
                self.moviePlaybackDurationSeconds = max(duration, self.moviePlaybackDurationSeconds)
                self.movieOptions = options
                self.movieSpeed = speed
            }
        }
        if wasPlaying {
            player.play()
            if movieSpeed != 1 { applyMovieSpeed(player) }
        }
    }
}

/// How long a video has shown each size of its picture, while it played with no size asked for.
struct YouTubeSizeWatch {
    var seconds: [Int: Double] = [:]
    /// Where the video was at the last look, to tell a jump from playing on.
    var lastPosition: Double?
    /// No looks count until then: after a jump the player shows a small size for a moment.
    var settlesAt = Date.distantPast
}

#if !FIRSTROW_PORTABLE
    // MARK: - Learning the size to start at

    extension MenuView {
        private static let youtubeSizeWatchInterval = 2.0

        /// Looks every two seconds at the size the player is showing, while a video plays
        /// with no size asked for, and learns from it where the next video should start.
        func watchYouTubePictureSize() {
            youtubeSizeWatchTask?.cancel()
            youtubeSizeWatch = YouTubeSizeWatch()
            youtubeSizeWatchTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await firstRowSleep(Self.youtubeSizeWatchInterval)
                    guard !Task.isCancelled, let session = self.youtubeSession, let player = self.moviePlayer else { return }
                    self.noteYouTubePictureSize(session: session, player: player)
                }
            }
        }

        private func noteYouTubePictureSize(session: YouTubePlaybackSession, player: AVPlayer) {
            guard let start = session.startHeight, YouTubeStore.shared.maximumHeight == nil else { return }
            let position = player.currentTime().seconds
            defer { youtubeSizeWatch.lastPosition = position }
            // Only steady playing at its own speed says anything about the connection.
            guard player.timeControlStatus == .playing, abs(player.rate - 1) < 0.05, movieScrubDirection == 0, position.isFinite else { return }
            if let last = youtubeSizeWatch.lastPosition, abs(position - last - Self.youtubeSizeWatchInterval) > 3 {
                youtubeSizeWatch.settlesAt = Date().addingTimeInterval(8)
                return
            }
            guard Date() >= youtubeSizeWatch.settlesAt, let size = player.currentItem?.presentationSize, size.width > 1, size.height > 1 else { return }
            // (A size as the playlist names it: the picture's shorter side.)
            let shown = Int(min(size.width, size.height).rounded())
            let heights = Self.youtubePictureHeights(in: session.variants).sorted(by: >)
            guard let height = heights.min(by: { abs($0 - shown) < abs($1 - shown) }) else { return }
            youtubeSizeWatch.seconds[height, default: 0] += Self.youtubeSizeWatchInterval
            if let learned = Self.youtubeStartingHeight(learnedFrom: youtubeSizeWatch.seconds, start: start, heights: heights) {
                // (As large as suits this screen is no limit at all: a larger screen starts at its own.)
                YouTubeStore.shared.setStartingHeight(learned >= Self.youtubeHeightSuitingTheScreen ? nil : learned)
            }
        }

        /// Where the next video should start, going by how long this one showed each size
        /// (`heights` largest first), having started at `start`; nil for no change. Lower,
        /// when it came down from where it started and stayed down: at the size it spent
        /// longest at. Higher, when it held a larger size for most of a minute or more.
        static func youtubeStartingHeight(learnedFrom seconds: [Int: Double], start: Int, heights: [Int]) -> Int? {
            let total = seconds.values.reduce(0, +)
            guard total >= 30 else { return nil }
            let below = seconds.filter { $0.key < start }
            let belowTotal = below.values.reduce(0, +)
            if belowTotal >= 20, belowTotal >= total * 0.25 {
                return below.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
            }
            let ceiling = youtubeHeightSuitingTheScreen
            var held = 0.0
            for height in heights where height > start {
                held += seconds[height] ?? 0
                if held >= 60, held >= total * 0.6 { return min(height, ceiling) }
            }
            return nil
        }
    }
#endif
