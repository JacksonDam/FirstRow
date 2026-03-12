import AVFoundation
import SwiftUI
#if canImport(CryptoKit)
    import CryptoKit
#endif
#if os(iOS)
    import MediaPlayer
#endif
#if os(macOS)
    import SQLite3
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif
private struct PodcastEmbeddedMetadataEntry {
    let artwork: NSImage?
    let description: String?
}

private let podcastEmbeddedMetadataCache = BoundedCache<String, PodcastEmbeddedMetadataEntry>(maxEntryCount: 600)

extension MenuView {
    var podcastSeriesSubmenuItemPrefix: String {
        "podcast_series::"
    }

    var podcastsNowPlayingSubmenuItemID: String {
        "podcasts_now_playing"
    }

    var isPodcastAudioNowPlaying: Bool {
        activePodcastPlaybackSeriesID != nil && activePodcastPlaybackEpisodeID != nil
    }

    func activePodcastPlaybackSeries() -> PodcastSeriesEntry? {
        guard let activePodcastPlaybackSeriesID else { return nil }
        return podcastSeriesItems.first(where: { $0.id == activePodcastPlaybackSeriesID })
    }

    func activePodcastPlaybackEpisodes() -> [PodcastEpisodeEntry] {
        if let activeSeries = activePodcastPlaybackSeries() {
            return activeSeries.episodes
        }
        guard let activePodcastPlaybackSeriesID else { return [] }
        let activeThirdMenuEpisodes = podcastEpisodesThirdMenuItems.filter { $0.seriesID == activePodcastPlaybackSeriesID }
        return activeThirdMenuEpisodes.isEmpty ? [] : activeThirdMenuEpisodes
    }

    func podcastTrackPositionText(trackIndex: Int, trackCount: Int) -> String {
        guard trackCount > 0, trackIndex >= 0, trackIndex < trackCount else { return "" }
        return "\(trackIndex + 1) of \(trackCount)"
    }

    func podcastTrackPositionText(forEpisodeID episodeID: String?, inSeriesID seriesID: String?) -> String {
        guard let episodeID, let seriesID else { return "" }
        let episodes: [PodcastEpisodeEntry] = if let series = podcastSeriesItems.first(where: { $0.id == seriesID }) {
            series.episodes
        } else {
            podcastEpisodesThirdMenuItems.filter { $0.seriesID == seriesID }
        }
        guard !episodes.isEmpty else { return "" }
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { return "" }
        return podcastTrackPositionText(trackIndex: index, trackCount: episodes.count)
    }

    func syncPodcastSubmenuSelectionForActiveSeries() {
        guard activeRootItemID == "podcasts", isInSubmenu, !isInThirdMenu else { return }
        let targetSeriesID = activePodcastSeriesID ?? activePodcastPlaybackSeriesID
        guard let targetSeriesID else { return }
        let targetItemID = "\(podcastSeriesSubmenuItemPrefix)\(targetSeriesID)"
        let submenuItems = currentSubmenuItems()
        guard let targetIndex = submenuItems.firstIndex(where: { $0.id == targetItemID }) else { return }
        selectedSubIndex = targetIndex
    }

