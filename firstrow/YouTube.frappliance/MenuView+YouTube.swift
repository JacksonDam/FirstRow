import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// What a YouTube page lists.
enum YouTubeMenuPage: Equatable {
    case list(YouTubeList)
    case search(String)
    case history
    case related(YouTubeVideo)

    var title: String {
        switch self {
        case let .list(list): list.title
        case let .search(query): query
        case .history: "History"
        case .related: "Related Videos"
        }
    }

    var emptyTitle: String {
        switch self {
        case .search: "No Videos Found"
        case .history: "Nothing Watched Yet"
        default: "No Videos"
        }
    }
}

struct YouTubePageState {
    var page: YouTubeMenuPage
    var selectedIndex = 0
    /// The row to select again once the page has loaded, after coming back to it.
    var selectedRowID: String?
    var videos: [YouTubeVideo] = []
    var continuation: YouTubeContinuation?
    var isLoaded = false
    var isLoadingMore = false
}

/// The YouTube pages' state, kept together so the menu holds one value for all of it.
struct YouTubeMenuState {
    var pages: [YouTubePageState] = []
    var error: String?
    var status: String?
    var requestID = 0
    /// The video the preview shows, its picture, and what was found out about videos lately.
    var previewVideoID: String?
    var previewImage: NSImage?
    /// The small pictures of list rows, by video.
    var rowPictures: [String: NSImage] = [:]
    var rowPictureOrder: [String] = []
    var rowPicturesInFlight: Set<String> = []
    var details: [String: YouTubeVideoDetails] = [:]
    var detailsOrder: [String] = []
    var detailsRequestID = 0
    var isStartingPlayback = false
    /// The menu's carousel: the pictures of each list's first videos (by the list's row),
    /// the lists being fetched, and the one last shown, which stays while a row that has
    /// no pictures (yet, or ever: Search) is selected.
    var carouselPictures: [String: [NSImage?]] = [:]
    var carouselInFlight: Set<String> = []
    var carouselShownKey: String?
    /// A list's first page, fetched for the carousel and kept for when the list is opened.
    var firstPages: [String: (page: YouTubePage, fetched: Date)] = [:]
}

/// YouTube: lists of videos, search and what was watched here.
extension MenuView {
    static let youtubeVideoRowPrefix = "youtube_video_"

    var currentYouTubePage: YouTubePageState? {
        youtube.pages.last
    }

    // MARK: - The YouTube menu

    func youtubeSubmenuItems() -> [SubmenuItemConfig] {
        var items: [SubmenuItemConfig] = []
        // (No dividers: with them the menu's rows were a little more than the list shows,
        // and the last was cut off.)
        for list in [YouTubeList.music, .trailers, .gaming, .news, .sports, .live] {
            items.append(SubmenuItemConfig(id: "youtube_list_\(Self.youtubeListToken(list))", title: list.title, leadsToMenu: true))
        }
        items.append(SubmenuItemConfig(id: "youtube_history", title: "History", leadsToMenu: true))
        items.append(SubmenuItemConfig(id: "youtube_search", title: "Search", trailingText: "..."))
        return items
    }

    private static func youtubeListToken(_ list: YouTubeList) -> String {
        switch list {
        case .music: "music"
        case .trailers: "trailers"
        case .gaming: "gaming"
        case .news: "news"
        case .sports: "sports"
        case .live: "live"
        case .channel: "channel"
        }
    }

    private static let youtubeMenuLists: [YouTubeList] = [.music, .trailers, .gaming, .news, .sports, .live]

    // MARK: - The menu's carousel

    /// What the carousel beside the YouTube menu is asked to show: the selected row's list,
    /// or the videos watched here. Nil on a row that leads to no videos, and in the lists.
    private var youtubeCarouselKey: String? {
        guard let id = selectedSubmenuItemID(for: "youtube") else { return nil }
        if id == "youtube_history" {
            let history = YouTubeStore.shared.history
            return history.first.map { "history:\($0.id):\(history.count)" }
        }
        return Self.youtubeMenuLists.contains { id == "youtube_list_\(Self.youtubeListToken($0))" } ? id : nil
    }

