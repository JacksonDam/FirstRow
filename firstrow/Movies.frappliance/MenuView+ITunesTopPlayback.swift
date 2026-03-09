import AVFoundation
import Foundation
import SwiftUI
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif

private struct _SendableImage: @unchecked Sendable { let image: NSImage? }

extension MenuView {
    private nonisolated func iTunesTopMoviePreviewTemporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("firstRowITunesTopMoviePreviews", isDirectory: true)
    }

    private nonisolated func sanitizedTemporaryMovieName(from rawID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = rawID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? "preview_movie" : sanitized
    }

    private nonisolated func downloadITunesTopPreviewToTemporaryFile(
        from remoteURL: URL,
        itemID: String,
        fallbackExtension: String,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = iTunesTopMoviePreviewTemporaryDirectoryURL()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let resolvedExtension = remoteURL.pathExtension.isEmpty ? fallbackExtension : remoteURL.pathExtension
        let resolvedFileName = "\(sanitizedTemporaryMovieName(from: itemID)).\(resolvedExtension)"
        let destinationURL = directoryURL.appendingPathComponent(resolvedFileName, isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            onProgress?(1)
            return destinationURL.standardizedFileURL
        }
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 120
        request.setValue("video/*;q=1, audio/*;q=1, application/octet-stream;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("firstRow/1.0", forHTTPHeaderField: "User-Agent")
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        _ = fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: destinationURL)
        do {
            if #available(macOS 12.0, *) {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ..< 300).contains(httpResponse.statusCode)
                else {
                    throw URLError(.badServerResponse)
                }
                let expectedLength = response.expectedContentLength
                var receivedLength: Int64 = 0
                let chunkSize = 64 * 1024
                var chunkBuffer: [UInt8] = []
                chunkBuffer.reserveCapacity(chunkSize)
                onProgress?(0)
                func flushChunkBuffer() throws {
                    guard !chunkBuffer.isEmpty else { return }
                    let data = Data(chunkBuffer)
                    try writeHandle.write(contentsOf: data)
                    receivedLength += Int64(chunkBuffer.count)
                    chunkBuffer.removeAll(keepingCapacity: true)
                    guard expectedLength > 0 else { return }
                    let progress = min(1, Double(receivedLength) / Double(expectedLength))
                    onProgress?(progress)
                }
                for try await byte in bytes {
                    chunkBuffer.append(byte)
                    if chunkBuffer.count >= chunkSize {
                        try flushChunkBuffer()
                    }
                }
                try flushChunkBuffer()
            } else {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ..< 300).contains(httpResponse.statusCode)
                else {
                    throw URLError(.badServerResponse)
                }
                try writeHandle.write(contentsOf: data)
            }
            onProgress?(1)
            try writeHandle.close()
            return destinationURL.standardizedFileURL
        } catch {
            try? writeHandle.close()
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private nonisolated func downloadITunesTopMoviePreviewToTemporaryFile(
        from remoteURL: URL,
        movieID: String,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> URL {
        try await downloadITunesTopPreviewToTemporaryFile(
            from: remoteURL,
            itemID: movieID,
            fallbackExtension: "m4v",
            onProgress: onProgress,
        )
    }

    func removeCurrentMoviePlaybackTemporaryFileIfNeeded() {
        guard let temporaryMovieURL = currentMoviePlaybackTemporaryFileURL else { return }
        let standardized = temporaryMovieURL.standardizedFileURL
        currentMoviePlaybackTemporaryFileURL = nil
        try? FileManager.default.removeItem(at: standardized)
    }

    func removeCurrentMusicPlaybackTemporaryFileIfNeeded() {
        guard let temporaryMusicURL = currentMusicPlaybackTemporaryFileURL else { return }
        let standardized = temporaryMusicURL.standardizedFileURL
        currentMusicPlaybackTemporaryFileURL = nil
        try? FileManager.default.removeItem(at: standardized)
    }

    enum ITunesTopVideoPreviewPlaybackSource {
        case movie(ITunesTopMovieEntry)
        case tvEpisode(ITunesTopTVEpisodeEntry)
        case musicVideo(ITunesTopMusicVideoEntry)
        var kind: ITunesTopCarouselKind {
            switch self {
            case .movie:
                .movies
            case .tvEpisode:
                .tvEpisodes
            case .musicVideo:
                .musicVideos
            }
        }

        var itemID: String {
            switch self {
            case let .movie(entry):
                entry.id
            case let .tvEpisode(entry):
                entry.id
            case let .musicVideo(entry):
                entry.id
            }
        }
    }

    func nextITunesTopVideoPreviewPlaybackRequestID(for source: ITunesTopVideoPreviewPlaybackSource) -> Int {
        nextITunesTopPlaybackRequestID(source.kind)
    }

    func currentITunesTopVideoPreviewPlaybackRequestID(for source: ITunesTopVideoPreviewPlaybackSource) -> Int {
        currentITunesTopPlaybackRequestID(source.kind)
    }

    func prepareITunesTopVideoPreviewPlaybackLoadingUI() {
        clearMoviePlaybackControlState()
        isMoviePlaybackVisible = true
        isMoviePreviewDownloadLoading = true
        moviePreviewDownloadProgress = 0
        movieControlsGlyphState = .loading
        showMovieControlsInstantly()
        var instant = Transaction()
        instant.animation = nil
        withTransaction(instant) {
            movieTransitionOverlayOpacity = 0
        }
    }

    func failITunesTopVideoPreviewPlaybackLaunch(
        requestID: Int,
        source: ITunesTopVideoPreviewPlaybackSource,
    ) {
        guard currentITunesTopVideoPreviewPlaybackRequestID(for: source) == requestID else { return }
        clearMoviePlaybackControlState()
        isMoviePlaybackVisible = false
        withAnimation(.easeInOut(duration: movieEntryFadeDuration)) {
            menuSceneOpacity = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + movieEntryFadeDuration) {
            guard self.currentITunesTopVideoPreviewPlaybackRequestID(for: source) == requestID else { return }
            self.isMovieTransitioning = false
        }
    }

    func finalizeITunesTopVideoPreviewPlaybackLaunch(with temporaryMovieURL: URL) {
        clearMoviePlaybackControlState()
        removeCurrentMoviePlaybackTemporaryFileIfNeeded()
        isCurrentMoviePlaybackEphemeralPreview = true
        currentMoviePlaybackTemporaryFileURL = temporaryMovieURL.standardizedFileURL
        lastClosedMovieURL = nil
        lastClosedMovieTimestamp = 0
        activateMoviePlayback(
            from: temporaryMovieURL,
            startSeconds: 0,
            showsPlayGlyphOnStart: true,
        )
        isMovieTransitioning = false
    }

    @MainActor
    func resolveITunesTopVideoPreviewRemoteURL(
        for source: ITunesTopVideoPreviewPlaybackSource,
    ) async -> URL? {
        switch source {
        case let .movie(entry):
            await resolveITunesTopMoviePreviewVideoURL(for: entry)
        case let .tvEpisode(entry):
            await resolveITunesTopTVEpisodePreviewVideoURL(for: entry)
        case let .musicVideo(entry):
            await resolveITunesTopMusicVideoPreviewVideoURL(for: entry)
        }
    }

    func startITunesTopVideoPreviewPlayback(from source: ITunesTopVideoPreviewPlaybackSource) {
        guard !isMovieTransitioning, !isMoviePlaybackVisible else { return }
        resetScreenSaverIdleTimer()
        let requestID = nextITunesTopVideoPreviewPlaybackRequestID(for: source)
        isMovieTransitioning = true
        withAnimation(.easeInOut(duration: movieEntryFadeDuration)) {
            movieTransitionOverlayOpacity = 1
            menuSceneOpacity = 0
        }
        Task.detached(priority: .userInitiated) {
            let fadeOutNanoseconds = UInt64(max(0, self.movieEntryFadeDuration) * 1_000_000_000)
            if fadeOutNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: fadeOutNanoseconds)
            }
            await MainActor.run {
                guard self.currentITunesTopVideoPreviewPlaybackRequestID(for: source) == requestID else {
                    self.isMovieTransitioning = false
                    self.movieTransitionOverlayOpacity = 0
                    return
                }
                self.prepareITunesTopVideoPreviewPlaybackLoadingUI()
            }
            guard let remotePreviewURL = await self.resolveITunesTopVideoPreviewRemoteURL(for: source) else {
                await MainActor.run {
                    self.failITunesTopVideoPreviewPlaybackLaunch(requestID: requestID, source: source)
                }
                return
            }
            let temporaryMovieURL: URL
            do {
                temporaryMovieURL = try await self.downloadITunesTopMoviePreviewToTemporaryFile(
                    from: remotePreviewURL,
                    movieID: source.itemID,
                    onProgress: { progress in
                        Task { @MainActor in
                            guard self.currentITunesTopVideoPreviewPlaybackRequestID(for: source) == requestID else {
                                return
                            }
                            guard self.isMoviePreviewDownloadLoading else { return }
                            self.moviePreviewDownloadProgress = max(0, min(1, progress))
                        }
                    },
                )
            } catch {
                await MainActor.run {
                    self.failITunesTopVideoPreviewPlaybackLaunch(requestID: requestID, source: source)
                }
                return
            }
            await MainActor.run {
                guard self.currentITunesTopVideoPreviewPlaybackRequestID(for: source) == requestID else {
                    try? FileManager.default.removeItem(at: temporaryMovieURL)
                    return
                }
                self.finalizeITunesTopVideoPreviewPlaybackLaunch(with: temporaryMovieURL)
            }
        }
    }

    func startITunesTopMoviePreviewPlayback(for movie: ITunesTopMovieEntry) {
        startITunesTopVideoPreviewPlayback(from: .movie(movie))
    }

    func startITunesTopTVEpisodePreviewPlayback(for episode: ITunesTopTVEpisodeEntry) {
        startITunesTopVideoPreviewPlayback(from: .tvEpisode(episode))
    }

    func startITunesTopSongPreviewPlayback(
        for song: ITunesTopSongEntry,
        trackIndex _: Int? = nil,
        trackCount _: Int? = nil,
        presentsFullscreen: Bool = true,
    ) {
        guard !isMovieTransitioning, !isMoviePlaybackVisible else { return }
        let requestID = nextITunesTopPlaybackRequestID(.songs)
        let resolvedTrackIndex = 0
        let resolvedTrackCount = 1
        Task.detached(priority: .userInitiated) {
            guard let remotePreviewURL = await self.resolveITunesTopSongPreviewAudioURL(for: song) else {
                return
            }
            let temporaryAudioURL: URL
            do {
                temporaryAudioURL = try await self.downloadITunesTopPreviewToTemporaryFile(
                    from: remotePreviewURL,
                    itemID: song.id,
                    fallbackExtension: "m4a",
                )
            } catch {
                return
            }
            let resolvedArtwork: NSImage? = await MainActor.run {
                _SendableImage(image: self.currentITunesTopCarouselArtworkCache(.songs)[song.id] ??
                    (self.currentITunesTopPreviewTargetID(.songs) == song.id
                        ? self.iTunesTopState(for: .songs).previewImage
                        : nil))
            }.image
            #if os(tvOS)
                let playbackEntry = MusicLibrarySongEntry(
                    id: song.id,
                    title: song.title,
                    artist: "iTunes Top Songs",
                    album: "",
                    genre: "",
                    composer: "",
                    durationSeconds: 0,
                    url: temporaryAudioURL,
                    artwork: resolvedArtwork,
                    musicKitSong: nil,
                )
            #else
                let playbackEntry = MusicLibrarySongEntry(
                    id: song.id,
                    title: song.title,
                    artist: "iTunes Top Songs",
                    album: "",
                    genre: "",
                    composer: "",
                    durationSeconds: 0,
                    url: temporaryAudioURL,
                    artwork: resolvedArtwork,
                )
            #endif
            await MainActor.run {
                guard self.currentITunesTopPlaybackRequestID(.songs) == requestID else {
                    try? FileManager.default.removeItem(at: temporaryAudioURL)
                    return
                }
                guard self.activeRootItemID == "music" else {
                    try? FileManager.default.removeItem(at: temporaryAudioURL)
                    return
                }
                guard self.thirdMenuMode == .musicITunesTopSongs ||
                    self.activeFullscreenScene?.key == self.musicNowPlayingFullscreenKey
                else {
                    try? FileManager.default.removeItem(at: temporaryAudioURL)
                    return
                }
                self.isMusicSongsShuffleMode = false
                self.startMusicPlayback(
                    from: playbackEntry,
                    trackIndex: resolvedTrackIndex,
                    trackCount: resolvedTrackCount,
                    presentsFullscreen: presentsFullscreen,
                )
                guard self.activeMusicPlaybackSongID == song.id else {
                    try? FileManager.default.removeItem(at: temporaryAudioURL)
                    return
                }
                self.currentMusicPlaybackTemporaryFileURL = temporaryAudioURL.standardizedFileURL
            }
        }
    }

    func startITunesTopMusicVideoPreviewPlayback(for video: ITunesTopMusicVideoEntry) {
        startITunesTopVideoPreviewPlayback(from: .musicVideo(video))
    }
}
