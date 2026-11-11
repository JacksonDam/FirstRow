import AVFoundation
#if canImport(Photos)
    import Photos
#endif
import Foundation
import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif
#if os(iOS)
    import UIKit
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif

extension MenuView {
    /// How many of an album's pictures the carousel shows. Each is a whole bitmap in memory while
    /// the album is selected.
    var photosCarouselArtworkLoadLimit: Int {
        #if os(iOS) || os(tvOS)
            12
        #else
            24
        #endif
    }

    var photosCarouselArtworkTargetSize: CGSize {
        #if os(iOS) || os(tvOS)
            CGSize(width: 1280, height: 1280)
        #else
            CGSize(width: 1600, height: 1600)
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

    /// How many day covers are kept: the ones nearest the selected day.
    var photosAlbumCoverCacheLimit: Int {
        #if os(iOS) || os(tvOS)
            240
        #else
            600
        #endif
    }

    var photoSlideshowImageTargetSize: CGSize {
        #if os(iOS)
            let nativeSize = activeWindowScreen?.nativeBounds.size ?? CGSize(width: 1920, height: 1080)
            let longestSide = max(nativeSize.width, nativeSize.height)
            let cappedLongestSide = min(max(longestSide, 1920), 2688)
            return CGSize(width: cappedLongestSide, height: cappedLongestSide)
        #elseif os(tvOS)
            CGSize(width: 1920, height: 1920)
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
        #if os(iOS) || os(tvOS)
            1
        #else
            2
        #endif
    }

    var photoSlideshowCacheLimit: Int {
        #if os(iOS) || os(tvOS)
            4
        #else
            8
        #endif
    }

    var photoSlideshowFallbackTargetSize: CGSize {
        #if os(iOS) || os(tvOS)
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
            photosSourceAlbums.first { $0.id == submenuItemID }
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
        // (Once: with no folders chosen there are none to find, however often it's asked.)
        if !hasRequestedPhotoSourceAlbums {
            requestPhotoSourceAlbumsLoad()
        }
        if let photosLastTwelveMonthsAlbum {
            requestPhotoAlbumCoverImageIfNeeded(for: photosLastTwelveMonthsAlbum)
        }
        for album in prioritizedPhotosAlbumsForCoverPrefetch() {
            requestPhotoAlbumCoverImageIfNeeded(for: album)
        }
        refreshPhotosCarouselForCurrentContext()
    }

    /// A list of days moved by a finger or the wheel shows other rows than the selected one's
    /// neighbours: their covers are asked for as it goes (a few times a second), and once more
    /// when it has stopped.
    func requestPhotoCoversForScrolledList() {
        guard activeRootItemID == "photos", isInThirdMenu, thirdMenuMode == .photosDateAlbums else { return }
        let now = CACurrentMediaTime()
        guard now - lastPhotosScrollCoverRequestTime >= 0.1 else {
            guard !isPhotosScrollCoverRequestPending else { return }
            isPhotosScrollCoverRequestPending = true
            Task {
                try? await firstRowSleep(0.12)
                isPhotosScrollCoverRequestPending = false
                requestPhotoCoversForScrolledList()
            }
            return
        }
        lastPhotosScrollCoverRequestTime = now
        for album in prioritizedPhotosAlbumsForCoverPrefetch() {
            requestPhotoAlbumCoverImageIfNeeded(for: album)
        }
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
        // (Every row in view, however many that is.)
        let limit = max(photosAlbumCoverPrefetchBatchLimit, visibleIndices.count + 1)
        if resolvedAlbums.count > limit {
            return Array(resolvedAlbums.prefix(limit))
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
        // Where a finger or the wheel left the list, when one has moved it: the rows in view then
        // aren't the ones around the selection.
        let scrollOffset = pointer.pinnedScrollOffset(identity: MenuListLayer.identity(of: menuItems)) ?? menuScrollOffset(
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
            photosCarouselLoadTask?.cancel()
            photosCarouselLoadTask = nil
            photosCarouselLoadOverlayOpacity = 0
            return
        }
        let identity = photosCarouselIdentityKey(for: selectedAlbum)
        // Its pictures are up, or on their way.
        if photosCarouselLoadedIdentity == identity { return }
        if photosCarouselIdentity == identity, photosCarouselLoadTask != nil { return }
        requestPhotosCarouselArtworks(for: selectedAlbum)
    }

    /// Tells one album's pictures from another's without going through them all (a year of
    /// photos is thousands).
    func photosCarouselIdentityKey(for album: PhotoLibraryAlbumEntry) -> String {
        "\(album.id)#\(album.count)#\(album.coverAssetLocalIdentifier ?? "")"
    }

    func requestPhotosCarouselArtworks(for album: PhotoLibraryAlbumEntry) {
        let identity = photosCarouselIdentityKey(for: album)
        photosCarouselIdentity = identity
        photosCarouselLoadTask?.cancel()
        photosCarouselLoadTask = nil
        if album.assetLocalIdentifiers.isEmpty {
            photosCarouselLoadedIdentity = identity
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
        let targetSize = Self.normalizedPhotoTargetSize(photosCarouselArtworkTargetSize, deliveryMode: .highQualityFormat)
        // Read off the main thread, and given up as soon as another album is selected: a list
        // scrolled through selects one after another.
        photosCarouselLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let images = Self.loadPhotoImages(localIdentifiers: localIdentifiers, targetSize: targetSize)
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                guard let self, self.photosCarouselRequestID == requestID else { return }
                self.photosCarouselLoadTask = nil
                guard !wasCancelled, self.photosCarouselIdentity == identity, self.shouldUsePhotosCarouselSlot else { return }
                self.photosCarouselLoadedIdentity = identity
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

    /// The carousel's pictures are large, and are let go when Photos is left.
    func releasePhotosCarouselPictures() {
        photosCarouselLoadTask?.cancel()
        photosCarouselLoadTask = nil
        guard !photosCarouselArtworks.isEmpty || !photosCarouselIdentity.isEmpty else { return }
        _ = incrementRequestID(&photosCarouselRequestID)
        photosCarouselIdentity = ""
        photosCarouselLoadedIdentity = ""
        photosCarouselArtworks = []
        photosCarouselLoadOverlayOpacity = 0
    }

    func requestPhotoAlbumCoverImageIfNeeded(for album: PhotoLibraryAlbumEntry) {
        guard let coverAssetLocalIdentifier = album.coverAssetLocalIdentifier else { return }
        guard photosAlbumCoverImageCache[album.id] == nil, pendingPhotosAlbumCovers[album.id] == nil else { return }
        guard !photosAlbumCoverRequestsInFlight.contains(album.id) else { return }
        photosAlbumCoverRequestsInFlight.insert(album.id)
        requestPhotoImage(
            localIdentifier: coverAssetLocalIdentifier,
            targetSize: CGSize(width: 220, height: 220),
            contentMode: .aspectFill,
            deliveryMode: .fastFormat,
        ) { image in
            // (No picture: the row went by before its turn came, and it's asked for again if it comes back.)
            self.photosAlbumCoverRequestsInFlight.remove(album.id)
            guard let image else { return }
            self.pendingPhotosAlbumCovers[album.id] = image
            self.schedulePhotosAlbumCoverFlush()
        }
    }

    /// Covers go into the cache together, a few times a second: every change to it redraws the
    /// menu, and a list scrolled through brings them in by the dozen.
    func schedulePhotosAlbumCoverFlush() {
        guard !isPhotosAlbumCoverFlushScheduled else { return }
        isPhotosAlbumCoverFlushScheduled = true
        Task {
            try? await firstRowSleep(0.08)
            isPhotosAlbumCoverFlushScheduled = false
            guard !pendingPhotosAlbumCovers.isEmpty else { return }
            var covers = photosAlbumCoverImageCache
            covers.merge(pendingPhotosAlbumCovers) { _, new in new }
            pendingPhotosAlbumCovers.removeAll()
            photosAlbumCoverImageCache = trimmedPhotosAlbumCovers(covers)
        }
    }

    /// The covers nearest the days in view, up to the limit. (Folders' covers and Last 12 Months'
    /// aren't days, and stay.)
    func trimmedPhotosAlbumCovers(_ covers: [String: NSImage]) -> [String: NSImage] {
        guard covers.count > photosAlbumCoverCacheLimit else { return covers }
        // (The middle of what's in view: a list moved by a finger is away from its selection.)
        let visibleIndices = visiblePhotosAlbumIndicesForCoverPrefetch()
        let middleIndex = visibleIndices.isEmpty
            ? min(max(0, selectedThirdIndex), max(0, photosDateAlbums.count - 1))
            : visibleIndices[visibleIndices.count / 2]
        var distanceByID: [String: Int] = [:]
        distanceByID.reserveCapacity(photosDateAlbums.count)
        for (index, album) in photosDateAlbums.enumerated() {
            distanceByID[album.id] = abs(index - middleIndex)
        }
        let kept = Set(covers.keys.sorted { (distanceByID[$0] ?? -1) < (distanceByID[$1] ?? -1) }.prefix(photosAlbumCoverCacheLimit))
        return covers.filter { kept.contains($0.key) }
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
            // Every photo in the library is gone through: not on the main thread.
            Task.detached(priority: .userInitiated) {
                let loadedAlbums = Self.loadPhotoLibraryAlbums()
                await MainActor.run {
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
        if FirstRowHarness.isActive {
            completion(false)
            return
        }
        #if canImport(Photos)
            let status: PHAuthorizationStatus = if #available(macOS 11.0, iOS 14.0, tvOS 14.0, *) {
                PHPhotoLibrary.authorizationStatus(for: .readWrite)
            } else {
                PHPhotoLibrary.authorizationStatus()
            }
            switch status {
            case .authorized, .limited:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                #if os(macOS)
                    // The system asks in a dialog of its own: show the pointer so it can be answered.
                    NSCursor.setHiddenUntilMouseMoves(false)
                #endif
                let handler: (PHAuthorizationStatus) -> Void = { newStatus in
                    Task { @MainActor in
                        completion(newStatus == .authorized || newStatus == .limited)
                    }
                }
                if #available(macOS 11.0, iOS 14.0, tvOS 14.0, *) {
                    PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: handler)
                } else {
                    PHPhotoLibrary.requestAuthorization(handler)
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
            revealWhen: { !self.isLoadingPhotoLibrary },
        ) {
            self.thirdMenuMode = .photosDateAlbums
            self.isInThirdMenu = true
            self.selectedThirdIndex = min(self.selectedThirdIndex, max(0, self.photosDateAlbums.count - 1))
            self.headerText = title
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
            self.requestPhotoLibraryLoadIfNeeded()
            self.refreshDetailPreviewForCurrentContext()
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
        Task {
            try? await firstRowSleep(menuHideDelay)
            guard !Task.isCancelled else { return }
            guard photoSlideshowRequestID == requestID else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                fullscreenTransitionOverlayOpacity = 1
                menuSceneOpacity = 0
            }
        }
        loadPhotoSlideshowImages(for: album, requestID: requestID)
        Task {
            // Up once its first picture is in: a second at least, for the menu to have faded away,
            // and after three whatever has come.
            let started = Date()
            while Date().timeIntervalSince(started) < 3.0,
                  Date().timeIntervalSince(started) < 1.0 || photoSlideshowImageCache[0] == nil
            {
                try? await firstRowSleep(0.05)
                guard !Task.isCancelled else { return }
                guard photoSlideshowRequestID == requestID else { return }
            }
            guard !Task.isCancelled else { return }
            guard photoSlideshowRequestID == requestID else { return }
            // The show's clock starts as it goes up, so the first picture has its whole turn.
            photoSlideshowPlaybackStartDate = Date()
            photoSlideshowPlaybackElapsedOffset = 0
            activeFullscreenScene = FullscreenScenePresentation(key: photoSlideshowFullscreenKey, payload: [:])
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                fullscreenSceneOpacity = 1
                fullscreenTransitionOverlayOpacity = 0
            }
            isFullscreenSceneTransitioning = false
            // Back shows for a moment, then leaves the pictures to themselves.
            showSlideshowControls()
            resolvePhotoSlideshowMusicURL(forRequestID: requestID)
        }
    }

    /// The slideshow's Back button (for the pointer and fingers): shown for a few seconds, then
    /// faded away until a tap, a click or the pointer moving brings it back.
    func showSlideshowControls() {
        slideshowControlsHideTask?.cancel()
        if !areSlideshowControlsVisible { areSlideshowControlsVisible = true }
        slideshowControlsHideTask = Task { @MainActor [weak self] in
            try? await firstRowSleep(3)
            guard let self, !Task.isCancelled else { return }
            self.areSlideshowControlsVisible = false
        }
    }

    func hideSlideshowControls() {
        slideshowControlsHideTask?.cancel()
        slideshowControlsHideTask = nil
        if areSlideshowControlsVisible { areSlideshowControlsVisible = false }
    }

    /// A tap or click on a slideshow: brings Back up, or puts it away, as on a movie.
    func toggleSlideshowControls() {
        if areSlideshowControlsVisible {
            hideSlideshowControls()
        } else {
            showSlideshowControls()
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
            Task(priority: .userInitiated) {
                let resolvedSong: MusicLibrarySongEntry?
                let snapshot: (
                    sortedSongs: [MusicLibrarySongEntry],
                    shuffleSongs: [MusicLibrarySongEntry],
                    itemIndices: [String: Int],
                )?
                do {
                    let loadedSnapshot = try await self.loadStartupMusicLibrarySnapshot()
                    snapshot = loadedSnapshot
                    resolvedSong = loadedSnapshot.shuffleSongs.randomElement()
                } catch {
                    snapshot = nil
                    resolvedSong = nil
                }
                await MainActor.run {
                    guard self.photoSlideshowRequestID == requestID else { return }
                    if let snapshot {
                        self.musicAllSongsCache = snapshot.sortedSongs
                        self.musicShuffleSongsCache = snapshot.shuffleSongs
                        #if canImport(iTunesLibrary)
                            self.musicLibraryItemIndexBySongID = snapshot.itemIndices
                        #endif
                    }
                    self.photoSlideshowResolvedMusicEntry = resolvedSong
                    self.photoSlideshowMusicURL = resolvedSong == nil ? self.defaultPhotoSlideshowMusicURL() : nil
                    self.startPhotoSlideshowBackgroundMusicFromResolvedSourceIfNeeded()
                }
            }
        }
    }

    func fetchRandomPhotoSlideshowMusicSong() async throws -> MusicLibrarySongEntry? {
        if let cachedSong = randomCachedMusicLibrarySong() {
            return cachedSong
        }
        let snapshot = try await loadStartupMusicLibrarySnapshot()
        return snapshot.shuffleSongs.randomElement()
    }

    func loadPhotoSlideshowImages(for album: PhotoLibraryAlbumEntry, requestID: Int) {
        let identifiers = album.assetLocalIdentifiers
        guard photoSlideshowRequestID == requestID else { return }
        photoSlideshowAssetLocalIdentifiers = identifiers
        photoSlideshowImageCache = [:]
        photoSlideshowImageRequestsInFlight = []
        photoSlideshowImageFallbackAttempted = []
        photoSlideshowVisiblePrimaryIndex = 0
        photoSlideshowVisibleSecondaryIndex = nil
        if identifiers.isEmpty {
            if activeFullscreenScene?.key == photoSlideshowFullscreenKey {
                handlePhotoSlideshowPlaybackFinished()
            } else {
                stopPhotoSlideshowMusic()
                resetPhotoSlideshowState()
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    menuSceneOpacity = 1
                }
                withAnimation(.easeInOut(duration: photoSlideshowMenuRevealDuration)) {
                    fullscreenTransitionOverlayOpacity = 0
                }
                Task {
                    try? await firstRowSleep(photoSlideshowMenuRevealDuration)
                    guard !Task.isCancelled else { return }
                    guard photoSlideshowRequestID == requestID else { return }
                    resetScreenSaverIdleTimer()
                    isFullscreenSceneTransitioning = false
                }
            }
            return
        }
        prefetchPhotoSlideshowImages(
            aroundPrimaryIndex: 0,
            secondaryIndex: nil,
            requestID: requestID,
        )
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
        player.isMuted = FirstRowHarness.isActive
        observedPhotoSlideshowMusicPlayer = player
        photoSlideshowMusicPlayer = player
        if let currentItem = player.currentItem {
            photoSlideshowMusicDidEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main,
            ) { _ in
                MainActor.assumeIsolatedIfPossible {
                    guard self.observedPhotoSlideshowMusicPlayer === player else { return }
                    player.seek(to: .zero)
                    player.playImmediately(atRate: 1.0)
                }
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
        if let bundled = bundledResourceURL("default", "mp3") {
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
        case .space, .enter:
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
        Task {
            try? await firstRowSleep(sceneDismissDelay)
            guard !Task.isCancelled else { return }
            guard isFullscreenSceneTransitioning else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                fullscreenTransitionOverlayOpacity = 1
            }
            activeFullscreenScene = nil
            stopPhotoSlideshowMusic()
            resetPhotoSlideshowState()
            try? await firstRowSleep(photoSlideshowExitHoldDuration)
            guard !Task.isCancelled else { return }
            var instant2 = Transaction()
            instant2.disablesAnimations = true
            withTransaction(instant2) {
                menuSceneOpacity = 1
            }
            withAnimation(.easeInOut(duration: photoSlideshowMenuRevealDuration)) {
                fullscreenTransitionOverlayOpacity = 0
            }
            try? await firstRowSleep(photoSlideshowMenuRevealDuration)
            guard !Task.isCancelled else { return }
            resetScreenSaverIdleTimer()
            isFullscreenSceneTransitioning = false
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
        let targetSize = photoSlideshowImageTargetSize
        photoSlideshowImageRequestsInFlight.insert(index)
        /// Whether the show still wants this picture in this place.
        func isStillWanted() -> Bool {
            photoSlideshowRequestID == requestID &&
                photoSlideshowAssetLocalIdentifiers.indices.contains(index) &&
                photoSlideshowAssetLocalIdentifiers[index] == localIdentifier
        }
        func keep(_ image: NSImage) {
            photoSlideshowImageCache[index] = image
            trimPhotoSlideshowImageCache(
                keeping: Set(
                    photoSlideshowDesiredIndices(
                        aroundPrimaryIndex: photoSlideshowVisiblePrimaryIndex,
                        secondaryIndex: photoSlideshowVisibleSecondaryIndex,
                    ),
                ),
            )
        }
        // The picture as the device has it, which is quick.
        requestPhotoImage(
            localIdentifier: localIdentifier,
            targetSize: targetSize,
            contentMode: .aspectFit,
            deliveryMode: photoSlideshowImageDeliveryMode,
        ) { image in
            guard isStillWanted() else {
                self.photoSlideshowImageRequestsInFlight.remove(index)
                return
            }
            if let image {
                self.photoSlideshowImageRequestsInFlight.remove(index)
                keep(image)
                return
            }
            // The device hasn't all of it (iCloud has the rest): a smaller one goes up meanwhile,
            // and the whole picture takes its place when it has come.
            self.requestPhotoImage(
                localIdentifier: localIdentifier,
                targetSize: self.photoSlideshowFallbackTargetSize,
                contentMode: .aspectFit,
                deliveryMode: .fastFormat,
            ) { standIn in
                guard isStillWanted() else {
                    self.photoSlideshowImageRequestsInFlight.remove(index)
                    return
                }
                if let standIn, self.photoSlideshowImageCache[index] == nil {
                    keep(standIn)
                }
                self.requestPhotoImage(
                    localIdentifier: localIdentifier,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    deliveryMode: self.photoSlideshowImageDeliveryMode,
                    allowsNetwork: true,
                ) { whole in
                    self.photoSlideshowImageRequestsInFlight.remove(index)
                    guard isStillWanted(), let whole else { return }
                    keep(whole)
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
    nonisolated static func loadPhotoLibraryAlbums() -> (dateAlbums: [PhotoLibraryAlbumEntry], lastTwelveMonths: PhotoLibraryAlbumEntry?) {
        #if FIRSTROW_PORTABLE
            // No system photo library on Linux or Windows.
            return ([], nil)
        #else
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
        #endif
    }

    /// One picture, read off the main thread and handed back on it. Without `allowsNetwork` it's
    /// what the device has, and comes back nil when that isn't enough for the size asked.
    func requestPhotoImage(
        localIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        allowsNetwork: Bool = false,
        completion: @escaping (NSImage?) -> Void,
    ) {
        if let fileURL = filePhotoURL(fromIdentifier: localIdentifier) {
            Task.detached(priority: .userInitiated) {
                let image = Self.filePhotoImage(at: fileURL, targetSize: targetSize)
                await MainActor.run { completion(image) }
            }
            return
        }
        let loader: PhotoImageLoader = allowsNetwork ? .downloads : (deliveryMode == .fastFormat ? .thumbnails : .pictures)
        loader.load(PhotoImageLoader.Request(
            localIdentifier: localIdentifier,
            targetSize: Self.normalizedPhotoTargetSize(targetSize, deliveryMode: deliveryMode),
            contentMode: contentMode,
            deliveryMode: deliveryMode,
            allowsNetwork: allowsNetwork,
            completion: completion,
        ))
    }

    /// An album's first pictures, for the carousel, read where this is called (off the main
    /// thread) and given up when the task is cancelled. Only what the device has: nothing here
    /// waits on iCloud.
    nonisolated static func loadPhotoImages(localIdentifiers: [String], targetSize: CGSize) -> [NSImage?] {
        var images: [NSImage?] = []
        images.reserveCapacity(localIdentifiers.count)
        for localIdentifier in localIdentifiers {
            if Task.isCancelled { break }
            if localIdentifier.hasPrefix(filePhotoIdentifierPrefix) {
                images.append(URL(string: localIdentifier).flatMap { filePhotoImage(at: $0, targetSize: targetSize) })
                continue
            }
            // (As good as the device has it; failing that, the small one the library keeps ready.)
            let image = PhotoImageLoader.image(
                localIdentifier: localIdentifier, targetSize: targetSize, contentMode: .aspectFit,
                deliveryMode: .highQualityFormat, allowsNetwork: false,
            ) ?? PhotoImageLoader.image(
                localIdentifier: localIdentifier, targetSize: targetSize, contentMode: .aspectFit,
                deliveryMode: .fastFormat, allowsNetwork: false,
            )
            images.append(image)
        }
        return images
    }

    nonisolated static func normalizedPhotoTargetSize(
        _ targetSize: CGSize,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
    ) -> CGSize {
        let safeWidth = max(1, targetSize.width)
        let safeHeight = max(1, targetSize.height)
        let maxRequestedDimension: CGFloat
        #if os(iOS) || os(tvOS)
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

/// Reads pictures from the photo library off the main thread, a couple at a time. The request
/// made last is served first: a list scrolled through leaves a trail of rows that have gone by,
/// and it's the ones in view now that want their pictures. Past a limit the oldest are let go
/// (and told so with no picture), to be asked for again if their rows come back.
final class PhotoImageLoader: @unchecked Sendable {
    struct Request {
        let localIdentifier: String
        let targetSize: CGSize
        let contentMode: PHImageContentMode
        let deliveryMode: PHImageRequestOptionsDeliveryMode
        let allowsNetwork: Bool
        /// Called on the main thread, once, with the picture or nil.
        let completion: (NSImage?) -> Void
    }

    /// Row covers: small, and many.
    static let thumbnails = PhotoImageLoader(label: "thumbnails", workerLimit: 2, pendingLimit: 40)
    /// A slideshow's pictures, as the device has them.
    static let pictures = PhotoImageLoader(label: "pictures", workerLimit: 2, pendingLimit: 16)
    /// Pictures iCloud may have to send, which can take seconds each: on their own, so that they
    /// hold nothing else up.
    static let downloads = PhotoImageLoader(label: "downloads", workerLimit: 1, pendingLimit: 6)

    private let queue: DispatchQueue
    private let workerLimit: Int
    private let pendingLimit: Int
    private let lock = NSLock()
    private var pending: [Request] = []
    private var workerCount = 0

    private init(label: String, workerLimit: Int, pendingLimit: Int) {
        queue = DispatchQueue(label: "firstrow.photos.\(label)", qos: .userInitiated, attributes: .concurrent)
        self.workerLimit = workerLimit
        self.pendingLimit = pendingLimit
    }

    func load(_ request: Request) {
        var letGo: [Request] = []
        var startsWorker = false
        lock.lock()
        pending.append(request)
        if pending.count > pendingLimit {
            let excess = pending.count - pendingLimit
            letGo = Array(pending.prefix(excess))
            pending.removeFirst(excess)
        }
        if workerCount < workerLimit {
            workerCount += 1
            startsWorker = true
        }
        lock.unlock()
        if !letGo.isEmpty {
            DispatchQueue.main.async {
                for request in letGo { request.completion(nil) }
            }
        }
        if startsWorker {
            queue.async { self.work() }
        }
    }

    private func work() {
        while true {
            lock.lock()
            guard let request = pending.popLast() else {
                workerCount -= 1
                lock.unlock()
                return
            }
            lock.unlock()
            let image = autoreleasepool {
                Self.image(
                    localIdentifier: request.localIdentifier, targetSize: request.targetSize, contentMode: request.contentMode,
                    deliveryMode: request.deliveryMode, allowsNetwork: request.allowsNetwork,
                )
            }
            DispatchQueue.main.async { request.completion(image) }
        }
    }

    /// One picture, read here and now: for anywhere but the main thread. (Asked for this way the
    /// library answers once, with the picture or without, so nothing is left waiting.)
    static func image(
        localIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        allowsNetwork: Bool,
    ) -> NSImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        func read(_ mode: PHImageRequestOptionsDeliveryMode) -> NSImage? {
            let options = PHImageRequestOptions()
            options.deliveryMode = mode
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowsNetwork
            options.isSynchronous = true
            var result: NSImage?
            PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                guard (info?[PHImageCancelledKey] as? Bool) != true else { return }
                result = image
            }
            return result
        }
        if let image = read(deliveryMode) { return image }
        // The quick way gives the small picture the library keeps ready, and a photo that's only
        // just arrived hasn't one yet: it's made from the photo itself then.
        return deliveryMode == .fastFormat ? read(.highQualityFormat) : nil
    }
}

extension MenuView {
    struct PhotoLibraryAlbumEntry: Identifiable {
        enum Scope {
            case last12Months
            case dateGroup
            case lastImport
            /// A folder chosen in Settings, or an iPhoto album or event.
            case source
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
