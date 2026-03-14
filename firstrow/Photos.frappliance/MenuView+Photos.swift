import AVFoundation
import Photos
import SwiftUI
#if os(iOS)
    import UIKit
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif

private let photosImageRequestQueue = DispatchQueue(
    label: "firstrow.photos.image-requests",
    qos: .userInitiated,
    attributes: .concurrent,
)

private let photosCarouselArtworkLoadQueue = DispatchQueue(
    label: "firstrow.photos.carousel-artworks",
    qos: .userInitiated,
)

extension MenuView {
    var photosCarouselArtworkLoadLimit: Int {
        #if os(iOS)
            20
        #else
            48
        #endif
    }

    var photosCarouselArtworkTargetSize: CGSize {
        #if os(iOS)
            CGSize(width: 1728, height: 1728)
        #else
            CGSize(width: 2048, height: 2048)
        #endif
    }

    var photosCarouselArtworkDeliveryMode: PHImageRequestOptionsDeliveryMode {
        .highQualityFormat
    }

    var photosAlbumCoverPrefetchRadius: Int {
        #if os(iOS)
            3
        #else
            4
        #endif
    }

    var photosAlbumCoverPrefetchBatchLimit: Int {
        #if os(iOS)
            12
        #else
            14
        #endif
    }

    var photoSlideshowImageTargetSize: CGSize {
        #if os(iOS)
            let nativeSize = activeWindowScreen?.nativeBounds.size ?? CGSize(width: 1920, height: 1080)
            let longestSide = max(nativeSize.width, nativeSize.height)
            let cappedLongestSide = min(max(longestSide, 1920), 2688)
            return CGSize(width: cappedLongestSide, height: cappedLongestSide)
        #else
            CGSize(width: 3200, height: 2000)
        #endif
    }

    var photoSlideshowImageDeliveryMode: PHImageRequestOptionsDeliveryMode {
        .highQualityFormat
    }

    var photoSlideshowPhotoCount: Int {
        photoSlideshowAssetLocalIdentifiers.count
    }

    var photoSlideshowPrefetchRadius: Int {
        #if os(iOS)
            1
        #else
            2
        #endif
    }

    var photoSlideshowCacheLimit: Int {
        #if os(iOS)
            4
        #else
            8
        #endif
    }

    var photoSlideshowFallbackTargetSize: CGSize {
        #if os(iOS)
            CGSize(width: 1536, height: 1536)
        #else
            CGSize(width: 2048, height: 2048)
        #endif
    }

    var photosLastImportAlbum: PhotoLibraryAlbumEntry {
        PhotoLibraryAlbumEntry(
            id: "photos_last_import_album",
            title: "Last Import",
            count: 0,
            assetLocalIdentifiers: [],
            coverAssetLocalIdentifier: nil,
            scope: .lastImport,
            dateGroupDay: nil,
        )
    }

    func photoAlbumForSubmenuItemID(_ submenuItemID: String) -> PhotoLibraryAlbumEntry? {
        switch submenuItemID {
        case "photos_last_12_months":
            photosLastTwelveMonthsAlbum
        case "photos_last_import":
            photosLastImportAlbum
        default:
            nil
        }
    }

    func photoLeadingImage(for album: PhotoLibraryAlbumEntry) -> NSImage? {
        photosAlbumCoverImageCache[album.id]
    }

    func makePhotosDateAlbumMenuItems(from albums: [PhotoLibraryAlbumEntry]) -> [MenuListItemConfig] {
        albums.map { album in
            .init(
                id: album.id,
                title: album.title,
                leadsToMenu: false,
                leadingImageAssetName: "photos",
                leadingImage: nil,
                trailingText: "(\(album.count))",
                trailingSymbolName: nil,
                showsTopDivider: false,
                showsBlueDot: false,
                showsLightRowBackground: true,
                alignsTextToDividerStart: false,
            )
        }
    }

    func refreshPhotosForCurrentContext() {
        guard activeRootItemID == "photos", isInSubmenu else {
            _ = incrementRequestID(&photosCarouselRequestID)
            photosCarouselLoadOverlayOpacity = 0
            return
        }
        requestPhotoLibraryLoadIfNeeded()
        if let photosLastTwelveMonthsAlbum {
            requestPhotoAlbumCoverImageIfNeeded(for: photosLastTwelveMonthsAlbum)
        }
        for album in prioritizedPhotosAlbumsForCoverPrefetch() {
            requestPhotoAlbumCoverImageIfNeeded(for: album)
        }
        refreshPhotosCarouselForCurrentContext()
    }

    func prioritizedPhotosAlbumsForCoverPrefetch() -> [PhotoLibraryAlbumEntry] {
        guard !photosDateAlbums.isEmpty else { return [] }
        let clampedSelectedIndex = min(max(0, selectedThirdIndex), photosDateAlbums.count - 1)
        var resolvedAlbums: [PhotoLibraryAlbumEntry] = []
        var seenAlbumIDs: Set<String> = []
        func appendAlbum(at index: Int) {
            guard photosDateAlbums.indices.contains(index) else { return }
            let album = photosDateAlbums[index]
            guard !seenAlbumIDs.contains(album.id) else { return }
            seenAlbumIDs.insert(album.id)
            resolvedAlbums.append(album)
        }
        appendAlbum(at: clampedSelectedIndex)
        let visibleIndices = visiblePhotosAlbumIndicesForCoverPrefetch()
        if !visibleIndices.isEmpty {
            for index in visibleIndices {
                appendAlbum(at: index)
            }
            if photosAlbumCoverPrefetchRadius > 0 {
                for delta in 1 ... photosAlbumCoverPrefetchRadius {
                    appendAlbum(at: clampedSelectedIndex + delta)
                    appendAlbum(at: clampedSelectedIndex - delta)
                }
            }
        } else if photosAlbumCoverPrefetchRadius > 0 {
            for delta in 1 ... photosAlbumCoverPrefetchRadius {
                appendAlbum(at: clampedSelectedIndex + delta)
                appendAlbum(at: clampedSelectedIndex - delta)
            }
        }
        if resolvedAlbums.count > photosAlbumCoverPrefetchBatchLimit {
            return Array(resolvedAlbums.prefix(photosAlbumCoverPrefetchBatchLimit))
        }
        return resolvedAlbums
    }