    /// The pictures the carousel shows now: the selected row's once they're here, until then
    /// (and on rows with none) the ones it showed last.
    var youtubeCarouselPictures: (key: String, pictures: [NSImage?])? {
        guard selectedSubmenuItemID(for: "youtube") != nil else { return nil }
        if let key = youtubeCarouselKey, let pictures = youtube.carouselPictures[key] { return (key, pictures) }
        if let key = youtube.carouselShownKey, let pictures = youtube.carouselPictures[key] { return (key, pictures) }
        return nil
    }

    private func loadYouTubeCarouselIfNeeded() {
        guard let key = youtubeCarouselKey else { return }
        if youtube.carouselPictures[key] != nil {
            if youtube.carouselShownKey != key { youtube.carouselShownKey = key }
            return
        }
        guard !youtube.carouselInFlight.contains(key) else { return }
        youtube.carouselInFlight.insert(key)
        Task { @MainActor in
            defer { self.youtube.carouselInFlight.remove(key) }
            // (Once the selection has rested on the row: rows passed over ask for nothing.)
            try? await firstRowSleep(0.3)
            guard self.youtubeCarouselKey == key else { return }
            var videos: [YouTubeVideo] = []
            if key.hasPrefix("history:") {
                videos = YouTubeStore.shared.history
            } else if let list = Self.youtubeMenuLists.first(where: { key == "youtube_list_\(Self.youtubeListToken($0))" }) {
                guard let page = try? await YouTubeClient.shared.videos(in: list) else { return }
                self.youtube.firstPages[key] = (page, Date())
                videos = page.videos
            }
            let chosen = Array(videos.prefix(10))
            var pictures = [NSImage?](repeating: nil, count: chosen.count)
            await withTaskGroup(of: (Int, NSImage?).self) { group in
                for (index, video) in chosen.enumerated() {
                    group.addTask { await (index, self.loadYouTubeThumbnail(for: video)) }
                }
                for await (index, picture) in group { pictures[index] = picture }
            }
            let found = pictures.filter { $0 != nil }
            guard found.count >= 3 else { return }
            // (The pictures of what was watched here change with it: the old ones go.)
            if key.hasPrefix("history:") {
                for old in self.youtube.carouselPictures.keys where old.hasPrefix("history:") { self.youtube.carouselPictures[old] = nil }
            }
            self.youtube.carouselPictures[key] = found
            if self.youtubeCarouselKey == key { self.youtube.carouselShownKey = key }
        }
    }

    /// Handles a row of the YouTube menu. Returns false for a row that isn't one of its own.
    func triggerYouTubeSubmenuItem(_ item: SubmenuItemConfig) -> Bool {
        let lists = Self.youtubeMenuLists
        if let list = lists.first(where: { item.id == "youtube_list_\(Self.youtubeListToken($0))" }) {
            playSound(named: "Selection")
            enterYouTube(.list(list))
            return true
        }
        switch item.id {
        case "youtube_history":
            playSound(named: "Selection")
            enterYouTube(.history)
        case "youtube_search":
            playSound(named: "Selection")
            askForYouTubeSearch()
        default:
            return false
        }
        return true
    }

    // MARK: - Rows

    func youtubeMenuListItems() -> [MenuListItemConfig] {
        guard let state = currentYouTubePage else { return [] }
        var items: [MenuListItemConfig] = []
        if let status = youtube.status {
            items.append(menuMessageItem(id: "youtube_status", title: status))
        } else if let error = youtube.error {
            items.append(menuMessageItem(id: "youtube_error", title: error))
        }
        guard state.isLoaded else { return items }
        if state.videos.isEmpty, youtube.error == nil {
            return [menuMessageItem(id: "youtube_empty", title: state.page.emptyTitle)]
        }
        for (index, video) in state.videos.enumerated() {
            var item = plainMenuListItem(
                id: Self.youtubeVideoRowPrefix + String(index),
                title: video.title,
                leadingImage: youtube.rowPictures[video.id],
                trailingText: video.isLive ? "Live" : video.durationText,
            )
            item.media = MenuRowMedia(
                byline: video.channel,
                length: video.isLive ? "Live" : (video.durationText ?? ""),
                count: video.viewsText ?? video.publishedText ?? "",
            )
            items.append(item)
        }
        return items
    }

