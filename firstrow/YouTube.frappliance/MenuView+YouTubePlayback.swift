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
    var hasStarted = false
    /// The caption track that's on (an index into the video's tracks) and its lines.
    var captionTrack: Int?
    var cues: [YouTubeCaptionCue] = []
    var captionRequestID = 0
}

#if !FIRSTROW_PORTABLE
    /// Gives the system's player a YouTube video at one size of picture. Handed the video's
    /// whole playlist the player picks sizes for itself as it goes; for a size that was asked
    /// for it is handed the playlist with only that size's streams left in, under an address
    /// of First Row's own, and asks here for what is at that address. (The streams the
    /// playlist names are at YouTube's own addresses, which the player fetches as ever.)
    final class YouTubePlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        static let shared = YouTubePlaylistLoader()
        private static let scheme = "firstrow-youtube"
        private let lock = NSLock()
        private var playlists: [String: Data] = [:]
        private let queue = DispatchQueue(label: "firstrow.youtube.playlists")

        /// Keeps a playlist, and gives the address the player is to ask for it by.
        func address(for playlist: String, videoID: String, height: Int) -> URL? {
            guard let url = URL(string: "\(Self.scheme)://playlist/\(videoID)/\(height).m3u8") else { return nil }
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
            return AVPlayerItem(asset: asset)
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

    func playYouTubeVideo(_ video: YouTubeVideo) {
        guard !isMovieTransitioning, !isMoviePlaybackVisible, !youtube.isStartingPlayback else { return }
        youtube.isStartingPlayback = true
        playSound(named: "Selection")
        resetScreenSaverIdleTimer()
        Task { @MainActor in
            defer { self.youtube.isStartingPlayback = false }
            do {
                let playback = try await YouTubeClient.shared.playback(of: video.id)
                let (url, variants, manifestText) = try await self.youtubePlayerURL(for: playback, videoID: video.id, maximumHeight: YouTubeStore.shared.maximumHeight)
                guard self.thirdMenuMode == .youtube, !self.isMovieTransitioning, !self.isMoviePlaybackVisible else { return }
                self.youtubeSession = YouTubePlaybackSession(video: video, playback: playback, url: url, variants: variants, manifestText: manifestText)
                // (Nothing to resume: what YouTube hands out to play is good for a few hours.)
                self.lastClosedMovieURL = nil
                self.lastClosedMovieTimestamp = 0
                self.removeCurrentMoviePlaybackTemporaryFileIfNeeded()
                self.isCurrentMoviePlaybackEphemeralPreview = true
                self.startMoviePlaybackWithStandardTransition(from: url)
            } catch {
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

    /// What the movie player plays a video from, and the sizes its picture comes in (with
    /// the playlist that names them) when they had to be looked up to choose one.
    private func youtubePlayerURL(for playback: YouTubePlayback, videoID: String, maximumHeight: Int?) async throws -> (URL, [YouTubeStreamVariant], String?) {
        #if FIRSTROW_PORTABLE
            // mpv is given one size of the picture and its sound, by their own addresses: left
            // to read the whole playlist, it opens all seventeen sizes before it starts.
            let variants = (try? await YouTubeClient.shared.variants(of: playback.manifestURL)) ?? []
            let limit = maximumHeight ?? Self.youtubeHeightSuitingTheScreen
            if !playback.isLive, let chosen = Self.youtubeVariant(in: variants, maximumHeight: limit),
               let url = AVPlayer.pairedStreamsURL(video: chosen.url, audio: chosen.audioURL)
            {
                return (url, variants, nil)
            }
            return (playback.manifestURL, variants, nil)
        #else
            _ = YouTubeDecoders.prepared
            // With no size asked for the player has the whole playlist, to pick from as it
            // goes; a size that was asked for is played as that size.
            if let maximumHeight, !playback.isLive,
               let manifest = try? await YouTubeClient.shared.manifest(of: playback.manifestURL),
               let url = Self.youtubeAddress(forHeight: maximumHeight, videoID: videoID, manifestText: manifest.text, variants: manifest.variants)
            {
                return (url, manifest.variants, manifest.text)
            }
            return (playback.manifestURL, [], nil)
        #endif
    }

    /// The sizes a video's picture can be asked for in.
    private static func youtubePictureHeights(in variants: [YouTubeStreamVariant]) -> Set<Int> {
        Set(variants.filter { !$0.isHighDynamicRange && $0.audioURL != nil && $0.height >= 144 }.map(\.height))
    }

    #if !FIRSTROW_PORTABLE
        /// The address the system's player is given for one size of a video's picture: the
        /// largest the video has that is no taller than `limit`.
        private static func youtubeAddress(forHeight limit: Int, videoID: String, manifestText: String, variants: [YouTubeStreamVariant]) -> URL? {
            let heights = youtubePictureHeights(in: variants)
            guard let smallest = heights.min(), let height = heights.filter({ $0 <= max(limit, smallest) }).max(),
                  let playlist = YouTubeClient.playlist(manifestText, keepingHeight: height) else { return nil }
            return YouTubePlaylistLoader.shared.address(for: playlist, videoID: videoID, height: height)
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
        #endif
        loadYouTubeVideoExtras()
    }

    /// Called as the movie player stops.
    func youtubeMoviePlaybackWillEnd() {
        guard youtubeSession != nil else { return }
        youtubeSession = nil
        youtubeStreamReloadTask?.cancel()
        youtubeStreamReloadTask = nil
        youtubePanel = nil
        youtubePanelReveal = 0
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

    /// Has the player stop and play on from where it was at the size of picture now asked
    /// for. (Left to change size as it went, it would first play out what it had already
    /// fetched at the old one.)
    private func reloadYouTubeStream() async {
        guard var session = youtubeSession, let player = moviePlayer, !session.playback.isLive else { return }
        #if FIRSTROW_PORTABLE
            let limit = YouTubeStore.shared.maximumHeight ?? Self.youtubeHeightSuitingTheScreen
            guard let chosen = Self.youtubeVariant(in: session.variants, maximumHeight: limit),
                  let url = AVPlayer.pairedStreamsURL(video: chosen.url, audio: chosen.audioURL), url != session.url
            else { return }
            let item = AVPlayerItem(url: url)
        #else
            var url = session.playback.manifestURL
            if let height = YouTubeStore.shared.maximumHeight {
                if session.manifestText == nil {
                    // (Asked for before the video's sizes had been looked up.)
                    let videoID = session.video.id
                    guard let manifest = try? await YouTubeClient.shared.manifest(of: session.playback.manifestURL),
                          var current = youtubeSession, current.video.id == videoID, moviePlayer === player, !Task.isCancelled else { return }
                    current.variants = manifest.variants
                    current.manifestText = manifest.text
                    youtubeSession = current
                    session = current
                }
                guard let text = session.manifestText,
                      let address = Self.youtubeAddress(forHeight: height, videoID: session.video.id, manifestText: text, variants: session.variants)
                else { return }
                url = address
            }
            guard url != session.url else { return }
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
