import AVFoundation
import SwiftUI

struct MenuView: View {
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

    let iconFlightAnimationDuration: Double = 0.75
    let submenuBackgroundIconTransitionDuration: Double = 0.75
    let submenuBackgroundIconReturnDuration: Double = 0.75
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
    let screenSaverIdleActivationDelay: TimeInterval = 60.0
    let screenSaverIdleCheckInterval: TimeInterval = 1.0

    // MARK: - Input constants

    let arrowInputDebounceInterval: TimeInterval = 0.05
    let directionalHoldInitialDelay: TimeInterval = 0.5
    let directionalHoldBaseRepeatInterval: TimeInterval = 0.16
    let directionalHoldFastRepeatInterval: TimeInterval = 0.08
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

    // MARK: - Navigation state

    @State var selectedIndex = 0
    @State var selectedSubIndex = 0
    @State var activeRootItemID: String?
    @State var isIconAnimated = false
    @State var isEnteringSubmenu = false
    @State var isInSubmenu = false
    @State var isInThirdMenu = false
    @State var headerText = "First Row"
    @State var headerOpacity: Double = 1
    @State var submenuTitleOpacity: Double = 0
    @State var rootMenuSelectionCenterSceneX: CGFloat?
    @State var rootMenuOpacity: Double = 1
    @State var submenuOpacity: Double = 0
    @State var thirdMenuOpacity: Double = 0
    @State var detailContentOpacity: Double = 0
    @State var isReturningToRoot = false
    @State var isMenuOverflowScrollingUp = false
    @State var isMenuOverflowScrollingDown = false
    @State var submenuEntryWorkItem: Task<Void, Never>?
    @State var overflowFadeWorkItem: Task<Void, Never>?

    // MARK: - Input handling state

    @State var lastNavigationKey: KeyCode = .none
    @State var navigationHoldStartTime: Date?
    @State var lastNavigationEventTime: Date?
    @State var selectionAnimationDuration: Double = 0.30
    @State var useLinearSelectionSweepAnimation = false
    @State var isSelectionSettled = true
    @State var settleWorkItem: Task<Void, Never>?
    @State var didPlayLimitForCurrentHold = false
    @State var activeDirectionalHoldKey: KeyCode = .none
    @State var directionalHoldPressStartTime: Date?
    @State var directionalHoldStartWorkItem: Task<Void, Never>?
    @State var directionalHoldTickWorkItem: Task<Void, Never>?
    @State var directionalHoldRepeatPhaseStartTime: Date?
    @State var lastHoldNavigationTime: Date?
    @State var lastArrowNavigationInputTime: Date?

    // MARK: - Third menu state

    @State var selectedThirdIndex = 0
    @State var thirdMenuMode: ThirdMenuMode = .none
    @State var thirdMenuItems: [MoviesFolderEntry] = []
    @State var thirdMenuRootURL: URL?
    @State var thirdMenuCurrentURL: URL?
    @State var movieLibraryRootURLs: [URL] = []

    // MARK: - iTunes Top state

    @State var iTunesTopMovies: [ITunesTopMovieEntry] = []
    @State var iTunesTopTVEpisodes: [ITunesTopTVEpisodeEntry] = []
    @State var iTunesTopSongs: [ITunesTopSongEntry] = []
    @State var iTunesTopMusicVideos: [ITunesTopMusicVideoEntry] = []
    @State var iTunesTopStateByKind: [ITunesTopCarouselKind: ITunesTopKindState] = ITunesTopCarouselKind.defaultStateMap
    @State var tvShowsSortMode: TVShowsSortMode = .show

    // MARK: - Music library state