    /// Fetches the small pictures of the rows around the selection that don't have theirs yet.
    private func loadYouTubeRowPictures() {
        guard thirdMenuMode == .youtube, let state = currentYouTubePage, state.isLoaded else { return }
        let offset = youtubeMenuListItems().count - state.videos.count
        let center = selectedThirdIndex - offset
        let wanted = (center - 6 ... center + 12).filter { state.videos.indices.contains($0) }.map { state.videos[$0] }
        for video in wanted where youtube.rowPictures[video.id] == nil && !youtube.rowPicturesInFlight.contains(video.id) {
            guard let url = video.rowThumbnailURL else { continue }
            youtube.rowPicturesInFlight.insert(video.id)
            Task { @MainActor in
                let image = await self.loadYouTubeImage(url, maxPixelSize: 400)
                self.youtube.rowPicturesInFlight.remove(video.id)
                guard let image else { return }
                self.youtube.rowPictures[video.id] = image
                self.youtube.rowPictureOrder.append(video.id)
                // (Bounded: the ones fetched longest ago go.)
                while self.youtube.rowPictureOrder.count > 80 {
                    self.youtube.rowPictures[self.youtube.rowPictureOrder.removeFirst()] = nil
                }
            }
        }
    }

    private func youtubeVideoIndex(forRowID id: String) -> Int? {
        guard id.hasPrefix(Self.youtubeVideoRowPrefix) else { return nil }
        return Int(id.dropFirst(Self.youtubeVideoRowPrefix.count))
    }

    var shouldHideYouTubeMenuUntilLoaded: Bool {
        guard let state = currentYouTubePage else { return false }
        return !state.isLoaded && youtube.error == nil
    }

    /// The video under the selection on the current page.
    var selectedYouTubeVideo: YouTubeVideo? {
        guard thirdMenuMode == .youtube, let state = currentYouTubePage else { return nil }
        let rows = youtubeMenuListItems()
        guard rows.indices.contains(selectedThirdIndex), let index = youtubeVideoIndex(forRowID: rows[selectedThirdIndex].id),
              state.videos.indices.contains(index)
        else { return nil }
        return state.videos[index]
    }

    /// Shows a message above the rows (or clears it) while keeping the same row selected.
    private func showYouTubeMessage(error: String? = nil, status: String? = nil) {
        let rows = youtubeMenuListItems()
        let selectedID = rows.indices.contains(selectedThirdIndex) ? rows[selectedThirdIndex].id : nil
        youtube.error = error
        youtube.status = status
        if let selectedID, let index = youtubeMenuListItems().firstIndex(where: { $0.id == selectedID }) {
            selectedThirdIndex = index
        }
    }

    // MARK: - Moving between pages

    /// Opens a page from the YouTube menu.
    func enterYouTube(_ page: YouTubeMenuPage) {
        youtube.requestID &+= 1
        transitionMenuForFolderSwap(useOverlayFade: true, revealWhen: { !self.shouldHideYouTubeMenuUntilLoaded }) {
            self.thirdMenuMode = .youtube
            self.isInThirdMenu = true
            self.youtube.pages = [YouTubePageState(page: page)]
            self.youtube.error = nil
            self.youtube.status = nil
            self.selectedThirdIndex = 0
            self.headerText = self.truncatedHeaderTitle(page.title, fallback: "YouTube")
            self.clearYouTubePreview()
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
            self.loadCurrentYouTubePage()
        }
    }

    func pushYouTubePage(_ page: YouTubeMenuPage) {
        transitionMenuForFolderSwap(revealWhen: { !self.shouldHideYouTubeMenuUntilLoaded }) {
            self.rememberYouTubeSelection()
            self.youtube.pages.append(YouTubePageState(page: page))
            self.youtube.error = nil
            self.youtube.status = nil
            self.selectedThirdIndex = 0
            self.headerText = self.truncatedHeaderTitle(page.title, fallback: "YouTube")
            self.clearYouTubePreview()
            self.loadCurrentYouTubePage()
        }
    }

