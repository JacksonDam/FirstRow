import Foundation

/// The Tiger look keeps podcasts where they always were: the ones to listen to under Music,
/// the ones to watch under Videos. Each opens a page of series, and a series a page of its
/// episodes.
enum TigerPodcastKind {
    case audio
    case video

    var submenuItemID: String {
        self == .audio ? "music_podcasts" : "movies_video_podcasts"
    }

    var rootID: String {
        self == .audio ? "music" : "movies"
    }

    var emptyMessage: String {
        self == .audio ? L("No Podcasts") : L("No Video Podcasts")
    }
}

struct TigerPodcastsState {
    var kind: TigerPodcastKind
    /// The page of series is up (and not one series' episodes).
    var showsSeries = true
    var title: String
}

extension MenuView {
    /// The series that have something of `kind`, each with only its episodes of that kind.
    func tigerPodcastSeries(of kind: TigerPodcastKind) -> [PodcastSeriesEntry] {
        podcastSeriesItems.compactMap { series in
            let episodes = series.episodes.filter { $0.isVideo == (kind == .video) }
            guard !episodes.isEmpty else { return nil }
            return PodcastSeriesEntry(id: series.id, title: series.title, artist: series.artist, description: series.description, artwork: series.artwork, episodes: episodes)
        }
    }

    /// Podcasts (or Video Podcasts) chosen in a section's list.
    func tigerEnterPodcasts(_ kind: TigerPodcastKind, title: String) {
        if podcastsLoadError != nil || !podcastsHasLoadedAtLeastOnce {
            tigerLoadPodcasts {
                guard self.activeRootItemID == kind.rootID, self.isInSubmenu, !self.isInThirdMenu else { return }
                if self.podcastsLoadError == nil, self.tigerPodcastSeries(of: kind).isEmpty {
                    self.presentFeatureErrorScreen(.noPodcasts)
                    return
                }
                self.tigerShowPodcastSeries(kind, title: title)
            }
            return
        }
        if tigerPodcastSeries(of: kind).isEmpty {
            presentFeatureErrorScreen(.noPodcasts)
            return
        }
        tigerShowPodcastSeries(kind, title: title)
    }

