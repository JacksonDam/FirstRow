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
    /// The sizes its picture comes in, largest first, once they're known.
    var variants: [YouTubeStreamVariant] = []
    var hasStarted = false
    /// The caption track that's on (an index into the video's tracks) and its lines.
    var captionTrack: Int?
    var cues: [YouTubeCaptionCue] = []
    var captionRequestID = 0
}

#if !FIRSTROW_PORTABLE
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
                let (url, variants) = try await self.youtubePlayerURL(for: playback, maximumHeight: YouTubeStore.shared.maximumHeight)
                guard self.thirdMenuMode == .youtube, !self.isMovieTransitioning, !self.isMoviePlaybackVisible else { return }
                self.youtubeSession = YouTubePlaybackSession(video: video, playback: playback, url: url, variants: variants)
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

    /// What the movie player plays a video from, and the sizes its picture comes in when
    /// they had to be looked up to choose one.
    private func youtubePlayerURL(for playback: YouTubePlayback, maximumHeight: Int?) async throws -> (URL, [YouTubeStreamVariant]) {
        #if FIRSTROW_PORTABLE
            // mpv is given one size of the picture and its sound, by their own addresses: left
            // to read the whole playlist, it opens all seventeen sizes before it starts.
            let variants = (try? await YouTubeClient.shared.variants(of: playback.manifestURL)) ?? []
            let limit = maximumHeight ?? Self.youtubeHeightSuitingTheScreen
            if !playback.isLive, let chosen = Self.youtubeVariant(in: variants, maximumHeight: limit),
               let url = AVPlayer.pairedStreamsURL(video: chosen.url, audio: chosen.audioURL)
            {
                return (url, variants)
            }
            return (playback.manifestURL, variants)
        #else
            _ = YouTubeDecoders.prepared
            return (playback.manifestURL, [])
        #endif
    }

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
            applyYouTubeMaximumHeight()
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
        youtubeComments = nil
        youtubeCommentsReveal = 0
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

    #if !FIRSTROW_PORTABLE
        /// Keeps the player to the size of picture that was asked for (any size if none was).
        func applyYouTubeMaximumHeight() {
            guard youtubeSession != nil, let item = moviePlayer?.currentItem else { return }
            if let height = YouTubeStore.shared.maximumHeight {
                // (A square as wide as a 16:9 picture that many lines tall, so that an
                // upright video of the same size fits too.)
                let side = (CGFloat(height) * 16 / 9).rounded(.up) + 2
                item.preferredMaximumResolution = CGSize(width: side, height: side)
            } else {
                item.preferredMaximumResolution = .zero
            }
        }
    #endif
}

/// A video's comments, open over the right of its picture.
struct YouTubeCommentsState {
    var videoID: String
    /// "5,240 Comments", as YouTube words it.
    var totalText: String?
    var comments: [YouTubeComment] = []
    var continuation: String?
    var isLoading = true
    var isLoadingMore = false
    var error: String?
    var focused = 0
}

// MARK: - A video's options: captions, picture size, comments

extension MenuView {
    /// What a YouTube video offers in the movie's options.
    func youtubeOptionKinds() -> [MovieOptionRow.Kind] {
        guard let session = youtubeSession else { return [.speed] }
        var kinds: [MovieOptionRow.Kind] = []
        if !session.playback.captions.isEmpty { kinds.append(.subtitles) }
        if !youtubeOfferedHeights(session).isEmpty { kinds.append(.quality) }
        kinds.append(.speed)
        kinds.append(.comments)
        return kinds
    }

    /// The sizes the video's picture comes in, largest first.
    private func youtubeOfferedHeights(_ session: YouTubePlaybackSession) -> [Int] {
        guard !session.playback.isLive else { return [] }
        var heights: [Int] = []
        for variant in session.variants where !variant.isHighDynamicRange && variant.audioURL != nil && variant.height >= 144 {
            if !heights.contains(variant.height) { heights.append(variant.height) }
        }
        return heights.sorted(by: >)
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
                guard let variants = try? await YouTubeClient.shared.variants(of: session.playback.manifestURL), !variants.isEmpty else { return }
                update { $0.variants = variants }
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
        #if FIRSTROW_PORTABLE
            // Once the choice has rested a moment: stepping through the sizes to reach one
            // would otherwise start, and drop, the playing of each on the way.
            youtubeStreamReloadTask?.cancel()
            youtubeStreamReloadTask = Task { @MainActor in
                try? await firstRowSleep(0.6)
                guard !Task.isCancelled else { return }
                self.reloadYouTubeStream()
            }
        #else
            applyYouTubeMaximumHeight()
        #endif
    }

    #if FIRSTROW_PORTABLE
        /// Has the player play another size of the picture, from where it is.
        private func reloadYouTubeStream() {
            guard var session = youtubeSession, let player = moviePlayer else { return }
            let limit = YouTubeStore.shared.maximumHeight ?? Self.youtubeHeightSuitingTheScreen
            guard let chosen = Self.youtubeVariant(in: session.variants, maximumHeight: limit),
                  let url = AVPlayer.pairedStreamsURL(video: chosen.url, audio: chosen.audioURL), url != session.url
            else { return }
            let time = player.currentTime()
            let wasPlaying = player.rate > 0.01
            let options = movieOptions
            let speed = movieSpeed
            session.url = url
            youtubeSession = session
            currentMoviePlaybackURL = url.standardizedFileURL
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            configureMoviePlaybackObservation(for: player)
            movieOptions = options
            movieSpeed = speed
            if wasPlaying {
                player.play()
                if speed != 1 { applyMovieSpeed(player) }
            }
        }
    #endif