    @State var musicCategoryThirdMenuItems: [MusicCategoryEntry] = []
    @State var musicSongsThirdMenuItems: [MusicLibrarySongEntry] = []
    @State var activeMusicCategoryKind: MusicCategoryKind?
    @State var activeMusicCategoryMenuTitle: String = ""
    @State var lastSelectedMusicCategoryIndex: Int = 0
    @State var isMusicSongsCategoryScoped = false
    @State var activeMusicLibraryMediaType: MusicLibraryMediaType = .songs
    @State var musicSongsShowsShuffleAction = false
    @State var isLoadingMusicSongs = false
    @State var musicSongsLoadError: String?
    @State var musicSongsRequestID = 0
    @State var musicShuffleRequestID = 0
    @State var musicStartupPreloadRequestID = 0
    @State var musicAllSongsCache: [MusicLibrarySongEntry]?
    @State var musicShuffleSongsCache: [MusicLibrarySongEntry]?
    @State var musicLibraryItemIndexBySongID: [String: Int] = [:]
    @State var hasStartedStartupMusicLibraryPreload = false
    @State var isStartupMusicLibraryPreloadComplete = false
    @State var startupMusicLibraryPreloadOverlayOpacity: Double = 1

    // MARK: - Movie playback state

    @State var moviePlayer: AVPlayer?
    @State var currentMoviePlaybackURL: URL?
    @State var currentMoviePlaybackTemporaryFileURL: URL?
    @State var isCurrentMoviePlaybackEphemeralPreview = false
    @State var lastClosedMovieURL: URL?
    @State var lastClosedMovieTimestamp: Double = 0
    @State var isMoviePlaybackVisible = false
    @State var isMovieTransitioning = false
    @State var movieTransitionOverlayOpacity: Double = 0
    @State var isMovieResumePromptVisible = false
    @State var isMovieResumePromptConfirming = false
    @State var movieResumePromptSelectedIndex = 0
    @State var movieResumePromptHideUnselected = false
    @State var movieResumePromptSolidBlackSelected = false
    @State var movieResumePromptTargetURL: URL?
    @State var movieResumePromptResumeSeconds: Double = 0
    @State var movieResumePromptBackdropImage: NSImage?
    @State var movieResumePromptBackdropRequestID = 0
    @State var movieResumePromptBackdropCache: [String: NSImage] = [:]
    @State var movieResumePromptOpacity: Double = 0
    @State var areMovieControlsVisible = false
    @State var movieControlsOpacity: Double = 0
    @State var movieControlsHideWorkItem: Task<Void, Never>?
    @State var movieControlsGlyphState: MoviePlaybackGlyphState = .pause
    @State var isMoviePreviewDownloadLoading = false
    @State var moviePreviewDownloadProgress: Double = 0
    @State var moviePlaybackCurrentSeconds: Double = 0
    @State var moviePlaybackDurationSeconds: Double = 0
    @State var pendingMovieControlsRevealOnDurationReady = false
    @State var movieTimeObserverToken: Any?
    @State var moviePlaybackDidEndObserver: NSObjectProtocol?
    @State var observedMoviePlayer: AVPlayer?
    @State var movieScrubDirection: Int = 0
    @State var movieScrubStartDate: Date?
    @State var movieLastScrubInputDate: Date?
    @State var movieLastScrubTickDate: Date?
    @State var movieScrubTimer: Timer?
    @State var moviePlaybackValidationRequestID = 0

    // MARK: - Movies library state

    @State var menuSceneOpacity: Double = 1
    @State var menuFolderSwapOverlayOpacity: Double = 0
    @State var moviePreviewTargetURL: URL?
    @State var moviePreviewImage: NSImage?
    @State var moviePreviewRequestID = 0
    @State var moviePreviewCache: [String: NSImage] = [:]
    @State var moviesFolderSelectionIndexByDirectoryPath: [String: Int] = [:]
    @State var moviesFolderSubmenuPreviewDescriptors: [MovieGapPreviewDescriptor] = []
    @State var moviesFolderSubmenuPreviewIdentity: String = ""
    @State var moviesFolderSubmenuPreviewRequestID = 0
    @State var isLoadingMoviesFolderEntries = false
    @State var moviesFolderEntriesRequestID = 0

    // MARK: - Music preview/carousel state