    func navigateUpInYouTubeMenu() {
        youtube.requestID &+= 1
        guard youtube.pages.count > 1 else {
            exitYouTubeToItsMenu()
            return
        }
        transitionMenuForFolderSwap(revealWhen: { !self.shouldHideYouTubeMenuUntilLoaded }) {
            self.youtube.pages.removeLast()
            self.youtube.error = nil
            self.youtube.status = nil
            guard let page = self.currentYouTubePage else { return }
            self.headerText = self.truncatedHeaderTitle(page.page.title, fallback: "YouTube")
            self.clearYouTubePreview()
            if page.isLoaded {
                self.selectYouTubeRememberedRow()
                self.refreshDetailPreviewForCurrentContext()
            } else {
                self.selectedThirdIndex = 0
                self.loadCurrentYouTubePage()
            }
        }
    }

    private func rememberYouTubeSelection() {
        let rows = youtubeMenuListItems()
        guard var current = youtube.pages.popLast() else { return }
        current.selectedIndex = selectedThirdIndex
        current.selectedRowID = rows.indices.contains(selectedThirdIndex) ? rows[selectedThirdIndex].id : nil
        youtube.pages.append(current)
    }

    private func selectYouTubeRememberedRow() {
        guard let index = youtube.pages.indices.last else { return }
        let page = youtube.pages[index]
        let rows = youtubeMenuListItems()
        if let id = page.selectedRowID, let row = rows.firstIndex(where: { $0.id == id }) {
            selectedThirdIndex = row
        } else {
            selectedThirdIndex = min(page.selectedIndex, max(0, rows.count - 1))
        }
        youtube.pages[index].selectedRowID = nil
    }

    private func exitYouTubeToItsMenu() {
        transitionMenuForFolderSwap(useOverlayFade: true) {
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.youtube.pages = []
            self.youtube.error = nil
            self.youtube.status = nil
            self.clearYouTubePreview()
            let items = self.currentSubmenuItems()
            self.selectedSubIndex = min(self.selectedSubIndex, max(0, items.count - 1))
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
        }
    }

    // MARK: - Loading

    private func loadCurrentYouTubePage() {
        guard let state = currentYouTubePage else { return }
        let requestID = youtube.requestID &+ 1
        youtube.requestID = requestID
        let pageIndex = youtube.pages.count - 1
        func finish(_ page: YouTubePage?, error: String?) {
            guard youtube.requestID == requestID, youtube.pages.indices.contains(pageIndex) else { return }
            if let page {
                youtube.pages[pageIndex].videos = page.videos
                youtube.pages[pageIndex].continuation = page.continuation
            }
            youtube.pages[pageIndex].isLoaded = true
            youtube.error = error
            if youtube.pages[pageIndex].selectedRowID != nil { selectYouTubeRememberedRow() }
            let count = youtubeMenuListItems().count
            if selectedThirdIndex >= count { selectedThirdIndex = max(0, count - 1) }
            refreshDetailPreviewForCurrentContext()
        }
        if case .history = state.page {
            finish(YouTubePage(videos: YouTubeStore.shared.history), error: nil)
            return
        }
        Task { @MainActor in
            do {
                let page: YouTubePage
                switch state.page {
                case let .list(list):
                    // (The carousel beside the menu may have fetched the list's start already.)
                    if let kept = self.youtube.firstPages["youtube_list_\(Self.youtubeListToken(list))"], Date().timeIntervalSince(kept.fetched) < 600 {
                        page = kept.page
                        break
                    }
                    page = try await YouTubeClient.shared.videos(in: list)
                case let .search(query):
                    page = try await YouTubeClient.shared.search(query)
                case let .related(video):
                    page = try await YouTubeClient.shared.details(of: video.id).related
                case .history:
                    page = YouTubePage()
                }
                finish(page, error: nil)
            } catch {
                finish(nil, error: error.localizedDescription)
            }
        }
    }

