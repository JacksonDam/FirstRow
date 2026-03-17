import AVFoundation
import SwiftUI

struct MenuTransitionSnapshot: Identifiable {
    let id = UUID()
    let rootID: String?
    let headerText: String
    let items: [MenuListItemConfig]
    let selectedIndex: Int
    var isNowPlayingPage: Bool = false
    var isErrorPage: Bool = false
    var isSubmenuErrorPage: Bool = false
}

enum MenuTransitionDirection {
    case forward
    case backward
}

struct MenuView: View {
    let initialBackdropImage: NSImage?
    let menuItems = MenuConfiguration.rootItems

    init(initialBackdropImage: NSImage? = nil) {
        self.initialBackdropImage = initialBackdropImage

        let rootItems = MenuConfiguration.rootItems
        let defaultRootIndex = rootItems.firstIndex(where: { $0.id == "music" }) ?? 0
        let defaultRootTitle =
            rootItems.indices.contains(defaultRootIndex)
                ? rootItems[defaultRootIndex].title
                : (rootItems.first?.title ?? "")

        _selectedIndex = State(initialValue: defaultRootIndex)
        _rootLabelText = State(initialValue: defaultRootTitle)
        _introBackdropImage = State(initialValue: initialBackdropImage)
        _rootCarouselSelectionValue = State(initialValue: Double(defaultRootIndex - 4))
    }

    // MARK: - Layout constants

    let iconSize: CGFloat = 400
    let iconSpacing: CGFloat = 80
    let menuWidth: CGFloat = 900
    let selectionBoxHeight: CGFloat = 75
    let menuRowSpacing: CGFloat = 5
    let defaultVisibleMenuRowCount: Int = 9
    let thirdLevelVisibleMenuRowCount: Int = 9
    let baselineVisibleMenuRowCount: Int = 7
    let stickySelectionRowIndex: Int = 4
    let dividerSectionGapAfterLine: CGFloat = 14
    let dividerLineInsetHorizontal: CGFloat = 33
    let dividerLineYOffsetInGap: CGFloat = 2
    let menuListBottomInset: CGFloat = 200
    let submenuTopFadeHeight: CGFloat = 30
    let submenuHeaderTopInset: CGFloat = 40
    let submenuDividerTopInset: CGFloat = 160
    let submenuDividerThickness: CGFloat = 6
    let submenuSelectionBoxLeading: CGFloat = 405
    let submenuSelectionBoxTopInset: CGFloat = 560
    let submenuListClipTopInset: CGFloat = 206
    let submenuVisibleMenuRowCount: Int = 4
    let submenuRowSpacing: CGFloat = 34
    let submenuRowHeight: CGFloat = 128
    let submenuSelectionRowPitch: CGFloat = 115
    let submenuSelectedRowContentYOffset: CGFloat = 0
    let submenuRowContentVerticalOffset: CGFloat = -5
    let submenuRowTitleFontSize: CGFloat = 69
    let submenuRowTrailingFontSize: CGFloat = 53
    let submenuArrowFontSize: CGFloat = 65
    let submenuSelectionVisualWidth: CGFloat = 1440
    let submenuSelectionVisualHeight: CGFloat = 140
    let submenuTextLeadingInset: CGFloat = 72
    let submenuTrailingSymbolRightInset: CGFloat = 206
    let submenuHeaderIconOpticalYOffset: CGFloat = 10
    let selectedCarouselReflectionYOffset: CGFloat = 0
    let selectedCarouselDetachedReflectionXOffset: CGFloat = -54
    let selectedCarouselDetachedReflectionYOffset: CGFloat = 1140
    let backgroundCarouselGroupLift: CGFloat = -820
    let backgroundCarouselZDepth: CGFloat = 960
    let arcRadius: CGFloat = 550
    let scaleReduction: CGFloat = 0.3
    let selectedCarouselAdjustedSizeMultiplier: CGFloat = 1.65
    let landedIconScale: CGFloat = 0.1512
    let landedIconVerticalMultiplier: CGFloat = 2.5
    let landedFinalYOffsetAdjustment: CGFloat = 30
    let menuHeaderVerticalOffset: CGFloat = -10
    let selectedCarouselEntryOffset: CGFloat = 200 * 1.5
    let rootCarouselRadius: CGFloat = 480
    let rootIntroStartCarouselRadius: CGFloat = 280
    let rootExitEndCarouselRadius: CGFloat = 680
    let rootCarouselTiltDegrees: Double = 26
    let rootCarouselCenterYOffset: CGFloat = -26
    let rootCarouselPerspectiveDistance: CGFloat = 2000
    let rootCarouselBaseSizeMultiplier: CGFloat = 0.8
    let rootIntroBackdropMinimumScale: CGFloat = 0.25
    let rootIntroBackdropFinalYOffset: CGFloat = -512
    let rootIntroBackdropFadeStartProgress: CGFloat = 0.75
    let rootIntroStageStartYOffset: CGFloat = 2325
    let rootIntroStageStartScale: CGFloat = 1.85
    let rootIntroStageStartOpacity: Double = 1
    let rootNavigationDurationMultiplier: Double = 1.7
    let rootIntroAnimationStartDelay: Double = 0.05
    let rootIntroLabelStartDelay: Double = 1.5
    let rootIntroLabelFadeDuration: Double = 0.25
    let rootIntroBackdropDuration: Double = 2.75

    // MARK: - Duration constants