    // MARK: Comments

    /// Opens the video's comments over the right of the picture.
    func openYouTubeComments() {
        guard let session = youtubeSession, youtubeComments == nil else { return }
        let videoID = session.video.id
        playSound(named: "Selection")
        withAnimation(.smoothInOut(duration: 0.3)) {
            movieOptions = nil
            movieOptionsReveal = 0
        }
        youtubeComments = YouTubeCommentsState(videoID: videoID)
        withAnimation(.smooth(duration: 0.36)) {
            youtubeCommentsReveal = 1
        }
        showMovieControlsInstantly()
        Task { @MainActor in
            do {
                var token = self.youtube.details[videoID]?.commentsToken
                if token == nil {
                    let details = try await YouTubeClient.shared.details(of: videoID)
                    self.rememberYouTubeDetails(details, for: videoID)
                    token = details.commentsToken
                }
                guard self.youtubeComments?.videoID == videoID else { return }
                guard let token else {
                    self.youtubeComments?.isLoading = false
                    self.youtubeComments?.error = "Comments are turned off."
                    return
                }
                let page = try await YouTubeClient.shared.comments(token)
                guard self.youtubeComments?.videoID == videoID else { return }
                self.youtubeComments?.isLoading = false
                self.youtubeComments?.totalText = page.totalText
                self.youtubeComments?.comments = page.comments
                self.youtubeComments?.continuation = page.continuation
                if page.comments.isEmpty { self.youtubeComments?.error = "No comments yet." }
            } catch {
                guard self.youtubeComments?.videoID == videoID else { return }
                self.youtubeComments?.isLoading = false
                self.youtubeComments?.error = error.localizedDescription
            }
        }
    }

    func closeYouTubeComments(playsSound: Bool = true) {
        guard youtubeComments != nil, youtubeCommentsReveal > 0 else { return }
        if playsSound { playSound(named: "Exit") }
        withAnimation(.smoothInOut(duration: 0.3)) {
            youtubeCommentsReveal = 0
        }
        scheduleMovieControlsAutoHide()
        Task { @MainActor in
            try? await firstRowSleep(0.32)
            guard self.youtubeCommentsReveal <= 0.001 else { return }
            self.youtubeComments = nil
        }
    }

    /// Picks out another comment (for a click, the wheel or a finger; the arrows have their
    /// own way below).
    func showYouTubeComment(_ index: Int, playsSound: Bool = false) {
        guard var state = youtubeComments, youtubeCommentsReveal > 0, index != state.focused,
              state.comments.indices.contains(index) else { return }
        state.focused = index
        youtubeComments = state
        if playsSound { playSound(named: "SelectionChange") }
        loadMoreYouTubeCommentsIfNeeded()
    }

    /// The comments' panel under a point of the window, while it's out: whether the point is
    /// on it, and on which comment.
    func youtubeCommentsHit(at windowPoint: CGPoint) -> (isOnPanel: Bool, index: Int?)? {
        guard isMoviePlaybackVisible, youtubeComments != nil, youtubeCommentsReveal > 0 else { return nil }
        return pointer.hitTester?.youtubeComment(at: windowPoint)
    }

    /// Keys while the comments are open. Returns true when they took the key.
    func handleYouTubeCommentsInput(_ key: KeyCode) -> Bool {
        guard var state = youtubeComments, youtubeCommentsReveal > 0 else { return false }
        switch key {
        case .escape, .delete, .leftArrow:
            closeYouTubeComments()
        case .upArrow:
            guard state.focused > 0 else {
                playLimitSoundOnceForCurrentHold()
                return true
            }
            state.focused -= 1
            youtubeComments = state
            playSound(named: "SelectionChange")
        case .downArrow:
            guard state.focused + 1 < state.comments.count else {
                playLimitSoundOnceForCurrentHold()
                return true
            }
            state.focused += 1
            youtubeComments = state
            playSound(named: "SelectionChange")
            loadMoreYouTubeCommentsIfNeeded()
        case .space:
            handleMovieSpacebarPressed()
        default:
            break
        }
        return true
    }

    private func loadMoreYouTubeCommentsIfNeeded() {
        guard let state = youtubeComments, !state.isLoadingMore, let token = state.continuation,
              state.focused >= state.comments.count - 6, state.comments.count < 400
        else { return }
        youtubeComments?.isLoadingMore = true
        let videoID = state.videoID
        Task { @MainActor in
            let page = try? await YouTubeClient.shared.comments(token)
            guard self.youtubeComments?.videoID == videoID else { return }
            self.youtubeComments?.isLoadingMore = false
            guard let page else {
                self.youtubeComments?.continuation = nil
                return
            }
            let known = Set(self.youtubeComments?.comments.map(\.id) ?? [])
            let fresh = page.comments.filter { !known.contains($0.id) }
            self.youtubeComments?.comments += fresh
            self.youtubeComments?.continuation = fresh.isEmpty ? nil : page.continuation
        }
    }
}