    func visiblePhotosAlbumIndicesForCoverPrefetch() -> [Int] {
        guard
            activeRootItemID == "photos",
            isInThirdMenu,
            thirdMenuMode == .photosDateAlbums,
            !photosDateAlbumMenuItems.isEmpty
        else {
            return []
        }
        let menuItems = photosDateAlbumMenuItems
        let clampedSelectedIndex = min(max(0, selectedThirdIndex), menuItems.count - 1)
        let selectionHeightScale = photosSelectionBoxHeightScale
        let rowHeight = selectionBoxHeight * max(1, selectionHeightScale)
        let dividerGap = effectiveDividerSectionGap(forSelectionBoxHeightScale: selectionHeightScale)
        let rowPitch = effectiveRowPitch(forSelectionBoxHeightScale: selectionHeightScale)
        let rowOffsets = menuRowOffsets(
            for: menuItems,
            dividerGap: dividerGap,
            rowPitch: rowPitch,
        )
        let contentHeight = menuContentHeight(
            for: menuItems,
            rowOffsets: rowOffsets,
            rowHeight: rowHeight,
        )
        let viewportHeight = menuViewportHeight(for: thirdLevelVisibleMenuRowCount)
        let scrollOffset = menuScrollOffset(
            contentHeight: contentHeight,
            selectedIndex: clampedSelectedIndex,
            rowOffsets: rowOffsets,
            viewportHeight: viewportHeight,
        )
        var visibleIndices = visibleMenuRowIndices(
            rowOffsets: rowOffsets,
            rowHeight: rowHeight,
            scrollOffset: scrollOffset,
            viewportHeight: viewportHeight,
        )
        if let maxVisibleIndex = visibleIndices.max(),
           menuItems.indices.contains(maxVisibleIndex + 1)
        {
            visibleIndices.append(maxVisibleIndex + 1)
        }
        return visibleIndices
    }

    func refreshPhotosCarouselForCurrentContext() {
        guard let selectedAlbum = selectedPhotoAlbumForCarousel, selectedAlbum.isPlayable else {
            _ = incrementRequestID(&photosCarouselRequestID)
            photosCarouselLoadOverlayOpacity = 0
            return
        }
        let identity = photosCarouselIdentityKey(for: selectedAlbum)
        if photosCarouselIdentity == identity, !photosCarouselArtworks.isEmpty {
            return
        }
        requestPhotosCarouselArtworks(for: selectedAlbum)
    }

    func photosCarouselIdentityKey(for album: PhotoLibraryAlbumEntry) -> String {
        "\(album.id)::\(album.assetLocalIdentifiers.joined(separator: "|"))"
    }