    let iconFlightAnimationDuration: Double = 1.0
    let submenuBackgroundIconTransitionDuration: Double = 1.0
    let submenuBackgroundIconReturnDuration: Double = 1.0
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
    let rootIntroDuration: Double = 2.325
    let rootLabelFadeOutDuration: Double = 0.12
    let rootLabelFadeInDuration: Double = 0.18
    let menuSlideDuration: Double = 0.6

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
    let menuSelectionWidthScale: CGFloat = 1.16
    let menuSelectionHeightScale: CGFloat = 1.18
    let menuSlideDistance: CGFloat = 580

    // MARK: - Fullscreen scene keys

    let musicNowPlayingFullscreenKey = "music_now_playing"
    let photoSlideshowFullscreenKey = "photo_slideshow"

    // MARK: - Navigation state

    @State var selectedIndex = MenuConfiguration.rootItems.firstIndex(where: { $0.id == "music" }) ?? 0
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
    @State var submenuEntryWorkItem: DispatchWorkItem?
    @State var overflowFadeWorkItem: DispatchWorkItem?
    @State var rootLabelText = MenuConfiguration.rootItems.first(where: { $0.id == "music" })?.title
        ?? MenuConfiguration.rootItems.first?.title
        ?? ""
    @State var rootLabelOpacity: Double = 0
    @State var isRootLabelVisible = false
    @State var rootLabelSwapWorkItem: DispatchWorkItem?
    @State var rootIntroStartWorkItem: DispatchWorkItem?
    @State var rootLabelRevealWorkItem: DispatchWorkItem?
    @State var rootIntroCompletionWorkItem: DispatchWorkItem?
    @State var rootExitWorkItem: DispatchWorkItem?
    @State var introBackdropImage: NSImage?
    @State var introBackdropProgress: CGFloat = 0
    @State var introProgress: CGFloat = 0
    @State var isRootIntroRunning = true
    @State var isRootExitRunning = false
    @State var hasStartedRootIntro = false
    @State var hasAnnouncedIntroBackdropAppearance = false
    @State var rootCarouselSelectionValue: Double = 0
    @State var menuTransitionSnapshot: MenuTransitionSnapshot?
    @State var menuTransitionProgress: CGFloat = 1
    @State var menuTransitionDirection: MenuTransitionDirection = .forward
    @State var submenuTransitionProgress: CGFloat = 0

    // MARK: - Input handling state

    @State var lastNavigationKey: KeyCode = .none
    @State var navigationHoldStartTime: Date?
    @State var lastNavigationEventTime: Date?
    @State var selectionAnimationDuration: Double = 0.30
    @State var useLinearSelectionSweepAnimation = false
    @State var isSelectionSettled = true
    @State var settleWorkItem: DispatchWorkItem?
    @State var didPlayLimitForCurrentHold = false
    @State var activeDirectionalHoldKey: KeyCode = .none
    @State var directionalHoldPressStartTime: Date?
    @State var directionalHoldStartWorkItem: DispatchWorkItem?
    @State var directionalHoldTickWorkItem: DispatchWorkItem?
    @State var directionalHoldRepeatPhaseStartTime: Date?
    @State var lastHoldNavigationTime: Date?
    @State var lastArrowNavigationInputTime: Date?

    // MARK: - Third menu state

    @State var selectedThirdIndex = 0
    @State var thirdMenuMode: ThirdMenuMode = .none
    @State var thirdMenuItems: [MoviesFolderEntry] = []
    @State var thirdMenuRootURL: URL?
    @State var thirdMenuCurrentURL: URL?

    // MARK: - iTunes Top state

    @State var iTunesTopMovies: [ITunesTopMovieEntry] = []
    @State var iTunesTopSongs: [ITunesTopSongEntry] = []
    @State var iTunesTopMusicVideos: [ITunesTopMusicVideoEntry] = []
    @State var iTunesTopStateByKind: [ITunesTopCarouselKind: ITunesTopKindState] = ITunesTopCarouselKind.defaultStateMap

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
    @State var movieControlsHideWorkItem: DispatchWorkItem?
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
    @State var photoSlideshowMusicFallbackWorkItem: DispatchWorkItem?
    @State var photoSlideshowMusicHasStarted = false
    @State var photoSlideshowUsesAppleScriptMusic = false

    // MARK: - Music now-playing page state

    @State var musicNowPlayingReturnThirdMenuMode: ThirdMenuMode = .none
    @State var musicNowPlayingReturnHeaderText: String = ""

    // MARK: - Error page state

    @State var errorPageHeaderText: String = ""
    @State var errorPageSubcaptionText: String = ""
    @State var isSubmenuErrorPage: Bool = false

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
    @State var musicNowPlayingFlipMidpointWorkItem: DispatchWorkItem?
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

    // MARK: - Fullscreen / transitions state

    @State var activeFullscreenScene: FullscreenScenePresentation?
    @State var fullscreenSceneOpacity: Double = 0
    @State var fullscreenTransitionOverlayOpacity: Double = 0
    @State var isFullscreenSceneTransitioning = false
    @State var isMenuFolderSwapTransitioning = false
    @State var isTheatricalTrailersLoading = false
    @State var theatricalTrailersLoadingRequestID = 0

    @State var lastUserInteractionAt = Date()

    // MARK: - Settings

    @AppStorage("isUISoundEffectsEnabled") var isUISoundEffectsEnabled = true
}

extension MenuView {
    @discardableResult
    func incrementRequestID(_ requestID: inout Int) -> Int {
        requestID = requestID &+ 1
        return requestID
    }
}
