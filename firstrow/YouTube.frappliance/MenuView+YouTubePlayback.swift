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
        #endif
    }

    /// Called as the movie player stops.
    func youtubeMoviePlaybackWillEnd() {
        guard youtubeSession != nil else { return }
        youtubeSession = nil
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