    func requestPhotosCarouselArtworks(for album: PhotoLibraryAlbumEntry) {
        let identity = photosCarouselIdentityKey(for: album)
        photosCarouselIdentity = identity
        if album.assetLocalIdentifiers.isEmpty {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                photosCarouselArtworks = []
                photosCarouselLoadOverlayOpacity = 0
            }
            return
        }
        let requestID = incrementRequestID(&photosCarouselRequestID)
        let localIdentifiers = Array(album.assetLocalIdentifiers.prefix(photosCarouselArtworkLoadLimit))
        let placeholderCount = max(4, min(8, localIdentifiers.count))
        if photosCarouselArtworks.isEmpty {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                photosCarouselArtworks = Array(repeating: nil, count: placeholderCount)
            }
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            photosCarouselLoadOverlayOpacity = 1
        }
        photosCarouselArtworkLoadQueue.async {
            let images = self.loadPhotoImages(
                localIdentifiers: localIdentifiers,
                targetSize: self.photosCarouselArtworkTargetSize,
                contentMode: .aspectFit,
                deliveryMode: self.photosCarouselArtworkDeliveryMode,
                shouldAbort: {
                    self.shouldAbortPhotosCarouselArtworkLoad(
                        requestID: requestID,
                        identity: identity,
                    )
                },
            )
            if self.shouldAbortPhotosCarouselArtworkLoad(requestID: requestID, identity: identity) {
                return
            }
            DispatchQueue.main.async {
                guard self.photosCarouselRequestID == requestID else { return }
                guard self.photosCarouselIdentity == identity else { return }
                guard self.shouldUsePhotosCarouselSlot else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    self.photosCarouselArtworks = images
                }
                withAnimation(.easeInOut(duration: 0.22)) {
                    self.photosCarouselLoadOverlayOpacity = 0
                }
            }
        }
    }

    func shouldAbortPhotosCarouselArtworkLoad(requestID: Int, identity: String) -> Bool {
        let shouldAbort = {
            self.photosCarouselRequestID != requestID ||
                self.photosCarouselIdentity != identity ||
                !self.shouldUsePhotosCarouselSlot
        }
        if Thread.isMainThread {
            return shouldAbort()
        }
        return DispatchQueue.main.sync(execute: shouldAbort)
    }

    func requestPhotoAlbumCoverImageIfNeeded(for album: PhotoLibraryAlbumEntry) {
        guard let coverAssetLocalIdentifier = album.coverAssetLocalIdentifier else { return }
        guard photosAlbumCoverImageCache[album.id] == nil else { return }
        guard !photosAlbumCoverRequestsInFlight.contains(album.id) else { return }
        photosAlbumCoverRequestsInFlight.insert(album.id)
        requestPhotoImage(
            localIdentifier: coverAssetLocalIdentifier,
            targetSize: CGSize(width: 220, height: 220),
            contentMode: .aspectFill,
            deliveryMode: .fastFormat,
        ) { image in
            self.photosAlbumCoverRequestsInFlight.remove(album.id)
            guard let image else { return }
            self.photosAlbumCoverImageCache[album.id] = image
        }
    }

    func requestPhotoLibraryLoadIfNeeded(force: Bool = false) {
        guard activeRootItemID == "photos", isInSubmenu else { return }
        guard force || !photoLibraryHasLoadedAtLeastOnce else { return }
        guard !isLoadingPhotoLibrary else { return }
        let requestID = incrementRequestID(&photoLibraryRequestID)
        isLoadingPhotoLibrary = true
        photoLibraryLoadError = nil
        requestPhotoLibraryAuthorization { isAuthorized in
            guard self.photoLibraryRequestID == requestID else { return }
            guard isAuthorized else {
                self.isLoadingPhotoLibrary = false
                self.photosDateAlbums = []
                self.photosDateAlbumMenuItems = []
                self.photosLastTwelveMonthsAlbum = nil
                self.photoLibraryHasLoadedAtLeastOnce = true
                self.photoLibraryLoadError = "Photos library access denied"
                self.refreshPhotosCarouselForCurrentContext()
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let loadedAlbums = self.loadPhotoLibraryAlbums()
                DispatchQueue.main.async {
                    guard self.photoLibraryRequestID == requestID else { return }
                    guard self.activeRootItemID == "photos", self.isInSubmenu else { return }
                    self.isLoadingPhotoLibrary = false
                    self.photosDateAlbums = loadedAlbums.dateAlbums
                    self.photosDateAlbumMenuItems = self.makePhotosDateAlbumMenuItems(from: loadedAlbums.dateAlbums)
                    self.photosLastTwelveMonthsAlbum = loadedAlbums.lastTwelveMonths
                    self.photoLibraryHasLoadedAtLeastOnce = true
                    self.photoLibraryLoadError = nil
                    self.selectedThirdIndex = min(self.selectedThirdIndex, max(0, self.photosDateAlbums.count - 1))
                    self.refreshPhotosForCurrentContext()
                    if self.thirdMenuMode == .photosDateAlbums, self.photosDateAlbums.isEmpty {
                        self.abortPhotosDateAlbumsMenuEntryForEmptyLibrary()
                    }
                }
            }
        }
    }

    func requestPhotoLibraryAuthorization(_ completion: @escaping (Bool) -> Void) {
        #if canImport(Photos)
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            switch status {
            case .authorized, .limited:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    DispatchQueue.main.async {
                        completion(newStatus == .authorized || newStatus == .limited)
                    }
                }
            @unknown default:
                completion(false)
            }
        #else
            completion(false)
        #endif
    }

    func enterPhotosDateAlbumsMenu(title: String) {
        if photoLibraryHasLoadedAtLeastOnce,
           !isLoadingPhotoLibrary,
           photoLibraryLoadError == nil,
           photosDateAlbums.isEmpty
        {
            presentNoPhotosLibraryFeatureErrorScreen()
            return
        }
        transitionMenuForFolderSwap(
            useOverlayFade: true,
            revealWhen: { !isLoadingPhotoLibrary },
        ) {
            thirdMenuMode = .photosDateAlbums
            isInThirdMenu = true
            selectedThirdIndex = min(selectedThirdIndex, max(0, photosDateAlbums.count - 1))
            headerText = title
            submenuOpacity = 0
            thirdMenuOpacity = 1
            requestPhotoLibraryLoadIfNeeded()
            refreshDetailPreviewForCurrentContext()
        }
    }

    func presentNoMoviesLibraryFeatureErrorScreen(afterMenuSwap: Bool = false) {
        presentFeatureErrorScreen(
            .noMoviesInFolder,
            usingExistingBlackout: afterMenuSwap,
        )
    }

    func presentNoPhotosLibraryFeatureErrorScreen(afterMenuSwap: Bool = false) {
        presentFeatureErrorScreen(
            .noPhotosInLibrary,
            usingExistingBlackout: afterMenuSwap,
        )
    }

    func abortPhotosDateAlbumsMenuEntryForEmptyLibrary() {
        guard thirdMenuMode == .photosDateAlbums else { return }
        isInThirdMenu = false
        thirdMenuMode = .none
        thirdMenuOpacity = 0
        submenuOpacity = 1
        headerText = rootMenuTitle(for: activeRootItemID)
        selectedThirdIndex = 0
        refreshDetailPreviewForCurrentContext()
        presentNoPhotosLibraryFeatureErrorScreen(afterMenuSwap: true)
    }

    func startPhotoAlbumSlideshow(for album: PhotoLibraryAlbumEntry) {
        guard album.isPlayable else { return }
        guard !isMovieTransitioning, !isMoviePlaybackVisible else { return }
        guard !isFullscreenSceneTransitioning else { return }
        resetScreenSaverIdleTimer()
        let requestID = incrementRequestID(&photoSlideshowRequestID)
        stopMusicPlaybackSession(clearDisplayState: false)
        stopPhotoSlideshowMusic()
        photoSlideshowAssetLocalIdentifiers = []
        photoSlideshowImageCache = [:]
        photoSlideshowImageRequestsInFlight = []
        photoSlideshowImageFallbackAttempted = []
        photoSlideshowVisiblePrimaryIndex = 0
        photoSlideshowVisibleSecondaryIndex = nil
        photoSlideshowAlbumTitle = album.title
        photoSlideshowPlaybackStartDate = Date()
        photoSlideshowPlaybackElapsedOffset = 0
        photoSlideshowIsPaused = false
        photoSlideshowPausedIndex = 0
        photoSlideshowDidSeekWhilePaused = false
        photoSlideshowHasFinished = false
        photoSlideshowResolvedMusicEntry = nil
        photoSlideshowMusicURL = nil
        photoSlideshowMusicFallbackWorkItem?.cancel()
        photoSlideshowMusicFallbackWorkItem = nil
        photoSlideshowMusicHasStarted = false
        photoSlideshowUsesAppleScriptMusic = false
        activeFullscreenScene = nil
        fullscreenSceneOpacity = 0
        fullscreenTransitionOverlayOpacity = 0
        isFullscreenSceneTransitioning = true
        withAnimation(.easeInOut(duration: photoSlideshowMenuFadeDuration)) {
            fullscreenTransitionOverlayOpacity = 1
        }
        let menuHideDelay = photoSlideshowMenuFadeDuration + fullscreenOverlayBlackoutSafetyDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + menuHideDelay) {
            guard self.photoSlideshowRequestID == requestID else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.fullscreenTransitionOverlayOpacity = 1
                self.menuSceneOpacity = 0
            }
        }
        loadPhotoSlideshowImages(for: album, requestID: requestID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard self.photoSlideshowRequestID == requestID else { return }
            self.activeFullscreenScene = FullscreenScenePresentation(key: self.photoSlideshowFullscreenKey, payload: [:])
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.fullscreenSceneOpacity = 1
                self.fullscreenTransitionOverlayOpacity = 0
            }
            self.isFullscreenSceneTransitioning = false
            self.resolvePhotoSlideshowMusicURL(forRequestID: requestID)
        }
    }

    func resolvePhotoSlideshowMusicURL(forRequestID requestID: Int) {
        requestMusicLibraryAuthorization { isAuthorized in
            guard self.photoSlideshowRequestID == requestID else { return }
            guard isAuthorized else {
                self.photoSlideshowResolvedMusicEntry = nil
                self.photoSlideshowMusicURL = self.defaultPhotoSlideshowMusicURL()
                self.startPhotoSlideshowBackgroundMusicFromResolvedSourceIfNeeded()
                return
            }
            if let cachedSong = self.randomCachedMusicLibrarySong() {
                self.photoSlideshowResolvedMusicEntry = cachedSong
                self.photoSlideshowMusicURL = nil
                self.startPhotoSlideshowBackgroundMusicFromResolvedSourceIfNeeded()
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let resolvedSong: MusicLibrarySongEntry?
                let snapshot: (
                    sortedSongs: [MusicLibrarySongEntry],
                    shuffleSongs: [MusicLibrarySongEntry],
                    itemIndices: [String: Int],
                    artworkDataByAlbumKey: [String: Data],
                )?
                do {
                    let loadedSnapshot = try self.loadStartupMusicLibrarySnapshot()
                    snapshot = loadedSnapshot
                    resolvedSong = loadedSnapshot.shuffleSongs.randomElement()
                } catch {
                    snapshot = nil
                    resolvedSong = nil
                }
                DispatchQueue.main.async {
                    guard self.photoSlideshowRequestID == requestID else { return }
                    if let snapshot {
                        self.musicAllSongsCache = snapshot.sortedSongs
                        self.musicShuffleSongsCache = snapshot.shuffleSongs
                        #if canImport(iTunesLibrary)
                            self.musicLibraryItemIndexBySongID = snapshot.itemIndices
                            self.musicLibraryArtworkDataByAlbumKey = snapshot.artworkDataByAlbumKey
                        #endif
                    }
                    self.photoSlideshowResolvedMusicEntry = resolvedSong
                    self.photoSlideshowMusicURL = resolvedSong == nil ? self.defaultPhotoSlideshowMusicURL() : nil
                    self.startPhotoSlideshowBackgroundMusicFromResolvedSourceIfNeeded()
                }
            }
        }
    }

    func fetchRandomPhotoSlideshowMusicSong() throws -> MusicLibrarySongEntry? {
        if let cachedSong = randomCachedMusicLibrarySong() {
            return cachedSong
        }
        let snapshot = try loadStartupMusicLibrarySnapshot()
        return snapshot.shuffleSongs.randomElement()
    }

    func loadPhotoSlideshowImages(for album: PhotoLibraryAlbumEntry, requestID: Int) {
        let identifiers = album.assetLocalIdentifiers
        DispatchQueue.main.async {
            guard self.photoSlideshowRequestID == requestID else { return }
            self.photoSlideshowAssetLocalIdentifiers = identifiers
            self.photoSlideshowImageCache = [:]
            self.photoSlideshowImageRequestsInFlight = []
            self.photoSlideshowImageFallbackAttempted = []
            self.photoSlideshowVisiblePrimaryIndex = 0
            self.photoSlideshowVisibleSecondaryIndex = nil
            if identifiers.isEmpty {
                if self.activeFullscreenScene?.key == self.photoSlideshowFullscreenKey {
                    self.handlePhotoSlideshowPlaybackFinished()
                } else {
                    self.stopPhotoSlideshowMusic()
                    self.resetPhotoSlideshowState()
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        self.menuSceneOpacity = 1
                    }
                    withAnimation(.easeInOut(duration: self.photoSlideshowMenuRevealDuration)) {
                        self.fullscreenTransitionOverlayOpacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.photoSlideshowMenuRevealDuration) {
                        guard self.photoSlideshowRequestID == requestID else { return }
                        self.resetScreenSaverIdleTimer()
                        self.isFullscreenSceneTransitioning = false
                    }
                }
                return
            }
            self.prefetchPhotoSlideshowImages(
                aroundPrimaryIndex: 0,
                secondaryIndex: nil,
                requestID: requestID,
            )
        }
    }

    func startPhotoSlideshowBackgroundMusicFromResolvedSourceIfNeeded() {
        guard !photoSlideshowMusicHasStarted else { return }
        photoSlideshowMusicFallbackWorkItem?.cancel()
        photoSlideshowMusicFallbackWorkItem = nil
        if let resolvedSong = photoSlideshowResolvedMusicEntry {
            photoSlideshowMusicHasStarted = true
            startMusicPlayback(
                from: resolvedSong,
                trackIndex: 0,
                trackCount: 1,
                presentsFullscreen: false,
                playbackQueue: [resolvedSong],
            )
            return
        }
        guard let urlToPlay = photoSlideshowMusicURL ?? defaultPhotoSlideshowMusicURL() else { return }
        photoSlideshowMusicHasStarted = true
        startLoopingPhotoSlideshowMusic(from: urlToPlay)
    }

    func startLoopingPhotoSlideshowMusic(from url: URL) {
        stopMusicPlaybackSession(clearDisplayState: false)
        photoSlideshowMusicPlayer?.pause()
        photoSlideshowMusicPlayer = nil
        if let photoSlideshowMusicDidEndObserver {
            NotificationCenter.default.removeObserver(photoSlideshowMusicDidEndObserver)
        }
        photoSlideshowMusicDidEndObserver = nil
        observedPhotoSlideshowMusicPlayer = nil
        #if os(macOS)
            if photoSlideshowUsesAppleScriptMusic {
                pauseMusicPlaybackViaAppleScript()
            }
        #endif
        photoSlideshowUsesAppleScriptMusic = false
        let player = AVPlayer(url: url)
        observedPhotoSlideshowMusicPlayer = player
        photoSlideshowMusicPlayer = player
        if let currentItem = player.currentItem {
            photoSlideshowMusicDidEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main,
            ) { _ in
                guard self.observedPhotoSlideshowMusicPlayer === player else { return }
                player.seek(to: .zero)
                player.playImmediately(atRate: 1.0)
            }
        }
        player.playImmediately(atRate: 1.0)
    }

    func stopPhotoSlideshowMusic() {
        photoSlideshowMusicFallbackWorkItem?.cancel()
        photoSlideshowMusicFallbackWorkItem = nil
        stopMusicPlaybackSession(clearDisplayState: false)
        #if os(macOS)
            if photoSlideshowUsesAppleScriptMusic {
                pauseMusicPlaybackViaAppleScript()
            }
        #endif
        photoSlideshowUsesAppleScriptMusic = false
        photoSlideshowMusicHasStarted = false
        photoSlideshowMusicPlayer?.pause()
        photoSlideshowMusicPlayer = nil
        if let photoSlideshowMusicDidEndObserver {
            NotificationCenter.default.removeObserver(photoSlideshowMusicDidEndObserver)
        }
        photoSlideshowMusicDidEndObserver = nil
        observedPhotoSlideshowMusicPlayer = nil
    }

    func defaultPhotoSlideshowMusicURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "default", withExtension: "mp3") {
            return bundled
        }
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("default.mp3", isDirectory: false),
            cwd.appendingPathComponent("firstRow/default.mp3", isDirectory: false),
        ]
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    func handlePhotoSlideshowInput(_ key: KeyCode, isRepeat: Bool) {
        _ = isRepeat
        switch key {
        case .space:
            if photoSlideshowIsPaused {
                resumePhotoSlideshow()
            } else {
                pausePhotoSlideshow()
            }
        case .leftArrow:
            guard photoSlideshowIsPaused else { return }
            movePhotoSlideshowPausedSelection(direction: -1)
        case .rightArrow:
            guard photoSlideshowIsPaused else { return }
            movePhotoSlideshowPausedSelection(direction: 1)
        case .delete, .escape:
            playSound(named: "Exit")
            photoSlideshowHasFinished = true
            endPhotoSlideshowAndReturnToMenu()
        default:
            return
        }
    }

    func pausePhotoSlideshow() {
        guard !photoSlideshowIsPaused else { return }
        let photoCount = photoSlideshowPhotoCount
        photoSlideshowPlaybackElapsedOffset = photoSlideshowCurrentElapsed()
        photoSlideshowIsPaused = true
        photoSlideshowPausedIndex = photoSlideshowIndex(
            at: photoSlideshowPlaybackElapsedOffset,
            photoCount: photoCount,
        )
        photoSlideshowDidSeekWhilePaused = false
        updatePhotoSlideshowVisibleIndices(primaryIndex: photoSlideshowPausedIndex, secondaryIndex: nil)
    }

    func resumePhotoSlideshow() {
        guard photoSlideshowIsPaused else { return }
        let photoCount = photoSlideshowPhotoCount
        if photoSlideshowDidSeekWhilePaused {
            photoSlideshowPlaybackElapsedOffset = photoSlideshowElapsedStart(
                forPhotoIndex: photoSlideshowPausedIndex,
                photoCount: photoCount,
            )
        }
        photoSlideshowPlaybackStartDate = Date()
        photoSlideshowIsPaused = false
        photoSlideshowDidSeekWhilePaused = false
    }

    func movePhotoSlideshowPausedSelection(direction: Int) {
        let photoCount = photoSlideshowPhotoCount
        guard photoCount > 0 else { return }
        let nextIndex = min(
            max(0, photoSlideshowPausedIndex + direction),
            photoCount - 1,
        )
        guard nextIndex != photoSlideshowPausedIndex else {
            playLimitSoundOnceForCurrentHold()
            return
        }
        photoSlideshowPausedIndex = nextIndex
        photoSlideshowDidSeekWhilePaused = true
        updatePhotoSlideshowVisibleIndices(primaryIndex: nextIndex, secondaryIndex: nil)
        playSound(named: "SelectionChange")
    }

    func photoSlideshowCurrentElapsed(at date: Date = Date()) -> TimeInterval {
        if photoSlideshowIsPaused {
            return photoSlideshowPlaybackElapsedOffset
        }
        return max(
            0,
            photoSlideshowPlaybackElapsedOffset + date.timeIntervalSince(photoSlideshowPlaybackStartDate),
        )
    }

    func photoSlideshowTotalDuration(photoCount: Int) -> TimeInterval {
        guard photoCount > 0 else { return 0 }
        let transitionBlock = photoSlideshowPhotoDisplayDuration + photoSlideshowCrossfadeDuration
        return (Double(max(0, photoCount - 1)) * transitionBlock) + photoSlideshowPhotoDisplayDuration
    }

    func photoSlideshowIndex(at elapsed: TimeInterval, photoCount: Int) -> Int {
        guard photoCount > 1 else { return 0 }
        let transitionBlock = photoSlideshowPhotoDisplayDuration + photoSlideshowCrossfadeDuration
        let totalDuration = photoSlideshowTotalDuration(photoCount: photoCount)
        let clamped = min(max(0, elapsed), totalDuration)
        let segment = Int(clamped / transitionBlock)
        return min(max(0, segment), photoCount - 1)
    }

    func photoSlideshowElapsedStart(forPhotoIndex index: Int, photoCount: Int) -> TimeInterval {
        guard photoCount > 1 else { return 0 }
        let clampedIndex = min(max(0, index), photoCount - 1)
        let transitionBlock = photoSlideshowPhotoDisplayDuration + photoSlideshowCrossfadeDuration
        return Double(clampedIndex) * transitionBlock
    }

    func handlePhotoSlideshowPlaybackFinished() {
        guard !photoSlideshowHasFinished else { return }
        photoSlideshowHasFinished = true
        endPhotoSlideshowAndReturnToMenu()
    }

    func endPhotoSlideshowAndReturnToMenu() {
        guard !isFullscreenSceneTransitioning else { return }
        guard activeFullscreenScene?.key == photoSlideshowFullscreenKey else { return }
        isFullscreenSceneTransitioning = true
        withAnimation(.easeInOut(duration: photoSlideshowMenuFadeDuration)) {
            fullscreenTransitionOverlayOpacity = 1
            fullscreenSceneOpacity = 0
        }
        let sceneDismissDelay = photoSlideshowMenuFadeDuration + fullscreenOverlayBlackoutSafetyDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + sceneDismissDelay) {
            guard self.isFullscreenSceneTransitioning else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.fullscreenTransitionOverlayOpacity = 1
            }
            activeFullscreenScene = nil
            stopPhotoSlideshowMusic()
            resetPhotoSlideshowState()
            DispatchQueue.main.asyncAfter(deadline: .now() + photoSlideshowExitHoldDuration) {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    menuSceneOpacity = 1
                }
                withAnimation(.easeInOut(duration: photoSlideshowMenuRevealDuration)) {
                    fullscreenTransitionOverlayOpacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + photoSlideshowMenuRevealDuration) {
                    resetScreenSaverIdleTimer()
                    isFullscreenSceneTransitioning = false
                }
            }
        }
    }

    func resetPhotoSlideshowState() {
        photoSlideshowAssetLocalIdentifiers = []
        photoSlideshowImageCache = [:]
        photoSlideshowImageRequestsInFlight = []
        photoSlideshowImageFallbackAttempted = []
        photoSlideshowVisiblePrimaryIndex = 0
        photoSlideshowVisibleSecondaryIndex = nil
        photoSlideshowAlbumTitle = ""
        photoSlideshowPlaybackElapsedOffset = 0
        photoSlideshowPlaybackStartDate = Date()
        photoSlideshowIsPaused = false
        photoSlideshowPausedIndex = 0
        photoSlideshowDidSeekWhilePaused = false
        photoSlideshowHasFinished = false
        photoSlideshowResolvedMusicEntry = nil
        photoSlideshowMusicURL = nil
        photoSlideshowMusicFallbackWorkItem?.cancel()
        photoSlideshowMusicFallbackWorkItem = nil
        photoSlideshowMusicHasStarted = false
        photoSlideshowUsesAppleScriptMusic = false
        fullscreenSceneOpacity = 0
    }

    func updatePhotoSlideshowVisibleIndices(primaryIndex: Int, secondaryIndex: Int?) {
        guard photoSlideshowPhotoCount > 0 else { return }
        let clampedPrimary = min(max(0, primaryIndex), photoSlideshowPhotoCount - 1)
        let clampedSecondary = secondaryIndex.map { min(max(0, $0), photoSlideshowPhotoCount - 1) }
        if photoSlideshowVisiblePrimaryIndex == clampedPrimary,
           photoSlideshowVisibleSecondaryIndex == clampedSecondary
        {
            return
        }
        photoSlideshowVisiblePrimaryIndex = clampedPrimary
        photoSlideshowVisibleSecondaryIndex = clampedSecondary
        prefetchPhotoSlideshowImages(
            aroundPrimaryIndex: clampedPrimary,
            secondaryIndex: clampedSecondary,
            requestID: photoSlideshowRequestID,
        )
    }

    func prefetchPhotoSlideshowImages(
        aroundPrimaryIndex primaryIndex: Int,
        secondaryIndex: Int?,
        requestID: Int,
    ) {
        guard photoSlideshowRequestID == requestID else { return }
        guard photoSlideshowPhotoCount > 0 else { return }
        let desiredIndices = photoSlideshowDesiredIndices(
            aroundPrimaryIndex: primaryIndex,
            secondaryIndex: secondaryIndex,
        )
        for index in desiredIndices {
            requestPhotoSlideshowImageIfNeeded(at: index, requestID: requestID)
        }
        trimPhotoSlideshowImageCache(keeping: Set(desiredIndices))
    }

    func photoSlideshowDesiredIndices(
        aroundPrimaryIndex primaryIndex: Int,
        secondaryIndex: Int?,
    ) -> [Int] {
        guard photoSlideshowPhotoCount > 0 else { return [] }
        var ordered: [Int] = []
        func appendIfValid(_ index: Int) {
            guard index >= 0, index < photoSlideshowPhotoCount else { return }
            if !ordered.contains(index) {
                ordered.append(index)
            }
        }
        appendIfValid(primaryIndex)
        if let secondaryIndex {
            appendIfValid(secondaryIndex)
        }
        if photoSlideshowPrefetchRadius > 0 {
            for delta in 1 ... photoSlideshowPrefetchRadius {
                appendIfValid(primaryIndex + delta)
                appendIfValid(primaryIndex - delta)
                if let secondaryIndex {
                    appendIfValid(secondaryIndex + delta)
                    appendIfValid(secondaryIndex - delta)
                }
            }
        }
        return ordered
    }

    func requestPhotoSlideshowImageIfNeeded(at index: Int, requestID: Int) {
        guard photoSlideshowRequestID == requestID else { return }
        guard index >= 0, index < photoSlideshowPhotoCount else { return }
        guard photoSlideshowImageCache[index] == nil else { return }
        guard !photoSlideshowImageRequestsInFlight.contains(index) else { return }
        let localIdentifier = photoSlideshowAssetLocalIdentifiers[index]
        photoSlideshowImageRequestsInFlight.insert(index)
        requestPhotoImage(
            localIdentifier: localIdentifier,
            targetSize: photoSlideshowImageTargetSize,
            contentMode: .aspectFit,
            deliveryMode: photoSlideshowImageDeliveryMode,
        ) { image in
            guard self.photoSlideshowRequestID == requestID else {
                self.photoSlideshowImageRequestsInFlight.remove(index)
                return
            }
            guard self.photoSlideshowAssetLocalIdentifiers.indices.contains(index),
                  self.photoSlideshowAssetLocalIdentifiers[index] == localIdentifier
            else {
                self.photoSlideshowImageRequestsInFlight.remove(index)
                return
            }
            if let image {
                self.photoSlideshowImageRequestsInFlight.remove(index)
                self.photoSlideshowImageCache[index] = image
                self.trimPhotoSlideshowImageCache(
                    keeping: Set(
                        self.photoSlideshowDesiredIndices(
                            aroundPrimaryIndex: self.photoSlideshowVisiblePrimaryIndex,
                            secondaryIndex: self.photoSlideshowVisibleSecondaryIndex,
                        ),
                    ),
                )
                return
            }
            guard !self.photoSlideshowImageFallbackAttempted.contains(index) else {
                self.photoSlideshowImageRequestsInFlight.remove(index)
                return
            }
            self.photoSlideshowImageFallbackAttempted.insert(index)
            self.requestPhotoImage(
                localIdentifier: localIdentifier,
                targetSize: self.photoSlideshowFallbackTargetSize,
                contentMode: .aspectFit,
                deliveryMode: .fastFormat,
            ) { fallbackImage in
                guard self.photoSlideshowRequestID == requestID else {
                    self.photoSlideshowImageRequestsInFlight.remove(index)
                    return
                }
                guard self.photoSlideshowAssetLocalIdentifiers.indices.contains(index),
                      self.photoSlideshowAssetLocalIdentifiers[index] == localIdentifier
                else {
                    self.photoSlideshowImageRequestsInFlight.remove(index)
                    return
                }
                self.photoSlideshowImageRequestsInFlight.remove(index)
                if let fallbackImage {
                    self.photoSlideshowImageCache[index] = fallbackImage
                    self.trimPhotoSlideshowImageCache(
                        keeping: Set(
                            self.photoSlideshowDesiredIndices(
                                aroundPrimaryIndex: self.photoSlideshowVisiblePrimaryIndex,
                                secondaryIndex: self.photoSlideshowVisibleSecondaryIndex,
                            ),
                        ),
                    )
                }
            }
        }
    }

    func trimPhotoSlideshowImageCache(keeping keepSet: Set<Int>) {
        var retained = keepSet
        retained.insert(photoSlideshowVisiblePrimaryIndex)
        if let secondary = photoSlideshowVisibleSecondaryIndex {
            retained.insert(secondary)
        }
        photoSlideshowImageCache = photoSlideshowImageCache.filter { retained.contains($0.key) }
        photoSlideshowImageFallbackAttempted.formIntersection(retained)
        if photoSlideshowImageCache.count <= photoSlideshowCacheLimit {
            return
        }
        let sortedKeys = photoSlideshowImageCache.keys.sorted { lhs, rhs in
            let lhsDistance = abs(lhs - photoSlideshowVisiblePrimaryIndex)
            let rhsDistance = abs(rhs - photoSlideshowVisiblePrimaryIndex)
            if lhsDistance == rhsDistance {
                return lhs < rhs
            }
            return lhsDistance < rhsDistance
        }
        let allowed = Set(sortedKeys.prefix(photoSlideshowCacheLimit))
        photoSlideshowImageCache = photoSlideshowImageCache.filter { allowed.contains($0.key) }
        photoSlideshowImageFallbackAttempted.formIntersection(allowed)
    }
}