    /// Fetches the next page of the list when the selection is nearing its end.
    private func loadMoreYouTubeVideosIfNeeded() {
        guard thirdMenuMode == .youtube, let pageIndex = youtube.pages.indices.last else { return }
        let state = youtube.pages[pageIndex]
        guard state.isLoaded, !state.isLoadingMore, let continuation = state.continuation,
              selectedThirdIndex >= youtubeMenuListItems().count - 8, state.videos.count < 400
        else { return }
        youtube.pages[pageIndex].isLoadingMore = true
        let requestID = youtube.requestID
        Task { @MainActor in
            let more = try? await YouTubeClient.shared.more(continuation)
            guard self.youtube.requestID == requestID, self.youtube.pages.indices.contains(pageIndex) else { return }
            self.youtube.pages[pageIndex].isLoadingMore = false
            guard let more else {
                // (Not asked for again: the list ends where it is.)
                self.youtube.pages[pageIndex].continuation = nil
                return
            }
            let known = Set(self.youtube.pages[pageIndex].videos.map(\.id))
            var fresh = more.videos.filter { !known.contains($0.id) }
            if case let .list(.channel(_, name)) = self.youtube.pages[pageIndex].page {
                for index in fresh.indices where fresh[index].channel.isEmpty { fresh[index].channel = name }
            }
            self.youtube.pages[pageIndex].videos += fresh
            self.youtube.pages[pageIndex].continuation = fresh.isEmpty ? nil : more.continuation
        }
    }

    // MARK: - Actions

    func triggerYouTubeMenuAction() {
        let rows = youtubeMenuListItems()
        guard rows.indices.contains(selectedThirdIndex), let state = currentYouTubePage else { return }
        let id = rows[selectedThirdIndex].id
        if let index = youtubeVideoIndex(forRowID: id), state.videos.indices.contains(index) {
            playYouTubeVideo(state.videos[index])
        } else if id == "youtube_error" {
            youtube.error = nil
            if let pageIndex = youtube.pages.indices.last { youtube.pages[pageIndex].isLoaded = false }
            loadCurrentYouTubePage()
        } else {
            playLimitSoundOnceForCurrentHold()
        }
    }