    func normalizedPodcastText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func strippedHTMLText(_ raw: String?) -> String? {
        guard let raw = normalizedPodcastText(raw) else { return nil }
        let withoutTags = raw.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression,
        )
        let normalizedSpaces = withoutTags.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression,
        )
        return normalizedPodcastText(normalizedSpaces)
    }

    func resolvedPodcastDescription(
        plainText: String?,
        htmlText: String?,
        fallback: String?,
    ) -> String {
        normalizedPodcastText(plainText)
            ?? strippedHTMLText(htmlText)
            ?? normalizedPodcastText(fallback)
            ?? "No description available."
    }

    var podcastArtworkRequestSize: CGSize {
        CGSize(width: 1600, height: 1600)
    }

    var podcastAudioExtensions: Set<String> {
        ["aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mp3", "opus", "wav"]
    }

    var podcastVideoExtensions: Set<String> {
        ["avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "ts", "webm", "wmv"]
    }

    func podcastMediaMetadataCacheKey(for mediaURL: URL) -> String {
        let normalizedURL = mediaURL.standardizedFileURL
        return normalizedURL.isFileURL ? normalizedURL.path : normalizedURL.absoluteString
    }

    func blockingAssetLoad<Value>(
        _ operation: @escaping @Sendable () async -> Value?,
    ) -> Value? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingResultBox<Value>()
        Task.detached(priority: .userInitiated) {
            await box.set(operation())
            semaphore.signal()
        }
        semaphore.wait()
        return box.value()
    }

    private func loadPodcastEmbeddedMetadata(_ mediaURL: URL) -> PodcastEmbeddedMetadataEntry {
        let cacheKey = podcastMediaMetadataCacheKey(for: mediaURL)
        if let cached = podcastEmbeddedMetadataCache.value(for: cacheKey) {
            return cached
        }
        let loaded = blockingAssetLoad { () async -> PodcastEmbeddedMetadataEntry? in
            let asset = AVURLAsset(url: mediaURL)
            let commonMetadata: [AVMetadataItem]
            if #available(macOS 12.0, *) {
                guard let loaded = try? await asset.load(.commonMetadata) else {
                    return PodcastEmbeddedMetadataEntry(artwork: nil, description: nil)
                }
                commonMetadata = loaded
            } else {
                commonMetadata = asset.commonMetadata
            }
            let artworkItems = AVMetadataItem.metadataItems(
                from: commonMetadata,
                filteredByIdentifier: .commonIdentifierArtwork,
            )
            let descriptionItems = AVMetadataItem.metadataItems(
                from: commonMetadata,
                filteredByIdentifier: .commonIdentifierDescription,
            )
            var artwork: NSImage?
            for item in artworkItems {
                let dataValue: Data? = if #available(macOS 12.0, *) {
                    try? await item.load(.dataValue)
                } else {
                    item.dataValue
                }
                if let dataValue,
                   let image = cachedDecodedDisplayArtworkImage(
                       from: dataValue,
                       sourceKey: "\(cacheKey)::embedded_artwork_data",
                       maxPixelSize: podcastArtworkRequestSize.width,
                   )
                {
                    artwork = image
                    break
                }
                let itemValue: (NSCopying & NSObjectProtocol)? = if #available(macOS 12.0, *) {
                    try? await item.load(.value)
                } else {
                    item.value
                }
                if let dataValue = itemValue as? Data,
                   let image = cachedDecodedDisplayArtworkImage(
                       from: dataValue,
                       sourceKey: "\(cacheKey)::embedded_artwork_value",
                       maxPixelSize: podcastArtworkRequestSize.width,
                   )
                {
                    artwork = image
                    break
                }
            }
            var description: String?
            for item in descriptionItems {
                let stringValue: String? = if #available(macOS 12.0, *) {
                    try? await item.load(.stringValue)
                } else {
                    item.stringValue
                }
                if let direct = stringValue {
                    let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        description = trimmed
                        break
                    }
                }
                let itemValue: (NSCopying & NSObjectProtocol)? = if #available(macOS 12.0, *) {
                    try? await item.load(.value)
                } else {
                    item.value
                }
                if let rawValue = itemValue as? String {
                    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        description = trimmed
                        break
                    }
                }
            }
            return PodcastEmbeddedMetadataEntry(artwork: artwork, description: description)
        } ?? PodcastEmbeddedMetadataEntry(artwork: nil, description: nil)
        podcastEmbeddedMetadataCache.store(loaded, for: cacheKey)
        return loaded
    }

    func resolvedPodcastIsVideo(mediaURL: URL, declaredIsVideo: Bool) -> Bool {
        let ext = mediaURL.pathExtension.lowercased()
        if podcastAudioExtensions.contains(ext) {
            return false
        }
        if podcastVideoExtensions.contains(ext) {
            return true
        }
        let flags = mediaTrackFlags(for: mediaURL)
        if flags.hasVideo {
            return true
        }
        if flags.hasAudio {
            return false
        }
        return declaredIsVideo
    }

    func loadPodcastArtworkFromMediaMetadata(_ mediaURL: URL) -> NSImage? {
        loadPodcastEmbeddedMetadata(mediaURL).artwork
    }

    func loadPodcastDescriptionFromMediaMetadata(_ mediaURL: URL) -> String? {
        normalizedPodcastText(loadPodcastEmbeddedMetadata(mediaURL).description)
    }

    func podcastSeriesSubmenuItemID(for series: PodcastSeriesEntry) -> String {
        "\(podcastSeriesSubmenuItemPrefix)\(series.id)"
    }

    func podcastSeriesForSubmenuItemID(_ submenuItemID: String?) -> PodcastSeriesEntry? {
        guard let submenuItemID else { return nil }
        guard submenuItemID.hasPrefix(podcastSeriesSubmenuItemPrefix) else { return nil }
        let seriesID = String(submenuItemID.dropFirst(podcastSeriesSubmenuItemPrefix.count))
        return podcastSeriesItems.first(where: { $0.id == seriesID })
    }

    func selectedPodcastEpisodeFromThirdMenuSelection() -> PodcastEpisodeEntry? {
        guard activeRootItemID == "podcasts", isInSubmenu, isInThirdMenu, thirdMenuMode == .podcastsEpisodes else {
            return nil
        }
        guard podcastEpisodesThirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
        return podcastEpisodesThirdMenuItems[selectedThirdIndex]
    }

    func podcastsSubmenuItems() -> [SubmenuItemConfig] {
        let baseItems: [SubmenuItemConfig] = if isLoadingPodcasts, podcastSeriesItems.isEmpty {
            []
        } else if let podcastsLoadError, podcastSeriesItems.isEmpty {
            [.init(
                id: "podcasts_error",
                title: podcastsLoadError,
                actionID: "podcasts_error",
                leadsToMenu: false,
            )]
        } else if podcastSeriesItems.isEmpty {
            []
        } else {
            podcastSeriesItems.map { series in .init(
                id: podcastSeriesSubmenuItemID(for: series),
                title: series.title,
                actionID: "podcast_series_open",
                leadsToMenu: true,
            ) }
        }
        guard isPodcastAudioNowPlaying else { return baseItems }
        return [.init(
            id: podcastsNowPlayingSubmenuItemID,
            title: "Now Playing",
            actionID: podcastsNowPlayingSubmenuItemID,
            leadsToMenu: true,
        )] + baseItems
    }

    func refreshPodcastsForCurrentContext() {
        guard activeRootItemID == "podcasts", isInSubmenu else { return }
        requestPodcastsLibraryLoadIfNeeded()
        if !podcastSeriesItems.isEmpty {
            hasPresentedNoPodcastsErrorInCurrentSession = false
        }
        if isInThirdMenu, thirdMenuMode == .podcastsEpisodes {
            syncPodcastEpisodesForActiveSeries()
        }
        maybePresentNoPodcastsEmptyLibraryError()
    }

    func maybePresentNoPodcastsEmptyLibraryError() {
        guard activeRootItemID == "podcasts", isInSubmenu else { return }
        guard podcastsHasLoadedAtLeastOnce else { return }
        guard !isLoadingPodcasts else { return }
        guard podcastsLoadError == nil else { return }
        guard podcastSeriesItems.isEmpty else { return }
        guard !hasPresentedNoPodcastsErrorInCurrentSession else { return }
        guard activeFullscreenScene == nil else { return }
        guard !isFullscreenSceneTransitioning else { return }
        hasPresentedNoPodcastsErrorInCurrentSession = true
        presentNoPodcastsFeatureErrorScreen()
    }

    func presentNoPodcastsFeatureErrorScreen() {
        presentFeatureErrorScreen(.noPodcasts)
    }

    func handlePodcastsRootMenuSelection(_ chosenRootItem: RootMenuItemConfig) {
        guard !isResolvingPodcastsRootSelection else { return }
        if podcastsHasLoadedAtLeastOnce, !isLoadingPodcasts {
            if podcastsLoadError == nil, podcastSeriesItems.isEmpty {
                playSound(named: "Selection")
                presentNoPodcastsFeatureErrorScreen()
                return
            }
            beginSubmenuTransition(for: chosenRootItem)
            return
        }
        let requestID = incrementRequestID(&podcastsRequestID)
        isResolvingPodcastsRootSelection = true
        isLoadingPodcasts = true
        podcastsLoadError = nil
        playSound(named: "Selection")
        requestPodcastsLibraryAuthorization { isAuthorized in
            guard self.podcastsRequestID == requestID else { return }
            guard isAuthorized else {
                self.isResolvingPodcastsRootSelection = false
                self.isLoadingPodcasts = false
                self.podcastSeriesItems = []
                self.podcastEpisodesThirdMenuItems = []
                self.activePodcastSeriesID = nil
                self.podcastsHasLoadedAtLeastOnce = true
                self.podcastsLoadError = "Podcasts library access denied"
                guard !self.isInSubmenu, !self.isEnteringSubmenu else { return }
                self.beginSubmenuTransition(for: chosenRootItem, playSelectionSound: false)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let series = try self.loadDownloadedPodcastSeries()
                    DispatchQueue.main.async {
                        guard self.podcastsRequestID == requestID else { return }
                        self.isResolvingPodcastsRootSelection = false
                        self.isLoadingPodcasts = false
                        self.podcastSeriesItems = series
                        self.podcastEpisodesThirdMenuItems = []
                        self.activePodcastSeriesID = nil
                        self.podcastsHasLoadedAtLeastOnce = true
                        self.podcastsLoadError = nil
                        self.hasPresentedNoPodcastsErrorInCurrentSession = false
                        guard !self.isInSubmenu, !self.isEnteringSubmenu else { return }
                        if series.isEmpty {
                            self.presentNoPodcastsFeatureErrorScreen()
                        } else {
                            self.beginSubmenuTransition(for: chosenRootItem, playSelectionSound: false)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.podcastsRequestID == requestID else { return }
                        self.isResolvingPodcastsRootSelection = false
                        self.isLoadingPodcasts = false
                        self.podcastSeriesItems = []
                        self.podcastEpisodesThirdMenuItems = []
                        self.activePodcastSeriesID = nil
                        self.podcastsHasLoadedAtLeastOnce = true
                        self.podcastsLoadError = self.podcastsLibraryErrorMessage(for: error)
                        guard !self.isInSubmenu, !self.isEnteringSubmenu else { return }
                        self.beginSubmenuTransition(for: chosenRootItem, playSelectionSound: false)
                    }
                }
            }
        }
    }

    func requestPodcastsLibraryLoadIfNeeded(force: Bool = false) {
        guard activeRootItemID == "podcasts", isInSubmenu else { return }
        guard force || !podcastsHasLoadedAtLeastOnce else { return }
        guard !isLoadingPodcasts else { return }
        let requestID = incrementRequestID(&podcastsRequestID)
        isLoadingPodcasts = true
        podcastsLoadError = nil
        requestPodcastsLibraryAuthorization { isAuthorized in
            guard self.podcastsRequestID == requestID else { return }
            guard isAuthorized else {
                self.isLoadingPodcasts = false
                self.podcastSeriesItems = []
                self.podcastEpisodesThirdMenuItems = []
                self.activePodcastSeriesID = nil
                self.podcastsHasLoadedAtLeastOnce = true
                self.podcastsLoadError = "Podcasts library access denied"
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let series = try self.loadDownloadedPodcastSeries()
                    DispatchQueue.main.async {
                        guard self.podcastsRequestID == requestID else { return }
                        guard self.activeRootItemID == "podcasts", self.isInSubmenu else { return }
                        self.isLoadingPodcasts = false
                        self.podcastSeriesItems = series
                        self.podcastsHasLoadedAtLeastOnce = true
                        self.podcastsLoadError = nil
                        if self.isInThirdMenu, self.thirdMenuMode == .podcastsEpisodes {
                            self.syncPodcastEpisodesForActiveSeries()
                        } else {
                            self.selectedSubIndex = min(
                                self.selectedSubIndex,
                                max(0, self.podcastSeriesItems.count - 1),
                            )
                            self.syncPodcastSubmenuSelectionForActiveSeries()
                        }
                        self.refreshDetailPreviewForCurrentContext()
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.podcastsRequestID == requestID else { return }
                        guard self.activeRootItemID == "podcasts", self.isInSubmenu else { return }
                        self.isLoadingPodcasts = false
                        self.podcastSeriesItems = []
                        self.podcastEpisodesThirdMenuItems = []
                        self.activePodcastSeriesID = nil
                        self.podcastsHasLoadedAtLeastOnce = true
                        self.podcastsLoadError = self.podcastsLibraryErrorMessage(for: error)
                    }
                }
            }
        }
    }

    func podcastsLibraryErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            return "Podcasts library access denied"
        }
        return "Unable to access Podcasts library"
    }

    func requestPodcastsLibraryAuthorization(_ completion: @escaping (Bool) -> Void) {
        #if os(iOS)
            let status = MPMediaLibrary.authorizationStatus()
            switch status {
            case .authorized:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                MPMediaLibrary.requestAuthorization { newStatus in
                    DispatchQueue.main.async {
                        completion(newStatus == .authorized)
                    }
                }
            @unknown default:
                completion(false)
            }
        #else
            completion(true)
        #endif
    }

    func loadDownloadedPodcastSeries() throws -> [PodcastSeriesEntry] {
        #if os(iOS)
            guard MPMediaLibrary.authorizationStatus() == .authorized else {
                throw NSError(
                    domain: "firstRowPodcastsLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Podcasts library access not authorized"],
                )
            }
            let collections = MPMediaQuery.podcasts().collections ?? []
            var seriesEntries: [PodcastSeriesEntry] = []
            seriesEntries.reserveCapacity(collections.count)
            for collection in collections {
                let downloadedItems = collection.items.filter { $0.assetURL != nil }
                guard !downloadedItems.isEmpty else { continue }
                let seriesTitle = downloadedItems.lazy.compactMap { normalizedPodcastText($0.albumTitle) }.first
                    ?? normalizedPodcastText(downloadedItems.first?.artist)
                    ?? "Unknown Podcast"
                let seriesArtist = downloadedItems.lazy.compactMap { normalizedPodcastText($0.artist) }.first
                    ?? "Unknown Artist"
                var seriesArtwork = downloadedItems.lazy.compactMap { $0.artwork?.image(at: podcastArtworkRequestSize) }.first
                var episodes: [PodcastEpisodeEntry] = []
                episodes.reserveCapacity(downloadedItems.count)
                for item in downloadedItems {
                    guard let mediaURL = item.assetURL else { continue }
                    let episodeTitle = normalizedPodcastText(item.title)
                        ?? mediaURL.deletingPathExtension().lastPathComponent
                    let episodeArtist = normalizedPodcastText(item.artist) ?? seriesArtist
                    let itemComments = item.value(forProperty: MPMediaItemPropertyComments) as? String
                    let embeddedDescription = loadPodcastDescriptionFromMediaMetadata(mediaURL)
                    let episodeDescription = resolvedPodcastDescription(
                        plainText: itemComments,
                        htmlText: nil,
                        fallback: embeddedDescription,
                    )
                    let durationSeconds = max(0, item.playbackDuration)
                    let airedDate = item.releaseDate
                    let mediaTypeMask = item.mediaType.rawValue
                    let declaredIsVideo = (mediaTypeMask & MPMediaType.anyVideo.rawValue) != 0
                    let isVideo = resolvedPodcastIsVideo(mediaURL: mediaURL, declaredIsVideo: declaredIsVideo)
                    let episodeArtwork = item.artwork?.image(at: podcastArtworkRequestSize)
                        ?? loadPodcastArtworkFromMediaMetadata(mediaURL)
                        ?? seriesArtwork
                    if seriesArtwork == nil, let episodeArtwork {
                        seriesArtwork = episodeArtwork
                    }
                    episodes.append(
                        PodcastEpisodeEntry(
                            id: "ios::\(item.persistentID)",
                            seriesID: "ios::\(collection.persistentID)",
                            seriesTitle: seriesTitle,
                            title: episodeTitle,
                            artist: episodeArtist,
                            description: episodeDescription,
                            durationSeconds: durationSeconds,
                            airedDate: airedDate,
                            mediaURL: mediaURL,
                            artwork: episodeArtwork,
                            isVideo: isVideo,
                        ),
                    )
                }
                guard !episodes.isEmpty else { continue }
                let seriesDescription = downloadedItems.lazy.compactMap { item -> String? in
                    if let comments = normalizedPodcastText(item.value(forProperty: MPMediaItemPropertyComments) as? String) {
                        return comments
                    }
                    guard let mediaURL = item.assetURL else { return nil }
                    return loadPodcastDescriptionFromMediaMetadata(mediaURL)
                }.first
                    ?? ""
                seriesEntries.append(
                    PodcastSeriesEntry(
                        id: "ios::\(collection.persistentID)",
                        title: seriesTitle,
                        artist: seriesArtist,
                        description: seriesDescription,
                        artwork: seriesArtwork,
                        episodes: sortedPodcastEpisodes(episodes),
                    ),
                )
            }
            return seriesEntries.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        #elseif os(macOS)
            let podcastsAppSeries = loadDownloadedPodcastSeriesFromPodcastsAppDatabase()
            if !podcastsAppSeries.isEmpty {
                return podcastsAppSeries
            }
            #if canImport(iTunesLibrary)
                return try loadDownloadedPodcastSeriesFromITunesLibrary()
            #else
                return []
            #endif
        #elseif canImport(iTunesLibrary)
            return try loadDownloadedPodcastSeriesFromITunesLibrary()
        #else
            return []
        #endif
    }

    func sortedPodcastEpisodes(_ episodes: [PodcastEpisodeEntry]) -> [PodcastEpisodeEntry] {
        episodes.sorted { lhs, rhs in
            switch (lhs.airedDate, rhs.airedDate) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    #if canImport(iTunesLibrary)
        func loadDownloadedPodcastSeriesFromITunesLibrary() throws -> [PodcastSeriesEntry] {
            try withITLibrary { library in
                let mediaItems = library.allMediaItems
                var groupedEpisodes: [String: [PodcastEpisodeEntry]] = [:]
                var groupedTitles: [String: String] = [:]
                var groupedArtists: [String: String] = [:]
                var groupedDescriptions: [String: String] = [:]
                var groupedArtwork: [String: NSImage] = [:]
                for item in mediaItems {
                    guard item.mediaKind == .kindPodcast else { continue }
                    guard let mediaURL = item.location else { continue }
                    let seriesTitle = normalizedPodcastText(item.album.title)
                        ?? normalizedPodcastText(item.title)
                        ?? "Unknown Podcast"
                    let seriesArtist = normalizedPodcastText(item.artist?.name) ?? "Unknown Artist"
                    let seriesKey = "\(seriesTitle.lowercased())::\(seriesArtist.lowercased())"
                    let seriesID = "mac::itunes::\(seriesKey)"
                    let episodeTitle = normalizedPodcastText(item.title)
                        ?? mediaURL.deletingPathExtension().lastPathComponent
                    let episodeArtist = normalizedPodcastText(item.artist?.name) ?? seriesArtist
                    let embeddedDescription = loadPodcastDescriptionFromMediaMetadata(mediaURL)
                    let episodeDescription = resolvedPodcastDescription(
                        plainText: item.comments,
                        htmlText: nil,
                        fallback: embeddedDescription,
                    )
                    let rawDuration = max(0, Double(item.totalTime))
                    let durationSeconds = rawDuration > 20000 ? (rawDuration / 1000.0) : rawDuration
                    let airedDate = item.releaseDate ?? item.addedDate
                    let episodeArtwork = item.artwork?.image ?? loadPodcastArtworkFromMediaMetadata(mediaURL)
                    let isVideo = resolvedPodcastIsVideo(mediaURL: mediaURL, declaredIsVideo: item.videoInfo != nil)
                    groupedTitles[seriesKey] = seriesTitle
                    groupedArtists[seriesKey] = seriesArtist
                    if groupedDescriptions[seriesKey] == nil || groupedDescriptions[seriesKey]?.isEmpty == true {
                        groupedDescriptions[seriesKey] = resolvedPodcastDescription(
                            plainText: item.comments,
                            htmlText: nil,
                            fallback: embeddedDescription,
                        )
                    }
                    if groupedArtwork[seriesKey] == nil, let episodeArtwork {
                        groupedArtwork[seriesKey] = episodeArtwork
                    }
                    let episode = PodcastEpisodeEntry(
                        id: "mac::itunes::\(item.persistentID)",
                        seriesID: seriesID,
                        seriesTitle: seriesTitle,
                        title: episodeTitle,
                        artist: episodeArtist,
                        description: episodeDescription,
                        durationSeconds: durationSeconds,
                        airedDate: airedDate,
                        mediaURL: mediaURL,
                        artwork: episodeArtwork,
                        isVideo: isVideo,
                    )
                    groupedEpisodes[seriesKey, default: []].append(episode)
                }
                var seriesEntries: [PodcastSeriesEntry] = []
                seriesEntries.reserveCapacity(groupedEpisodes.count)
                for (seriesKey, episodes) in groupedEpisodes {
                    guard !episodes.isEmpty else { continue }
                    let title = groupedTitles[seriesKey] ?? "Unknown Podcast"
                    let artist = groupedArtists[seriesKey] ?? "Unknown Artist"
                    let description = groupedDescriptions[seriesKey] ?? ""
                    let seriesArtwork = groupedArtwork[seriesKey]
                    let seriesID = "mac::itunes::\(seriesKey)"
                    let sortedEpisodes = sortedPodcastEpisodes(
                        episodes.map { episode in
                            PodcastEpisodeEntry(
                                id: episode.id,
                                seriesID: episode.seriesID,
                                seriesTitle: episode.seriesTitle,
                                title: episode.title,
                                artist: episode.artist,
                                description: episode.description,
                                durationSeconds: episode.durationSeconds,
                                airedDate: episode.airedDate,
                                mediaURL: episode.mediaURL,
                                artwork: episode.artwork ?? seriesArtwork,
                                isVideo: episode.isVideo,
                            )
                        },
                    )
                    seriesEntries.append(
                        PodcastSeriesEntry(
                            id: seriesID,
                            title: title,
                            artist: artist,
                            description: description,
                            artwork: seriesArtwork,
                            episodes: sortedEpisodes,
                        ),
                    )
                }
                return seriesEntries.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            } // withITLibrary
        }
    #endif
    #if os(macOS)
        func podcastsAppGroupContainerURL() -> URL? {
            guard let homeURL = realUserHomeDirectoryURL() else { return nil }
            return homeURL.appendingPathComponent("Library", isDirectory: true).appendingPathComponent("Group Containers", isDirectory: true).appendingPathComponent("243LU875E5.groups.com.apple.podcasts", isDirectory: true)
        }

        func podcastsAppDatabaseURL() -> URL? {
            podcastsAppGroupContainerURL()?.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("MTLibrary.sqlite", isDirectory: false)
        }

        func podcastsAppArtworkCacheDirectoryURL(groupContainerURL: URL) -> URL {
            groupContainerURL.appendingPathComponent("Library", isDirectory: true).appendingPathComponent("Cache", isDirectory: true).appendingPathComponent("Assets", isDirectory: true).appendingPathComponent("Artwork", isDirectory: true)
        }

        func resolvePodcastsAppMediaURL(
            downloadPath: String?,
            assetURL: String?,
            groupContainerURL: URL,
        ) -> URL? {
            if let rawDownloadPath = normalizedPodcastText(downloadPath) {
                if rawDownloadPath.lowercased().hasPrefix("file://"),
                   let fileURL = URL(string: rawDownloadPath)
                {
                    return fileURL.standardizedFileURL
                }
                if rawDownloadPath.hasPrefix("/") {
                    return URL(fileURLWithPath: rawDownloadPath, isDirectory: false).standardizedFileURL
                }
                return groupContainerURL.appendingPathComponent(rawDownloadPath, isDirectory: false).standardizedFileURL
            }
            if let rawAssetURL = normalizedPodcastText(assetURL),
               rawAssetURL.lowercased().hasPrefix("file://"),
               let fileURL = URL(string: rawAssetURL)
            {
                return fileURL.standardizedFileURL
            }
            return nil
        }

        func podcastDateFromCoreDataTimestamp(_ rawValue: Double) -> Date? {
            guard rawValue.isFinite, rawValue > 0 else { return nil }
            return Date(timeIntervalSinceReferenceDate: rawValue)
        }

        func sqliteColumnString(_ statement: OpaquePointer?, _ column: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: raw)
        }

        func sqliteColumnDouble(_ statement: OpaquePointer?, _ column: Int32) -> Double {
            sqlite3_column_double(statement, column)
        }

        func sqliteColumnInt64(_ statement: OpaquePointer?, _ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func podcastsArtworkPixelArea(from fileName: String) -> Int {
            let pattern = "(\\d+)x(\\d+)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
            let nameRange = NSRange(fileName.startIndex ..< fileName.endIndex, in: fileName)
            guard let match = regex.firstMatch(in: fileName, options: [], range: nameRange) else { return 0 }
            guard match.numberOfRanges >= 3 else { return 0 }
            let widthRange = match.range(at: 1)
            let heightRange = match.range(at: 2)
            guard let widthSwiftRange = Range(widthRange, in: fileName),
                  let heightSwiftRange = Range(heightRange, in: fileName),
                  let width = Int(fileName[widthSwiftRange]),
                  let height = Int(fileName[heightSwiftRange])
            else {
                return 0
            }
            return max(0, width * height)
        }

        func podcastsAppArtworkFileIndex(groupContainerURL: URL) -> [String: URL] {
            let artworkDirectoryURL = podcastsAppArtworkCacheDirectoryURL(groupContainerURL: groupContainerURL)
            let fileManager = FileManager.default
            guard let fileURLs = try? fileManager.contentsOfDirectory(
                at: artworkDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            ) else {
                return [:]
            }
            var index: [String: URL] = [:]
            var areas: [String: Int] = [:]
            for fileURL in fileURLs {
                let fileName = fileURL.lastPathComponent
                let normalizedName = fileName.lowercased()
                if normalizedName.contains("-blurred") {
                    continue
                }
                let components = fileName.split(separator: "-")
                guard components.count >= 3 else { continue }
                let hashComponent = String(components[1]).lowercased()
                guard hashComponent.count == 32 else { continue }
                let area = podcastsArtworkPixelArea(from: fileName)
                if let existingArea = areas[hashComponent], existingArea >= area {
                    continue
                }
                index[hashComponent] = fileURL
                areas[hashComponent] = area
            }
            return index
        }

        func md5HexString(_ rawValue: String) -> String? {
            let normalized = normalizedPodcastText(rawValue)
            guard let normalized else { return nil }
            #if canImport(CryptoKit)
                let digest = Insecure.MD5.hash(data: Data(normalized.utf8))
                return digest.map { String(format: "%02x", $0) }.joined()
            #else
                return nil
            #endif
        }

        func loadPodcastsAppArtwork(
            templateURL: String?,
            imageURL: String?,
            logoURL: String?,
            artworkFileIndex: [String: URL],
        ) -> NSImage? {
            let urlCandidates = [templateURL, imageURL, logoURL].compactMap { normalizedPodcastText($0) }
            for candidate in urlCandidates {
                guard let hash = md5HexString(candidate),
                      let fileURL = artworkFileIndex[hash],
                      let image = cachedDecodedDisplayArtworkImage(
                          fromFileURL: fileURL,
                          sourceKey: "podcasts_app_artwork_file::\(hash)",
                          maxPixelSize: podcastArtworkRequestSize.width,
                      )
                else {
                    continue
                }
                return image
            }
            return loadPodcastsRemoteArtwork(
                templateURL: templateURL,
                imageURL: imageURL,
                logoURL: logoURL,
            )
        }

        func loadPodcastsRemoteArtwork(
            templateURL: String?,
            imageURL: String?,
            logoURL: String?,
        ) -> NSImage? {
            let candidates = podcastsRemoteArtworkURLCandidates(
                templateURL: templateURL,
                imageURL: imageURL,
                logoURL: logoURL,
            )
            guard !candidates.isEmpty else { return nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 4
            configuration.timeoutIntervalForResource = 6
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            for remoteURL in candidates.prefix(3) {
                if let cached = cachedDecodedDisplayArtworkImage(
                    sourceKey: remoteURL.absoluteString,
                    maxPixelSize: podcastArtworkRequestSize.width,
                ) {
                    return cached
                }
                var request = URLRequest(url: remoteURL)
                request.timeoutInterval = 4
                let semaphore = DispatchSemaphore(value: 0)
                var resolvedImage: NSImage?
                let task = session.dataTask(with: request) { data, response, _ in
                    defer { semaphore.signal() }
                    guard let data else { return }
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200 ..< 300).contains(httpResponse.statusCode)
                    else {
                        return
                    }
                    guard let image = cachedDecodedDisplayArtworkImage(
                        from: data,
                        sourceKey: remoteURL.absoluteString,
                        maxPixelSize: self.podcastArtworkRequestSize.width,
                    ) else { return }
                    resolvedImage = image
                }
                task.resume()
                _ = semaphore.wait(timeout: .now() + 6.5)
                if let resolvedImage {
                    return resolvedImage
                }
            }
            return nil
        }

        func podcastsRemoteArtworkURLCandidates(
            templateURL: String?,
            imageURL: String?,
            logoURL: String?,
        ) -> [URL] {
            var rawCandidates: [String] = []
            if let imageURL = normalizedPodcastText(imageURL) {
                rawCandidates.append(imageURL)
            }
            if let logoURL = normalizedPodcastText(logoURL) {
                rawCandidates.append(logoURL)
            }
            if let templateURL = normalizedPodcastText(templateURL) {
                rawCandidates.append(templateURL)
                let replacements = [1200, 600]
                for size in replacements {
                    let resolved = templateURL.replacingOccurrences(of: "{w}", with: "\(size)").replacingOccurrences(of: "{h}", with: "\(size)").replacingOccurrences(of: "{f}", with: "jpg")
                    rawCandidates.append(resolved)
                }
            }
            var seen: Set<String> = []
            var urls: [URL] = []
            for raw in rawCandidates {
                guard let url = URL(string: raw) else { continue }
                let key = url.absoluteString
                if seen.insert(key).inserted {
                    urls.append(url)
                }
            }
            return urls
        }

        func sqliteTableColumns(_ database: OpaquePointer?, tableName: String) -> Set<String> {
            guard let database else { return [] }
            let pragma = "PRAGMA table_info(\(tableName));"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, pragma, -1, &statement, nil) == SQLITE_OK, let statement else {
                if statement != nil {
                    sqlite3_finalize(statement)
                }
                return []
            }
            defer { sqlite3_finalize(statement) }
            var columns: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let columnName = sqliteColumnString(statement, 1)?.uppercased() {
                    columns.insert(columnName)
                }
            }
            return columns
        }

        func loadDownloadedPodcastSeriesFromPodcastsAppDatabase() -> [PodcastSeriesEntry] {
            guard let groupContainerURL = podcastsAppGroupContainerURL() else { return [] }
            guard let databaseURL = podcastsAppDatabaseURL() else { return [] }
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: databaseURL.path) else { return [] }
            let artworkFileIndex = podcastsAppArtworkFileIndex(groupContainerURL: groupContainerURL)
            var database: OpaquePointer?
            let openStatus = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
            guard openStatus == SQLITE_OK, let database else {
                if let database {
                    sqlite3_close(database)
                }
                return []
            }
            defer { sqlite3_close(database) }
            let episodeColumns = sqliteTableColumns(database, tableName: "ZMTEPISODE")
            let hiddenFilter = if episodeColumns.contains("ZISHIDDEN") {
                "COALESCE(e.ZISHIDDEN, 0) != 1"
            } else if episodeColumns.contains("ZHIDDEN") {
                "COALESCE(e.ZHIDDEN, 0) != 1"
            } else {
                "1 = 1"
            }
            let deletedFilter: String = episodeColumns.contains("ZUSERDELETED")
                ? "COALESCE(e.ZUSERDELETED, 0) != 1"
                : "1 = 1"
            let query = """
            SELECT
                COALESCE(e.ZUUID, ''),
                COALESCE(e.ZTITLE, ''),
                COALESCE(e.ZITEMDESCRIPTIONWITHOUTHTML, ''),
                COALESCE(e.ZITEMDESCRIPTION, ''),
                COALESCE(e.ZAUTHOR, ''),
                COALESCE(e.ZDURATION, 0),
                COALESCE(e.ZPUBDATE, 0),
                COALESCE(e.ZDOWNLOADDATE, 0),
                COALESCE(e.ZIMPORTDATE, 0),
                COALESCE(e.ZDOWNLOADPATH, ''),
                COALESCE(e.ZASSETURL, ''),
                COALESCE(e.ZVIDEO, 0),
                COALESCE(e.ZARTWORKTEMPLATEURL, ''),
                COALESCE(p.ZUUID, ''),
                COALESCE(p.ZTITLE, ''),
                COALESCE(p.ZAUTHOR, ''),
                COALESCE(p.ZITEMDESCRIPTION, ''),
                COALESCE(p.ZARTWORKTEMPLATEURL, ''),
                COALESCE(p.ZIMAGEURL, ''),
                COALESCE(p.ZLOGOIMAGEURL, '')
            FROM ZMTEPISODE e
            LEFT JOIN ZMTPODCAST p ON p.Z_PK = e.ZPODCAST
            WHERE \(deletedFilter)
              AND \(hiddenFilter)
              AND (
                    (e.ZDOWNLOADPATH IS NOT NULL AND LENGTH(e.ZDOWNLOADPATH) > 0)
                 OR (e.ZASSETURL IS NOT NULL AND e.ZASSETURL LIKE 'file://%')          )
            ORDER BY p.ZTITLE COLLATE NOCASE ASC, e.ZPUBDATE DESC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
                if statement != nil {
                    sqlite3_finalize(statement)
                }
                return []
            }
            defer { sqlite3_finalize(statement) }
            var groupedEpisodes: [String: [PodcastEpisodeEntry]] = [:]
            var groupedTitles: [String: String] = [:]
            var groupedArtists: [String: String] = [:]
            var groupedDescriptions: [String: String] = [:]
            var groupedArtwork: [String: NSImage] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let episodeUUID = normalizedPodcastText(sqliteColumnString(statement, 0))
                let rawEpisodeTitle = normalizedPodcastText(sqliteColumnString(statement, 1))
                let episodeDescriptionWithoutHTML = normalizedPodcastText(sqliteColumnString(statement, 2))
                let episodeDescriptionWithHTML = normalizedPodcastText(sqliteColumnString(statement, 3))
                let episodeAuthor = normalizedPodcastText(sqliteColumnString(statement, 4))
                let durationSeconds = max(0, sqliteColumnDouble(statement, 5))
                let pubDateRaw = sqliteColumnDouble(statement, 6)
                let downloadDateRaw = sqliteColumnDouble(statement, 7)
                let importDateRaw = sqliteColumnDouble(statement, 8)
                let rawDownloadPath = normalizedPodcastText(sqliteColumnString(statement, 9))
                let rawAssetURL = normalizedPodcastText(sqliteColumnString(statement, 10))
                let declaredIsVideo = sqliteColumnInt64(statement, 11) != 0
                let rawEpisodeArtworkTemplateURL = normalizedPodcastText(sqliteColumnString(statement, 12))
                let podcastUUID = normalizedPodcastText(sqliteColumnString(statement, 13))
                let rawSeriesTitle = normalizedPodcastText(sqliteColumnString(statement, 14))
                let rawSeriesAuthor = normalizedPodcastText(sqliteColumnString(statement, 15))
                let rawSeriesDescription = normalizedPodcastText(sqliteColumnString(statement, 16))
                let rawSeriesArtworkTemplateURL = normalizedPodcastText(sqliteColumnString(statement, 17))
                let rawSeriesImageURL = normalizedPodcastText(sqliteColumnString(statement, 18))
                let rawSeriesLogoImageURL = normalizedPodcastText(sqliteColumnString(statement, 19))
                guard let mediaURL = resolvePodcastsAppMediaURL(
                    downloadPath: rawDownloadPath,
                    assetURL: rawAssetURL,
                    groupContainerURL: groupContainerURL,
                ) else {
                    continue
                }
                let seriesTitle = rawSeriesTitle
                    ?? episodeAuthor
                    ?? "Unknown Podcast"
                let seriesArtist = rawSeriesAuthor
                    ?? episodeAuthor
                    ?? "Unknown Artist"
                let seriesKey = podcastUUID ?? "\(seriesTitle.lowercased())::\(seriesArtist.lowercased())"
                let seriesID = "mac::podcasts_app::\(seriesKey)"
                let episodeTitle = rawEpisodeTitle
                    ?? mediaURL.deletingPathExtension().lastPathComponent
                let embeddedDescription = loadPodcastDescriptionFromMediaMetadata(mediaURL)
                let episodeDescription = resolvedPodcastDescription(
                    plainText: episodeDescriptionWithoutHTML,
                    htmlText: episodeDescriptionWithHTML,
                    fallback: embeddedDescription ?? rawSeriesDescription,
                )
                let airedDate = podcastDateFromCoreDataTimestamp(pubDateRaw)
                    ?? podcastDateFromCoreDataTimestamp(downloadDateRaw)
                    ?? podcastDateFromCoreDataTimestamp(importDateRaw)
                let episodeID = episodeUUID ?? "mac::podcasts_app::\(seriesKey)::\(episodeTitle.lowercased())::\(Int(pubDateRaw))"
                let isVideo = resolvedPodcastIsVideo(mediaURL: mediaURL, declaredIsVideo: declaredIsVideo)
                groupedTitles[seriesKey] = seriesTitle
                groupedArtists[seriesKey] = seriesArtist
                if groupedDescriptions[seriesKey] == nil || groupedDescriptions[seriesKey]?.isEmpty == true {
                    groupedDescriptions[seriesKey] = resolvedPodcastDescription(
                        plainText: rawSeriesDescription,
                        htmlText: nil,
                        fallback: embeddedDescription,
                    )
                }
                if groupedArtwork[seriesKey] == nil {
                    groupedArtwork[seriesKey] = loadPodcastsAppArtwork(
                        templateURL: rawSeriesArtworkTemplateURL,
                        imageURL: rawSeriesImageURL,
                        logoURL: rawSeriesLogoImageURL,
                        artworkFileIndex: artworkFileIndex,
                    ) ?? loadPodcastArtworkFromMediaMetadata(mediaURL)
                }
                let episodeArtwork = loadPodcastsAppArtwork(
                    templateURL: rawEpisodeArtworkTemplateURL,
                    imageURL: rawSeriesImageURL,
                    logoURL: rawSeriesLogoImageURL,
                    artworkFileIndex: artworkFileIndex,
                ) ?? loadPodcastArtworkFromMediaMetadata(mediaURL) ?? groupedArtwork[seriesKey]
                let episode = PodcastEpisodeEntry(
                    id: episodeID,
                    seriesID: seriesID,
                    seriesTitle: seriesTitle,
                    title: episodeTitle,
                    artist: episodeAuthor ?? seriesArtist,
                    description: episodeDescription,
                    durationSeconds: durationSeconds,
                    airedDate: airedDate,
                    mediaURL: mediaURL,
                    artwork: episodeArtwork,
                    isVideo: isVideo,
                )
                groupedEpisodes[seriesKey, default: []].append(episode)
            }
            var seriesEntries: [PodcastSeriesEntry] = []
            seriesEntries.reserveCapacity(groupedEpisodes.count)
            for (seriesKey, episodes) in groupedEpisodes {
                guard !episodes.isEmpty else { continue }
                let seriesArtwork = groupedArtwork[seriesKey]
                let seriesID = "mac::podcasts_app::\(seriesKey)"
                let title = groupedTitles[seriesKey] ?? "Unknown Podcast"
                let artist = groupedArtists[seriesKey] ?? "Unknown Artist"
                let description = groupedDescriptions[seriesKey] ?? ""
                let normalizedEpisodes = episodes.map { episode in
                    PodcastEpisodeEntry(
                        id: episode.id,
                        seriesID: episode.seriesID,
                        seriesTitle: episode.seriesTitle,
                        title: episode.title,
                        artist: episode.artist,
                        description: episode.description,
                        durationSeconds: episode.durationSeconds,
                        airedDate: episode.airedDate,
                        mediaURL: episode.mediaURL,
                        artwork: episode.artwork ?? seriesArtwork,
                        isVideo: episode.isVideo,
                    )
                }
                seriesEntries.append(
                    PodcastSeriesEntry(
                        id: seriesID,
                        title: title,
                        artist: artist,
                        description: description,
                        artwork: seriesArtwork,
                        episodes: sortedPodcastEpisodes(normalizedEpisodes),
                    ),
                )
            }
            return seriesEntries.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    #endif
    func enterPodcastEpisodesMenu(for series: PodcastSeriesEntry) {
        transitionMenuForFolderSwap {
            thirdMenuMode = .podcastsEpisodes
            isInThirdMenu = true
            activePodcastSeriesID = series.id
            podcastEpisodesThirdMenuItems = series.episodes
            selectedThirdIndex = min(selectedThirdIndex, max(0, podcastEpisodesThirdMenuItems.count - 1))
            headerText = truncatedPodcastSeriesHeaderTitle(series.title)
            submenuOpacity = 0
            thirdMenuOpacity = 1
            refreshDetailPreviewForCurrentContext()
        }
    }

    func syncPodcastEpisodesForActiveSeries() {
        guard activeRootItemID == "podcasts", isInSubmenu else { return }
        guard thirdMenuMode == .podcastsEpisodes else { return }
        guard let activePodcastSeriesID else {
            podcastEpisodesThirdMenuItems = []
            selectedThirdIndex = 0
            headerText = rootMenuTitle(for: activeRootItemID)
            return
        }
        guard let series = podcastSeriesItems.first(where: { $0.id == activePodcastSeriesID }) else {
            podcastEpisodesThirdMenuItems = []
            selectedThirdIndex = 0
            headerText = rootMenuTitle(for: activeRootItemID)
            return
        }
        podcastEpisodesThirdMenuItems = series.episodes
        selectedThirdIndex = min(selectedThirdIndex, max(0, podcastEpisodesThirdMenuItems.count - 1))
        headerText = truncatedPodcastSeriesHeaderTitle(series.title)
    }

    func truncatedPodcastSeriesHeaderTitle(_ title: String) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return "Podcasts" }
        let font = NSFont(name: firstRowBoldFontName, size: 60) ?? NSFont.boldSystemFont(ofSize: 60)
        let maxWidth: CGFloat = 720
        func measuredWidth(_ value: String) -> CGFloat {
            ceil((value as NSString).size(withAttributes: [.font: font]).width)
        }
        if measuredWidth(normalizedTitle) <= maxWidth {
            return normalizedTitle
        }
        var candidate = normalizedTitle
        while !candidate.isEmpty {
            candidate.removeLast()
            let truncated = "\(candidate)..."
            if measuredWidth(truncated) <= maxWidth {
                return truncated
            }
        }
        return "..."
    }

    func podcastEpisodeLengthText(for durationSeconds: Double) -> String {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return "--:--"
        }
        let wholeSeconds = Int(durationSeconds.rounded())
        let seconds = wholeSeconds % 60
        let totalMinutes = wholeSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    func podcastEpisodeAiredText(for date: Date?) -> String {
        guard let date else { return "--/--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    func podcastEpisodeIsRecent(_ date: Date?) -> Bool {
        guard let date else { return false }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let airedStart = calendar.startOfDay(for: date)
        guard airedStart <= todayStart else { return false }
        guard let dayDelta = calendar.dateComponents([.day], from: airedStart, to: todayStart).day else {
            return false
        }
        return dayDelta <= 7
    }
}

extension MenuView {
    struct PodcastEpisodeEntry: Identifiable {
        let id: String
        let seriesID: String
        let seriesTitle: String
        let title: String
        let artist: String
        let description: String
        let durationSeconds: Double
        let airedDate: Date?
        let mediaURL: URL?
        let artwork: NSImage?
        let isVideo: Bool
    }

    struct PodcastSeriesEntry: Identifiable {
        let id: String
        let title: String
        let artist: String
        let description: String
        let artwork: NSImage?
        let episodes: [PodcastEpisodeEntry]
    }

    var podcastFallbackImage: NSImage? {
        NSImage(named: "Podcast") ?? NSImage(named: "podcasts")
    }
}