    @State var musicPreviewTargetSongID: String?
    @State var musicPreviewImage: NSImage?
    @State var musicPreviewRequestID = 0
    @State var musicPreviewCache: [String: NSImage] = [:]
    @State var musicLibraryArtworkDataByAlbumKey: [String: Data] = [:]
    @State var musicTopLevelCarouselActiveSubmenuID: String?
    @State var musicTopLevelCarouselArtworksByIndex: [Int: NSImage?] = [:]
    @State var musicTopLevelCarouselLoadedArtworkCount = 0
    @State var musicTopLevelCarouselResolvedArtworkCount: Int?
    @State var musicTopLevelCarouselPageStartsInFlight: Set<Int> = []
    @State var musicTopLevelCarouselRequestID = 0
    @State var isLoadingMusicTopLevelCarousel = false
    @State var musicTopLevelCarouselLoadOverlayOpacity: Double = 0

    // MARK: - Podcasts state

    @State var podcastSeriesItems: [PodcastSeriesEntry] = []
    @State var podcastEpisodesThirdMenuItems: [PodcastEpisodeEntry] = []
    @State var activePodcastSeriesID: String?
    @State var activePodcastPlaybackSeriesID: String?
    @State var activePodcastPlaybackEpisodeID: String?
    @State var isLoadingPodcasts = false
    @State var podcastsLoadError: String?
    @State var podcastsRequestID = 0
    @State var podcastsHasLoadedAtLeastOnce = false
    @State var hasPresentedNoPodcastsErrorInCurrentSession = false
    @State var isResolvingPodcastsRootSelection = false

    // MARK: - Photos state

    @State var photosDateAlbums: [PhotoLibraryAlbumEntry] = []
    @State var photosDateAlbumMenuItems: [MenuListItemConfig] = []
    @State var photosLastTwelveMonthsAlbum: PhotoLibraryAlbumEntry?
    @State var isLoadingPhotoLibrary = false
    @State var photoLibraryLoadError: String?
    @State var photoLibraryHasLoadedAtLeastOnce = false
    @State var photoLibraryRequestID = 0
    @State var photosAlbumCoverImageCache: [String: NSImage] = [:]
    @State var photosAlbumCoverRequestsInFlight: Set<String> = []
    @State var photosCarouselArtworks: [NSImage?] = []
    @State var photosCarouselIdentity: String = ""
    @State var photosCarouselRequestID = 0
    @State var photosCarouselLoadOverlayOpacity: Double = 0
    @State var photoSlideshowRequestID = 0
    @State var photoSlideshowAssetLocalIdentifiers: [String] = []
    @State var photoSlideshowImageCache: [Int: NSImage] = [:]
    @State var photoSlideshowImageRequestsInFlight: Set<Int> = []
    @State var photoSlideshowImageFallbackAttempted: Set<Int> = []
    @State var photoSlideshowVisiblePrimaryIndex = 0
    @State var photoSlideshowVisibleSecondaryIndex: Int?
    @State var photoSlideshowAlbumTitle: String = ""
    @State var photoSlideshowPlaybackStartDate = Date()
    @State var photoSlideshowPlaybackElapsedOffset: TimeInterval = 0
    @State var photoSlideshowIsPaused = false
    @State var photoSlideshowPausedIndex = 0
    @State var photoSlideshowDidSeekWhilePaused = false
    @State var photoSlideshowHasFinished = false
    @State var photoSlideshowResolvedMusicEntry: MusicLibrarySongEntry?
    @State var photoSlideshowMusicURL: URL?
    @State var photoSlideshowMusicPlayer: AVPlayer?
    @State var observedPhotoSlideshowMusicPlayer: AVPlayer?
    @State var photoSlideshowMusicDidEndObserver: NSObjectProtocol?
    @State var photoSlideshowMusicFallbackWorkItem: Task<Void, Never>?
    @State var photoSlideshowMusicHasStarted = false
    @State var photoSlideshowUsesAppleScriptMusic = false

    // MARK: - Music playback state

