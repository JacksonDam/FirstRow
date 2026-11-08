import AVFoundation
import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif

/// The menu system's navigation, library and playback state. Its logic is in the `MenuView+*` files.
@MainActor
final class MenuView: ObservableObject {
    let menuItems = MenuConfiguration.rootItems

    // MARK: - Layout constants

    let iconSize: CGFloat = 400
    let iconSpacing: CGFloat = 80
    let menuWidth: CGFloat = 900
    let selectionBoxHeight: CGFloat = 75
    let menuRowSpacing: CGFloat = 5
    let defaultVisibleMenuRowCount: Int = 9
    let thirdLevelVisibleMenuRowCount: Int = 10
    let baselineVisibleMenuRowCount: Int = 7
    let stickySelectionRowIndex: Int = 3
    let dividerSectionGapAfterLine: CGFloat = 14
    let dividerLineInsetHorizontal: CGFloat = 33
    let dividerLineYOffsetInGap: CGFloat = 2
    let menuListBottomInset: CGFloat = 200
    let submenuTopFadeHeight: CGFloat = 30
    let arcRadius: CGFloat = 550
    let scaleReduction: CGFloat = 0.3
    let selectedCarouselAdjustedSizeMultiplier: CGFloat = 1.65
    let landedIconScale: CGFloat = 0.2
    let landedIconVerticalMultiplier: CGFloat = 2.5
    let landedFinalYOffsetAdjustment: CGFloat = 32
    let menuHeaderVerticalOffset: CGFloat = -10
    let selectedCarouselEntryOffset: CGFloat = 200 * 1.5

    // MARK: - Duration constants

    /// The modern look has no icon flight, so its menus come and go sooner.
    var iconFlightAnimationDuration: Double { ModernTheme.isActive ? 0.3 : 0.5 }
    let submenuBackgroundIconTransitionDuration: Double = 0.5
    var submenuBackgroundIconReturnDuration: Double { ModernTheme.isActive ? 0.3 : 0.5 }
    let movieEntryFadeDuration: Double = 0.48
    let movieEntryBlackHoldDuration: Double = 1.0
    let movieExitFreezeHoldDuration: Double = 0.5
    let movieExitFadeDuration: Double = 0.48
    let movieResumePromptRevealDelay: Double = 1.0
    let movieResumePromptFadeDuration: Double = 0.24
    let movieResumePromptSelectionSlideDuration: Double = 0.2
    let movieResumePromptLaunchFadeDuration: Double = 0.4
    let menuFolderSwapFadeDuration: Double = 0.22
    let menuOverlayBlackoutSafetyDuration: Double = 0.1
    let menuFolderSwapHoldDuration: Double = 0.5
    let fullscreenOverlayBlackoutSafetyDuration: Double = 0.1
    let screenSaverNowPlayingToastFadeDuration: Double = 0.5
    let screenSaverNowPlayingToastVisibleDuration: Double = 10.0
    let screenSaverNowPlayingToastSize = CGSize(width: 500, height: 170)
    let screenSaverMusicTrackSwitchCoalesceDelay: TimeInterval = 0.07
    let photoSlideshowPhotoDisplayDuration: Double = 3.0
    let photoSlideshowCrossfadeDuration: Double = 1.0
    let photoSlideshowMenuFadeDuration: Double = 0.28
    let photoSlideshowMenuRevealDuration: Double = 0.24
    let photoSlideshowExitHoldDuration: Double = 1.0
    let musicSongSwitchTransitionDuration: Double = 1.0
    let musicSongOutgoingFadeDuration: Double = 0.6
    let musicSongIncomingTransitionDelay: Double = 0.2
    let musicNowPlayingFlipInterval: TimeInterval = 18.0
    let musicNowPlayingFlipDuration: TimeInterval = 1.2
    /// How long the menus sit idle before the screen saver starts (0 = never), from Settings.
    var screenSaverIdleActivationDelay: TimeInterval {
        AppSettings.screenSaverDelay
    }

    let screenSaverIdleCheckInterval: TimeInterval = 1.0