extension MenuView {
    func loadPhotoLibraryAlbums() -> (dateAlbums: [PhotoLibraryAlbumEntry], lastTwelveMonths: PhotoLibraryAlbumEntry?) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let calendar = Calendar.current
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.dateFormat = "MMM"
        func ordinalSuffix(for day: Int) -> String {
            let remainder = day % 100
            if remainder >= 11, remainder <= 13 {
                return "th"
            }
            switch day % 10 {
            case 1:
                return "st"
            case 2:
                return "nd"
            case 3:
                return "rd"
            default:
                return "th"
            }
        }
        func formattedAlbumDate(_ date: Date) -> String {
            let components = calendar.dateComponents([.day, .year], from: date)
            let day = components.day ?? 0
            let year = components.year ?? 0
            let month = monthFormatter.string(from: date)
            return "\(month) \(day)\(ordinalSuffix(for: day)), \(year)"
        }
        let thresholdDate = calendar.date(byAdding: .month, value: -12, to: Date()) ?? .distantPast
        var dateBuckets: [Date: [String]] = [:]
        var orderedDays: [Date] = []
        var lastTwelveMonthIDs: [String] = []
        assets.enumerateObjects { asset, _, _ in
            guard let creationDate = asset.creationDate else { return }
            if creationDate >= thresholdDate {
                lastTwelveMonthIDs.append(asset.localIdentifier)
            }
            let startOfDay = calendar.startOfDay(for: creationDate)
            if dateBuckets[startOfDay] == nil {
                orderedDays.append(startOfDay)
                dateBuckets[startOfDay] = []
            }
            dateBuckets[startOfDay, default: []].append(asset.localIdentifier)
        }
        let dayIDFormatter = DateFormatter()
        dayIDFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayIDFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayIDFormatter.dateFormat = "yyyy-MM-dd"
        let dateAlbums = orderedDays.compactMap { day -> PhotoLibraryAlbumEntry? in
            guard let ids = dateBuckets[day], !ids.isEmpty else { return nil }
            return PhotoLibraryAlbumEntry(
                id: "photos_date_\(dayIDFormatter.string(from: day))",
                title: formattedAlbumDate(day),
                count: ids.count,
                assetLocalIdentifiers: ids,
                coverAssetLocalIdentifier: ids.first,
                scope: .dateGroup,
                dateGroupDay: day,
            )
        }
        let lastTwelveMonthsAlbum = PhotoLibraryAlbumEntry(
            id: "photos_last_12_months_album",
            title: "Last 12 Months",
            count: lastTwelveMonthIDs.count,
            assetLocalIdentifiers: lastTwelveMonthIDs,
            coverAssetLocalIdentifier: lastTwelveMonthIDs.first,
            scope: .last12Months,
            dateGroupDay: nil,
        )
        return (dateAlbums: dateAlbums, lastTwelveMonths: lastTwelveMonthsAlbum)
    }

    func requestPhotoImage(
        localIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        isSynchronous: Bool = false,
        completion: @escaping (NSImage?) -> Void,
    ) {
        let performRequest = {
            let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = fetchedAssets.firstObject else {
                if Thread.isMainThread {
                    completion(nil)
                } else {
                    DispatchQueue.main.async {
                        completion(nil)
                    }
                }
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = isSynchronous
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: normalizedPhotoTargetSize(targetSize, deliveryMode: deliveryMode),
                contentMode: contentMode,
                options: options,
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled {
                    if Thread.isMainThread {
                        completion(nil)
                    } else {
                        DispatchQueue.main.async {
                            completion(nil)
                        }
                    }
                    return
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isSynchronous, isDegraded {
                    return
                }
                if Thread.isMainThread {
                    completion(image)
                } else {
                    DispatchQueue.main.async {
                        completion(image)
                    }
                }
            }
        }
        if isSynchronous || !Thread.isMainThread {
            performRequest()
        } else {
            photosImageRequestQueue.async(execute: performRequest)
        }
    }

    func loadPhotoImages(
        localIdentifiers: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        shouldAbort: (() -> Bool)? = nil,
    ) -> [NSImage?] {
        guard !localIdentifiers.isEmpty else { return [] }
        if shouldAbort?() == true {
            return []
        }
        let resolvedTargetSize = normalizedPhotoTargetSize(targetSize, deliveryMode: deliveryMode)
        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        fetchedAssets.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = deliveryMode == .highQualityFormat ? .exact : .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = true
        let manager = PHImageManager.default()
        var images: [NSImage?] = []
        images.reserveCapacity(localIdentifiers.count)
        for localIdentifier in localIdentifiers {
            if shouldAbort?() == true {
                break
            }
            autoreleasepool {
                guard let asset = assetsByID[localIdentifier] else {
                    images.append(nil)
                    return
                }
                var requestedImage: NSImage?
                manager.requestImage(
                    for: asset,
                    targetSize: resolvedTargetSize,
                    contentMode: contentMode,
                    options: options,
                ) { image, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    if cancelled {
                        requestedImage = nil
                        return
                    }
                    requestedImage = image
                }
                images.append(requestedImage)
            }
        }
        return images
    }

    func normalizedPhotoTargetSize(
        _ targetSize: CGSize,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
    ) -> CGSize {
        let safeWidth = max(1, targetSize.width)
        let safeHeight = max(1, targetSize.height)
        let maxRequestedDimension: CGFloat
        #if os(iOS)
            if deliveryMode == .highQualityFormat {
                maxRequestedDimension = 2688
            } else {
                maxRequestedDimension = 1536
            }
        #else
            if deliveryMode == .highQualityFormat {
                maxRequestedDimension = 3200
            } else {
                maxRequestedDimension = 2048
            }
        #endif
        let longestSide = max(safeWidth, safeHeight)
        guard longestSide > maxRequestedDimension else {
            return CGSize(width: safeWidth, height: safeHeight)
        }
        let scale = maxRequestedDimension / longestSide
        return CGSize(
            width: max(1, floor(safeWidth * scale)),
            height: max(1, floor(safeHeight * scale)),
        )
    }
}

extension MenuView {
    struct PhotoLibraryAlbumEntry: Identifiable {
        enum Scope {
            case last12Months
            case dateGroup
            case lastImport
        }

        let id: String
        let title: String
        let count: Int
        let assetLocalIdentifiers: [String]
        let coverAssetLocalIdentifier: String?
        let scope: Scope
        let dateGroupDay: Date?
        var isPlayable: Bool {
            scope != .lastImport && !assetLocalIdentifiers.isEmpty
        }
    }
}