    /// Reads the podcasts that have been downloaded (the row that asked turns meanwhile).
    private func tigerLoadPodcasts(then finish: @escaping () -> Void) {
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
                self.podcastsLoadError = L("Podcasts library access denied")
                finish()
                return
            }
            Task(priority: .userInitiated) {
                do {
                    let series = try self.loadDownloadedPodcastSeries()
                    await MainActor.run {
                        guard self.podcastsRequestID == requestID else { return }
                        self.isLoadingPodcasts = false
                        self.podcastSeriesItems = series
                        self.podcastsHasLoadedAtLeastOnce = true
                        self.podcastsLoadError = nil
                        finish()
                    }
                } catch {
                    await MainActor.run {
                        guard self.podcastsRequestID == requestID else { return }
                        self.isLoadingPodcasts = false
                        self.podcastSeriesItems = []
                        self.podcastEpisodesThirdMenuItems = []
                        self.activePodcastSeriesID = nil
                        self.podcastsHasLoadedAtLeastOnce = true
                        self.podcastsLoadError = self.podcastsLibraryErrorMessage(for: error)
                        finish()
                    }
                }
            }
        }
    }

    private func tigerShowPodcastSeries(_ kind: TigerPodcastKind, title: String) {
        transitionMenuForFolderSwap {
            let count = self.tigerPodcastSeries(of: kind).count
            self.tiger.podcasts = TigerPodcastsState(kind: kind, showsSeries: true, title: title)
            self.activePodcastSeriesID = nil
            self.podcastEpisodesThirdMenuItems = []
            self.isInThirdMenu = true
            self.thirdMenuMode = .podcastsEpisodes
            self.selectedThirdIndex = min(self.tiger.podcastSeriesIndex[kind] ?? 0, max(0, count - 1))
            self.headerText = title
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
    }

    /// The rows of the page of series.
    func tigerPodcastSeriesListItems(_ kind: TigerPodcastKind) -> [MenuListItemConfig] {
        let series = tigerPodcastSeries(of: kind)
        if isLoadingPodcasts, series.isEmpty { return [] }
        if let podcastsLoadError, series.isEmpty {
            return [menuMessageItem(id: "podcasts_error", title: podcastsLoadError)]
        }
        if series.isEmpty {
            return [menuMessageItem(id: "podcasts_empty", title: kind.emptyMessage)]
        }
        return series.map { entry in
            plainMenuListItem(id: entry.id, title: entry.title, leadsToMenu: true, showsBlueDot: entry.episodes.contains { self.podcastEpisodeIsRecent($0.airedDate) })
        }
    }

    /// The keys on the page of series. Returns false for a key that isn't its own.
    func tigerHandlePodcastSeriesKey(_ key: KeyCode, isRepeat: Bool) -> Bool {
        guard let podcasts = tiger.podcasts, podcasts.showsSeries, isInThirdMenu else { return false }
        let series = tigerPodcastSeries(of: podcasts.kind)
        switch key {
        case .upArrow, .downArrow:
            let direction = key == .downArrow ? 1 : -1
            guard !series.isEmpty, prepareNavigationTiming(direction: direction, isRepeat: isRepeat) else { return true }
            let next = max(0, min(series.count - 1, selectedThirdIndex + direction))
            guard next != selectedThirdIndex else {
                playLimitSoundOnceForCurrentHold()
                return true
            }
            didPlayLimitForCurrentHold = false
            markSelectionAsMoving()
            playSound(named: "SelectionChange")
            selectedThirdIndex = next
            tiger.podcastSeriesIndex[podcasts.kind] = next
        case .enter:
            resetNavigationAccelerationState()
            playSound(named: "Selection")
            if podcastsLoadError != nil {
                // (The row that says it couldn't be read: asked again.)
                tigerLoadPodcasts {}
            } else if series.indices.contains(selectedThirdIndex) {
                tigerOpenPodcastSeries(series[selectedThirdIndex], kind: podcasts.kind)
            }
        case .delete, .escape:
            resetNavigationAccelerationState()
            playSound(named: "Exit")
            transitionMenuForFolderSwap {
                self.tiger.podcasts = nil
                self.activePodcastSeriesID = nil
                self.podcastEpisodesThirdMenuItems = []
                self.isInThirdMenu = false
                self.thirdMenuMode = .none
                self.thirdMenuOpacity = 0
                self.submenuOpacity = 1
                self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
            }
        case .leftArrow, .rightArrow:
            resetNavigationAccelerationState()
        default:
            break
        }
        return true
    }

    private func tigerOpenPodcastSeries(_ series: PodcastSeriesEntry, kind: TigerPodcastKind) {
        // (On the episode that is playing, when it is one of these.)
        let playing = activePodcastPlaybackSeriesID == series.id ? series.episodes.firstIndex { $0.id == activePodcastPlaybackEpisodeID } : nil
        transitionMenuForFolderSwap {
            self.tiger.podcasts?.showsSeries = false
            self.thirdMenuMode = .podcastsEpisodes
            self.isInThirdMenu = true
            self.activePodcastSeriesID = series.id
            self.podcastEpisodesThirdMenuItems = series.episodes
            self.selectedThirdIndex = min(playing ?? 0, max(0, series.episodes.count - 1))
            self.headerText = self.truncatedPodcastSeriesHeaderTitle(series.title)
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
    }

    /// Back from a series' episodes: to the page of series, on the series that was open.
    func tigerLeavePodcastEpisodes() {
        guard let podcasts = tiger.podcasts, !podcasts.showsSeries else { return }
        transitionMenuForFolderSwap {
            let count = self.tigerPodcastSeries(of: podcasts.kind).count
            self.tiger.podcasts?.showsSeries = true
            self.activePodcastSeriesID = nil
            self.podcastEpisodesThirdMenuItems = []
            self.thirdMenuMode = .podcastsEpisodes
            self.selectedThirdIndex = min(self.tiger.podcastSeriesIndex[podcasts.kind] ?? 0, max(0, count - 1))
            self.headerText = podcasts.title
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
    }

    /// The episode that is chosen on a page of episodes to watch, for the preview beside it.
    func tigerVideoPodcastPreviewURL() -> URL? {
        guard let podcasts = tiger.podcasts, podcasts.kind == .video, !podcasts.showsSeries, isInThirdMenu, thirdMenuMode == .podcastsEpisodes else { return nil }
        guard podcastEpisodesThirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
        guard let url = podcastEpisodesThirdMenuItems[selectedThirdIndex].mediaURL, url.isFileURL else { return nil }
        return url.standardizedFileURL
    }
}