    // MARK: - Input constants

    let arrowInputDebounceInterval: TimeInterval = 0.05
    let directionalHoldInitialDelay: TimeInterval = 0.5
    let directionalHoldBaseRepeatInterval: TimeInterval = 0.16
    let directionalHoldFastRepeatInterval: TimeInterval = 0.08
    /// Lists longer than `longListItemCount` reach twice the top speed.
    let directionalHoldLongListFastRepeatInterval: TimeInterval = 0.04
    let longListItemCount = 12
    /// How many rows the list the arrows last moved through has (sets the top hold speed).
    var navigatedListItemCount = 0
    let directionalHoldAccelerationDelay: TimeInterval = 0.5
    let directionalHoldAccelerationRampDuration: TimeInterval = 0.3
    let directionalHoldSweepOverlapFactor: Double = 1.18
    let movieControlsAutoHideDelay: TimeInterval = 3.0
    let movieControlsFadeDuration: TimeInterval = 1.0
    let movieScrubReleaseGracePeriod: TimeInterval = 0.18

    // MARK: - Appearance constants

    let menuArrowAppearance = MenuConfiguration.defaultArrowAppearance
    let photosSelectionBoxWidthScale: CGFloat = 1.1
    let photosSelectionBoxHeightScale: CGFloat = 1.2
    let selectionTextureVisualWidthDelta: CGFloat = 93
    let selectionTextureVisualHeightDelta: CGFloat = 58
    let photosSelectionTextureLeadingAdjustment: CGFloat = 6
    let photosSelectionTextureTrailingAdjustment: CGFloat = 3
    let photosSelectionTextureHeightAdjustment: CGFloat = -2
    let photosCompactSelectionVisualWidthReduction: CGFloat = 18
    let movieResumeSelectionTextureLeadingAdjustment: CGFloat = -14
    let movieResumeSelectionTextureTrailingAdjustment: CGFloat = 0

    // MARK: - Fullscreen scene keys

    let musicNowPlayingFullscreenKey = "music_now_playing"
    let screenSaverFullscreenKey = "settings_screen_saver"
    let featureErrorFullscreenKey = "feature_error"
    let theatricalTrailersLoadingFullscreenKey = "movies_theatrical_trailers_loading"
    let photoSlideshowFullscreenKey = "photo_slideshow"

    private var mediaSourcesObserver: NSObjectProtocol?
    /// Mouse and trackpad state (Settings > Mouse).
    let pointer = PointerInputState()
    /// A finger is choosing a row in touch mode, so the selection shows.
    @Published var isTouchSelecting = false
    #if os(iOS)
        let touch = TouchInputState()
    #endif