    @State var deferNowPlayingMenuItemUntilAfterFadeOut = false
    @State var holdNowPlayingMenuItemDuringExitFade = false
    @State var isMusicSongsShuffleMode = false
    @State var activeMusicPlaybackQueue: [MusicLibrarySongEntry] = []
    @State var activeMusicPlaybackSongID: String?
    @State var musicNowPlayingTitle = "Unknown Song"
    @State var musicNowPlayingArtist = "Unknown Artist"
    @State var musicNowPlayingAlbum = ""
    @State var musicNowPlayingTrackPositionText = ""
    @State var musicNowPlayingArtwork: NSImage?
    @State var musicNowPlayingArtworkRequestID: Int = 0
    @State var musicNowPlayingElapsedSeconds: Double = 0
    @State var musicNowPlayingDurationSeconds: Double = 0
    @State var musicNowPlayingShowsShuffleGlyph = false
    @State var musicNowPlayingLeadingGlyphState: MoviePlaybackGlyphState?
    @State var musicSongTransitionSnapshot: MusicNowPlayingSnapshot?
    @State var musicSongTransitionOutgoingProgress: CGFloat = 0
    @State var musicSongTransitionOutgoingOpacityProgress: CGFloat = 0
    @State var musicSongTransitionIncomingProgress: CGFloat = 0
    @State var musicSongTransitionDirection: Int = 1
    @State var musicSongTransitionRequestID: Int = 0
    @State var musicSongTransitionDeadline: Date?
    @State var isMusicSongTransitioning = false
    @State var musicNowPlayingFlipRotationDegrees: Double = 0
    @State var musicNowPlayingUsesAlternateLayout = false
    @State var musicNowPlayingFlipTimer: Timer?
    @State var musicNowPlayingFlipMidpointWorkItem: Task<Void, Never>?
    @State var musicNowPlayingFlipGeneration: Int = 0
    @State var isMusicNowPlayingFlipAnimating = false
    @State var musicAudioPlayer: AVPlayer?
    @State var isCurrentMusicPlaybackUsingAppleScript = false
    @State var currentMusicPlaybackTemporaryFileURL: URL?
    @State var musicTimeObserverToken: Any?
    @State var musicPlaybackDidEndObserver: NSObjectProtocol?
    @State var observedMusicAudioPlayer: AVPlayer?
    @State var musicScrubDirection: Int = 0
    @State var musicScrubStartDate: Date?
    @State var musicLastScrubInputDate: Date?
    @State var musicLastScrubTickDate: Date?
    @State var musicScrubTimer: Timer?
    #if os(tvOS)
        @State var musicKitProgressTimer: Timer?
        @State var musicKitScrubGlyphResetWorkItem: Task<Void, Never>?
        @State var musicKitDidHandleTrackEnd = false
    #endif

    // MARK: - Fullscreen / transitions state

    @State var activeFullscreenScene: FullscreenScenePresentation?
    @State var fullscreenSceneOpacity: Double = 0
    @State var fullscreenTransitionOverlayOpacity: Double = 0
    @State var isFullscreenSceneTransitioning = false
    @State var isMenuFolderSwapTransitioning = false
    @State var theatricalTrailersLoadingShowsSpinner = false
    @State var theatricalTrailersLoadingRequestID = 0

    // MARK: - Screen saver state

    @State var screenSaverNowPlayingToastOpacity: Double = 0
    @State var screenSaverNowPlayingToastHideWorkItem: Task<Void, Never>?
    @State var screenSaverPendingMusicTrackSwitchDelta = 0
    @State var screenSaverPendingMusicTrackSwitchWorkItem: Task<Void, Never>?
    @State var lastUserInteractionAt = Date()
    @State var screenSaverIdleMonitorTimer: Timer?

    // MARK: - Settings

    @AppStorage("isUISoundEffectsEnabled") var isUISoundEffectsEnabled = true
    @AppStorage("isScreenSaverEnabled") var isScreenSaverEnabled = true

    #if os(iOS)
        @State var isMoviesFolderPickerPresented = false
        @State var hasPromptedMoviesFolderPickerThisSession = false
    #endif
}

extension MenuView {
    @discardableResult
    func incrementRequestID(_ requestID: inout Int) -> Int {
        requestID = requestID &+ 1
        return requestID
    }
}