    private func askForYouTubeSearch() {
        requestTextEntry(title: "Search YouTube", prompt: "Type what to look for.") { [weak self] text in
            guard let self, let query = text?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return }
            self.enterYouTube(.search(query))
        }
    }

    // MARK: - Preview

    private func clearYouTubePreview() {
        youtube.previewVideoID = nil
        youtube.previewImage = nil
    }

    func refreshYouTubePreviewForCurrentContext() {
        loadYouTubeCarouselIfNeeded()
        loadMoreYouTubeVideosIfNeeded()
        loadYouTubeRowPictures()
        guard let video = selectedYouTubeVideo else {
            clearYouTubePreview()
            return
        }
        guard youtube.previewVideoID != video.id else { return }
        youtube.previewVideoID = video.id
        youtube.previewImage = nil
        youtube.detailsRequestID &+= 1
        let detailsRequestID = youtube.detailsRequestID
        Task { @MainActor in
            let image = await self.loadYouTubeThumbnail(for: video)
            guard self.youtube.previewVideoID == video.id else { return }
            self.youtube.previewImage = image
        }
        guard youtube.details[video.id] == nil else { return }
        // What the list doesn't say (the description, the day it was added) is asked for once
        // the selection has rested on the video a moment.
        Task { @MainActor in
            try? await firstRowSleep(0.7)
            guard self.youtube.detailsRequestID == detailsRequestID, self.youtube.previewVideoID == video.id else { return }
            guard let details = try? await YouTubeClient.shared.details(of: video.id) else { return }
            self.rememberYouTubeDetails(details, for: video.id)
        }
    }

    func rememberYouTubeDetails(_ details: YouTubeVideoDetails, for videoID: String) {
        if youtube.details[videoID] == nil { youtube.detailsOrder.append(videoID) }
        youtube.details[videoID] = details
        while youtube.detailsOrder.count > 40 {
            youtube.details[youtube.detailsOrder.removeFirst()] = nil
        }
    }

    /// A video's picture: the large one, or the smaller one every video has.
    func loadYouTubeThumbnail(for video: YouTubeVideo) async -> NSImage? {
        for url in [video.largeThumbnailURL].compactMap({ $0 }) + video.fallbackThumbnailURLs {
            if let image = await loadYouTubeImage(url) { return image }
        }
        return nil
    }

    func loadYouTubeImage(_ url: URL, maxPixelSize: CGFloat = 900) async -> NSImage? {
        let key = "youtube-art::\(url.absoluteString)"
        if let cached = cachedDecodedDisplayArtworkImage(sourceKey: key, maxPixelSize: maxPixelSize) {
            return cached
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode), !data.isEmpty
        else { return nil }
        return await Task.detached(priority: .userInitiated) {
            cachedDecodedDisplayArtworkImage(from: data, sourceKey: key, maxPixelSize: maxPixelSize)
        }.value
    }

    func youtubeGapContentItems(icon: (Double, Animation?) -> GapItemSpec, pass: RenderPass, memo: inout GapContentMemo) -> [GapItemSpec] {
        let video = selectedYouTubeVideo
        let image = (video?.id == youtube.previewVideoID) ? youtube.previewImage : nil
        let key = image == nil ? "none" : (video?.id ?? "none")
        let animation = pass.animation(.easeInOut(duration: 0.22), when: memo.youtubePreviewKey != nil && memo.youtubePreviewKey != key)
        memo.youtubePreviewKey = key
        // Beside the menu itself: the selected list's videos, in Music's carousel (each
        // picture a square, as its covers are).
        if let carousel = youtubeCarouselPictures,
           let item = gapCarouselItem(key: "youtube_carousel:\(carousel.key)", artworks: carousel.pictures, exitOpacity: iTunesTopCarouselExitOverlayOpacity, asCovers: true)
        {
            return [icon(0, animation), item]
        }
        var items = [icon(image == nil ? 1 : 0, animation)]
        guard let video, let image else { return items }
        let details = youtube.details[video.id]
        var lines: [MetadataPreviewSpec.Line] = []
        if !video.channel.isEmpty { lines.append(.init(label: "From", value: video.channel)) }
        if let added = details?.dateText ?? video.publishedText, !added.isEmpty { lines.append(.init(label: "Added", value: added)) }
        if video.isLive {
            lines.append(.init(label: "Length", value: "Live"))
        } else if let length = video.durationText, !length.isEmpty {
            lines.append(.init(label: "Length", value: length))
        }
        if let views = details?.viewsText ?? video.viewsText, !views.isEmpty {
            lines.append(.init(label: "Views", value: Self.youtubeCountOnly(views)))
        }
        if let likes = details?.likesText, !likes.isEmpty { lines.append(.init(label: "Likes", value: likes)) }
        let description = Self.youtubePreviewDescription(details?.description ?? video.summary)
        items.append(GapItemSpec(
            key: "youtube_metadata",
            kind: .metadata(MetadataPreviewSpec(
                image: image,
                aspectRatio: aspectRatio(for: image, fallback: 16.0 / 9.0),
                forcedPreviewAspectRatio: nil,
                sizeScale: 0.92,
                title: video.title,
                description: description,
                lines: lines,
                baseIconSize: iconSize,
                offsetX: musicGapPreviewHorizontalOffset - 56,
                offsetY: gapContentVerticalOffset - 8,
                identity: "youtube:\(video.id)",
                transitionDelay: 0,
                animatesTransition: false,
            )),
            animation: animation,
            transition: animation,
            fade: .easeInOut(duration: 0.22),
        ))
        return items
    }

    /// The start of a video's description, for the preview: its first paragraph (and the next,
    /// if the first is only a line), a few lines at most. Descriptions run to pages of links
    /// and credits, and the picture above gives up its room to whatever is shown.
    static func youtubePreviewDescription(_ text: String?) -> String? {
        guard let text else { return nil }
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ") }
            .filter { !$0.isEmpty }
        guard var summary = paragraphs.first else { return nil }
        if summary.count < 90, paragraphs.count > 1 { summary += " " + paragraphs[1] }
        if summary.count > 260 {
            let cut = summary.prefix(260)
            let end = cut.lastIndex(of: " ") ?? cut.endIndex
            summary = String(cut[..<end]) + "…"
        }
        return summary
    }

    /// "37,398,126 views" as "37,398,126": the line is already labelled Views.
    static func youtubeCountOnly(_ text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count == 2, let first = words.first, first.first?.isNumber == true else { return text }
        return String(first)
    }
}