    init() {
        mediaSourcesObserver = NotificationCenter.default.addObserver(
            forName: MediaSources.didChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mediaSourcesRevision &+= 1
                self?.reloadMediaAfterSourcesChange()
            }
        }
        #if os(macOS)
            unavailableTracksObserver = NotificationCenter.default.addObserver(
                forName: UnavailableAppleMusicTrackCache.didUpdateNotification,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                Task { @MainActor in self?.removeUnavailableAppleMusicTracksFromCaches() }
            }
        #endif
    }

    private var unavailableTracksObserver: NSObjectProtocol?
    var photoSourceAlbumsRequestID = 0

    // MARK: - Media folders state

    @Published var mediaFoldersPages: [MediaFoldersPageState] = []
    /// Bumped whenever the chosen folders or libraries change, to redraw lists that show them.
    @Published var mediaSourcesRevision = 0
    var isChoosingMediaSource = false

    // MARK: - Navigation state

    @Published var selectedIndex = 0
    @Published var selectedSubIndex = 0
    @Published var activeRootItemID: String?
    @Published var isIconAnimated = false
    @Published var isEnteringSubmenu = false
    @Published var isInSubmenu = false
    @Published var isInThirdMenu = false
    @Published var headerText = "First Row"
    @Published var headerOpacity: Double = 1
    @Published var submenuTitleOpacity: Double = 0
    @Published var rootMenuOpacity: Double = 1
    @Published var submenuOpacity: Double = 0
    @Published var thirdMenuOpacity: Double = 0
    @Published var detailContentOpacity: Double = 0
    @Published var isReturningToRoot = false
    @Published var isMenuOverflowScrollingUp = false
    @Published var isMenuOverflowScrollingDown = false
    @Published var submenuEntryWorkItem: Task<Void, Never>?
    @Published var overflowFadeWorkItem: Task<Void, Never>?

    // MARK: - Input handling state

    @Published var lastNavigationKey: KeyCode = .none
    @Published var navigationHoldStartTime: Date?
    @Published var lastNavigationEventTime: Date?
    @Published var selectionAnimationDuration: Double = 0.30
    @Published var useLinearSelectionSweepAnimation = false
    @Published var isSelectionSettled = true
    @Published var settleWorkItem: Task<Void, Never>?
    @Published var didPlayLimitForCurrentHold = false
    @Published var activeDirectionalHoldKey: KeyCode = .none
    @Published var directionalHoldPressStartTime: Date?
    @Published var directionalHoldStartWorkItem: Task<Void, Never>?
    @Published var directionalHoldTickWorkItem: Task<Void, Never>?
    @Published var directionalHoldRepeatPhaseStartTime: Date?
    @Published var lastHoldNavigationTime: Date?
    @Published var lastArrowNavigationInputTime: Date?

    // MARK: - Third menu state

    @Published var selectedThirdIndex = 0
    @Published var thirdMenuMode: ThirdMenuMode = .none
    @Published var thirdMenuItems: [MoviesFolderEntry] = []
    @Published var thirdMenuRootURL: URL?
    @Published var thirdMenuCurrentURL: URL?
    @Published var movieLibraryRootURLs: [URL] = []
    /// The movies list is Continue Watching rather than a folder.
    @Published var isShowingContinueWatching = false
    var continueWatchingRemainingText: [String: String] = [:]

    // MARK: - iTunes Top state

    @Published var iTunesTopMovies: [ITunesTopMovieEntry] = []
    @Published var iTunesTopTVEpisodes: [ITunesTopTVEpisodeEntry] = []
    @Published var iTunesTopSongs: [ITunesTopSongEntry] = []
    @Published var iTunesTopMusicVideos: [ITunesTopMusicVideoEntry] = []
    @Published var iTunesTopStateByKind: [ITunesTopCarouselKind: ITunesTopKindState] = ITunesTopCarouselKind.defaultStateMap
    @Published var tvShowsSortMode: TVShowsSortMode = .show

    // MARK: - Music library state

    @Published var musicCategoryThirdMenuItems: [MusicCategoryEntry] = []
    @Published var musicSongsThirdMenuItems: [MusicLibrarySongEntry] = []
    @Published var activeMusicCategoryKind: MusicCategoryKind?
    @Published var activeMusicCategoryMenuTitle: String = ""
    @Published var lastSelectedMusicCategoryIndex: Int = 0
    @Published var isMusicSongsCategoryScoped = false
    @Published var activeMusicLibraryMediaType: MusicLibraryMediaType = .songs
    @Published var musicSongsShowsShuffleAction = false
    @Published var isLoadingMusicSongs = false
    @Published var musicSongsLoadError: String?
    @Published var musicSongsRequestID = 0
    @Published var musicShuffleRequestID = 0
    @Published var musicStartupPreloadRequestID = 0
    @Published var musicAllSongsCache: [MusicLibrarySongEntry]?
    @Published var musicShuffleSongsCache: [MusicLibrarySongEntry]?
    @Published var musicLibraryItemIndexBySongID: [String: Int] = [:]
    @Published var hasStartedStartupMusicLibraryPreload = false
    @Published var isStartupMusicLibraryPreloadComplete = false
    var isMusicEntryWaitingForStartupPreload = false
    @Published var startupMusicLibraryPreloadOverlayOpacity: Double = 0
    @Published var startupSoundWarmUpWorkItem: Task<Void, Never>?

    // MARK: - Movie playback state

    @Published var moviePlayer: AVPlayer?
    @Published var currentMoviePlaybackURL: URL?
    @Published var currentMoviePlaybackTemporaryFileURL: URL?
    @Published var isCurrentMoviePlaybackEphemeralPreview = false
    @Published var lastClosedMovieURL: URL?
    @Published var lastClosedMovieTimestamp: Double = 0
    @Published var isMoviePlaybackVisible = false
    @Published var isMovieTransitioning = false
    @Published var movieTransitionOverlayOpacity: Double = 0
    @Published var isMovieResumePromptVisible = false
    @Published var isMovieResumePromptConfirming = false
    @Published var movieResumePromptSelectedIndex = 0
    @Published var movieResumePromptHideUnselected = false
    @Published var movieResumePromptSolidBlackSelected = false
    @Published var movieResumePromptTargetURL: URL?
    @Published var movieResumePromptResumeSeconds: Double = 0
    @Published var movieResumePromptBackdropImage: NSImage?
    @Published var movieResumePromptBackdropRequestID = 0
    @Published var movieResumePromptBackdropCache: [String: NSImage] = [:]
    @Published var movieResumePromptOpacity: Double = 0
    @Published var areMovieControlsVisible = false
    @Published var movieControlsOpacity: Double = 0
    @Published var movieControlsHideWorkItem: Task<Void, Never>?
    @Published var movieControlsGlyphState: MoviePlaybackGlyphState = .pause
    @Published var isMoviePreviewDownloadLoading = false
    @Published var moviePreviewDownloadProgress: Double = 0
    @Published var moviePlaybackCurrentSeconds: Double = 0
    @Published var moviePlaybackDurationSeconds: Double = 0
    @Published var pendingMovieControlsRevealOnDurationReady = false
    @Published var movieTimeObserverToken: Any?
    @Published var moviePlaybackDidEndObserver: NSObjectProtocol?
    @Published var observedMoviePlayer: AVPlayer?
    @Published var movieScrubDirection: Int = 0
    @Published var movieScrubStartDate: Date?
    @Published var movieLastScrubInputDate: Date?
    @Published var movieLastScrubTickDate: Date?
    @Published var movieScrubTimer: Timer?
    /// The subtitles, audio and speed panel, while it's open.
    @Published var movieOptions: MovieOptionsState?
    /// The current movie's playback speed (1 is normal).
    var movieSpeed: Double = 1
    /// A left or right press in a movie that isn't yet known to be a tap or a hold.
    var movieArrowPending: (direction: Int, task: Task<Void, Never>)?
    @Published var moviePlaybackValidationRequestID = 0

    // MARK: - Movies library state

    @Published var menuSceneOpacity: Double = 1
    @Published var menuFolderSwapOverlayOpacity: Double = 0
    @Published var moviePreviewTargetURL: URL?
    @Published var moviePreviewImage: NSImage?
    @Published var moviePreviewRequestID = 0
    @Published var moviePreviewCache: [String: NSImage] = [:]
    @Published var moviesFolderSelectionIndexByDirectoryPath: [String: Int] = [:]
    @Published var moviesFolderSubmenuPreviewDescriptors: [MovieGapPreviewDescriptor] = []
    @Published var moviesFolderSubmenuPreviewIdentity: String = ""
    @Published var moviesFolderSubmenuPreviewRequestID = 0
    @Published var isLoadingMoviesFolderEntries = false
    @Published var moviesFolderEntriesRequestID = 0

    // MARK: - Music preview/carousel state

    @Published var musicPreviewTargetSongID: String?
    @Published var musicPreviewImage: NSImage?
    @Published var musicPreviewDisplayedSong: MusicLibrarySongEntry?
    @Published var musicPreviewRequestID = 0
    @Published var musicPreviewRefreshWorkItem: Task<Void, Never>?
    /// Song covers near the selection. Not published, since filling it doesn't change the screen.
    let musicPreviewCache = LRUCache<String, NSImage>(maxEntryCount: 32)
    /// Library covers by album, filled after launch. Not published either.
    var musicLibraryArtworkDataByAlbumKey: [String: Data] = [:]
    #if canImport(iTunesLibrary)
        /// The library the cover pass reads from, held only while it runs.
        var musicLibraryArtworkLibrary: ITLibrary?
        var musicLibraryArtworkAttemptsByAlbumKey: [String: Int] = [:]
        var musicLibraryArtworkPassRequestID = 0
        var isLoadingMusicLibraryArtwork = false
        var musicTopLevelCarouselNeedsReloadAfterArtwork = false
    #endif
    @Published var musicTopLevelCarouselActiveSubmenuID: String?
    @Published var musicTopLevelCarouselArtworksByIndex: [Int: NSImage?] = [:]
    @Published var musicTopLevelCarouselLoadedArtworkCount = 0
    @Published var musicTopLevelCarouselResolvedArtworkCount: Int?
    @Published var musicTopLevelCarouselPageStartsInFlight: Set<Int> = []
    @Published var musicTopLevelCarouselRequestID = 0
    @Published var isLoadingMusicTopLevelCarousel = false
    @Published var musicTopLevelCarouselLoadOverlayOpacity: Double = 0

    // MARK: - Podcasts state

    @Published var podcastSeriesItems: [PodcastSeriesEntry] = []
    @Published var podcastEpisodesThirdMenuItems: [PodcastEpisodeEntry] = []
    @Published var activePodcastSeriesID: String?
    @Published var activePodcastPlaybackSeriesID: String?
    @Published var activePodcastPlaybackEpisodeID: String?
    @Published var isLoadingPodcasts = false
    @Published var podcastsLoadError: String?
    @Published var podcastsRequestID = 0
    @Published var podcastsHasLoadedAtLeastOnce = false
    @Published var hasPresentedNoPodcastsErrorInCurrentSession = false
    @Published var isResolvingPodcastsRootSelection = false

    // MARK: - Photos state

    @Published var photosDateAlbums: [PhotoLibraryAlbumEntry] = []
    @Published var photosSourceAlbums: [PhotoLibraryAlbumEntry] = []
    @Published var photosDateAlbumMenuItems: [MenuListItemConfig] = []
    @Published var photosLastTwelveMonthsAlbum: PhotoLibraryAlbumEntry?
    @Published var isLoadingPhotoLibrary = false
    @Published var photoLibraryLoadError: String?
    @Published var photoLibraryHasLoadedAtLeastOnce = false
    @Published var photoLibraryRequestID = 0
    @Published var photosAlbumCoverImageCache: [String: NSImage] = [:]
    @Published var photosAlbumCoverRequestsInFlight: Set<String> = []
    @Published var photosCarouselArtworks: [NSImage?] = []
    @Published var photosCarouselIdentity: String = ""
    @Published var photosCarouselRequestID = 0
    @Published var photosCarouselLoadOverlayOpacity: Double = 0
    @Published var photoSlideshowRequestID = 0
    @Published var photoSlideshowAssetLocalIdentifiers: [String] = []
    @Published var photoSlideshowImageCache: [Int: NSImage] = [:]
    @Published var photoSlideshowImageRequestsInFlight: Set<Int> = []
    @Published var photoSlideshowImageFallbackAttempted: Set<Int> = []
    @Published var photoSlideshowVisiblePrimaryIndex = 0
    @Published var photoSlideshowVisibleSecondaryIndex: Int?
    @Published var photoSlideshowAlbumTitle: String = ""
    @Published var photoSlideshowPlaybackStartDate = Date()
    @Published var photoSlideshowPlaybackElapsedOffset: TimeInterval = 0
    @Published var photoSlideshowIsPaused = false
    @Published var photoSlideshowPausedIndex = 0
    @Published var photoSlideshowDidSeekWhilePaused = false
    @Published var photoSlideshowHasFinished = false
    @Published var photoSlideshowResolvedMusicEntry: MusicLibrarySongEntry?
    @Published var photoSlideshowMusicURL: URL?
    @Published var photoSlideshowMusicPlayer: AVPlayer?
    @Published var observedPhotoSlideshowMusicPlayer: AVPlayer?
    @Published var photoSlideshowMusicDidEndObserver: NSObjectProtocol?
    @Published var photoSlideshowMusicFallbackWorkItem: Task<Void, Never>?
    @Published var photoSlideshowMusicHasStarted = false
    @Published var photoSlideshowUsesAppleScriptMusic = false

    // MARK: - Music playback state

    @Published var deferNowPlayingMenuItemUntilAfterFadeOut = false
    /// The Music menu as last drawn: whether it had a Now Playing row and which row was selected.
    var musicSubmenuSelectionMemo: (hasNowPlayingRow: Bool, selectedID: String?)?
    @Published var holdNowPlayingMenuItemDuringExitFade = false
    @Published var hasPendingExternalMusicRestore = false
    @Published var isMusicSongsShuffleMode = false
    @Published var activeMusicPlaybackQueue: [MusicLibrarySongEntry] = []
    @Published var activeMusicPlaybackSongID: String?
    @Published var musicNowPlayingTitle = "Unknown Song"
    @Published var musicNowPlayingArtist = "Unknown Artist"
    @Published var musicNowPlayingAlbum = ""
    @Published var musicNowPlayingTrackPositionText = ""
    @Published var musicNowPlayingArtwork: NSImage?
    @Published var musicNowPlayingArtworkRequestID: Int = 0
    @Published var musicNowPlayingElapsedSeconds: Double = 0
    @Published var musicNowPlayingDurationSeconds: Double = 0
    @Published var musicNowPlayingShowsShuffleGlyph = false
    @Published var musicNowPlayingLeadingGlyphState: MoviePlaybackGlyphState?
    @Published var musicSongTransitionSnapshot: MusicNowPlayingSnapshot?
    @Published var musicSongTransitionOutgoingProgress: CGFloat = 0
    @Published var musicSongTransitionOutgoingOpacityProgress: CGFloat = 0
    @Published var musicSongTransitionIncomingProgress: CGFloat = 0
    @Published var musicSongTransitionDirection: Int = 1
    @Published var musicSongTransitionRequestID: Int = 0
    @Published var musicSongTransitionDeadline: Date?
    @Published var isMusicSongTransitioning = false
    @Published var musicNowPlayingFlipRotationDegrees: Double = 0
    @Published var musicNowPlayingUsesAlternateLayout = false
    @Published var musicNowPlayingFlipTimer: Timer?
    @Published var musicNowPlayingFlipMidpointWorkItem: Task<Void, Never>?
    @Published var musicNowPlayingFlipGeneration: Int = 0
    @Published var isMusicNowPlayingFlipAnimating = false
    @Published var musicAudioPlayer: AVPlayer?
    @Published var isCurrentMusicPlaybackUsingAppleScript = false
    @Published var currentMusicPlaybackTemporaryFileURL: URL?
    @Published var musicTimeObserverToken: Any?
    @Published var musicPlaybackDidEndObserver: NSObjectProtocol?
    @Published var observedMusicAudioPlayer: AVPlayer?
    @Published var musicScrubDirection: Int = 0
    @Published var musicScrubStartDate: Date?
    @Published var musicLastScrubInputDate: Date?
    @Published var musicLastScrubTickDate: Date?
    @Published var musicScrubTimer: Timer?
    var musicArtworkPrefetchInFlightKeys: Set<String> = []
    @Published var musicPlaybackRequestID = 0
    #if os(tvOS) || os(macOS)
        @Published var musicKitScrubGlyphResetWorkItem: Task<Void, Never>?
    #endif
    #if os(tvOS) || os(iOS)
        @Published var musicKitProgressTimer: Timer?
        @Published var musicKitDidHandleTrackEnd = false
    #endif
    #if os(iOS)
        @Published var isCurrentMusicPlaybackUsingMediaPlayer = false
        var musicMediaPlayerWasPlaying = false
    #endif
    @Published var isCurrentMusicPlaybackManagedByFirstRow = false
    @Published var musicAppleScriptCurrentTrackPersistentIDHex: String?
    @Published var musicAppleScriptIsPlaying = false
    @Published var musicAppleScriptStartupDeadline: Date?
    @Published var musicAppleScriptDidHandleTrackBoundary = false
    @Published var musicAppleScriptProgressAnchorElapsedSeconds: Double = 0
    @Published var musicAppleScriptProgressAnchorDate: Date?
    @Published var musicAppleScriptProgressTimer: Timer?
    @Published var musicAppleScriptProgressRequestInFlight = false
    @Published var musicAppleScriptLastSyncDate: Date?
    @Published var musicSystemPlayerObserverTokens: [NSObjectProtocol] = []

    // MARK: - Spotify state

    @Published var spotifyMenuPages: [SpotifyMenuPageState] = []
    @Published var spotifyCollections: [SpotifyCollection] = []
    @Published var isLoadingSpotifyMenu = false
    @Published var spotifyMenuError: String?
    @Published var spotifyRevision = 0
    var spotifyMenuRequestID = 0
    /// The Spotify pages to go back to from the songs list they opened.
    var spotifySongsReturnPages: [SpotifyMenuPageState]?
    var spotifySessionObserver: NSObjectProtocol?
    @Published var isCurrentMusicPlaybackUsingSpotify = false
    var spotifyIsPlaying = false
    var spotifyShowsAdvert = false
    /// The song Spotify was asked to play and hasn't reported yet.
    var spotifyPendingTrackURI: String?
    var spotifyPendingSince: Date?
    var spotifyLastTrackPositionSeconds: Double = 0
    /// Where a seek was sent, until Spotify reports being there.
    var spotifySeekTarget: (seconds: Double, date: Date)?
    var spotifyProgressTimer: Timer?

    // MARK: - Jellyfin and text entry state

    @Published var jellyfin = JellyfinMenuState()
    var jellyfinVideoSession: JellyfinPlaybackSession?
    var jellyfinMusicSession: JellyfinPlaybackSession?
    var jellyfinProgressTimer: Timer?
    var isStartingJellyfinPlayback = false
    @Published var textEntry: TextEntryState?
    @Published var codeDisplay: CodeDisplayState?
    @Published var textEntryOpacity: Double = 0
    var textEntryCompletion: ((String?) -> Void)?
    var codeDisplayCancel: (() -> Void)?

    // MARK: - Fullscreen / transitions state

    @Published var activeFullscreenScene: FullscreenScenePresentation?
    @Published var fullscreenSceneOpacity: Double = 0
    @Published var fullscreenTransitionOverlayOpacity: Double = 0
    @Published var isFullscreenSceneTransitioning = false
    @Published var isMenuFolderSwapTransitioning = false
    @Published var theatricalTrailersLoadingShowsSpinner = false
    @Published var theatricalTrailersLoadingRequestID = 0

    // MARK: - Screen saver state

    @Published var screenSaverNowPlayingToastOpacity: Double = 0
    @Published var screenSaverNowPlayingToastHideWorkItem: Task<Void, Never>?
    @Published var screenSaverPendingMusicTrackSwitchDelta = 0
    @Published var screenSaverPendingMusicTrackSwitchWorkItem: Task<Void, Never>?
    @Published var lastUserInteractionAt = Date()
    @Published var screenSaverIdleMonitorTimer: Timer?

    // MARK: - Settings

    var isUISoundEffectsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "isUISoundEffectsEnabled") as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "isUISoundEffectsEnabled")
        }
    }

    var isScreenSaverEnabled: Bool {
        AppSettings.screenSaverDelay > 0
    }

    #if os(iOS)
        @Published var isMoviesFolderPickerPresented = false
        @Published var hasPromptedMoviesFolderPickerThisSession = false
    #endif
}

extension MenuView {
    @discardableResult
    func incrementRequestID(_ requestID: inout Int) -> Int {
        requestID = requestID &+ 1
        return requestID
    }
}
