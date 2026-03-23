import Foundation
import SwiftUI

private let iTunesTopArtworkParallelismLimit = 4

private struct ITunesTopMoviesFeedEntry {
    let rank: Int
    let lookupID: String
    let title: String
    let summary: String?
    let artworkURL: URL?
    let storeURL: URL?
    let previewVideoURL: URL?
}

private final class ITunesTopMoviesFeedParserDelegate: NSObject, XMLParserDelegate {
    private(set) var entries: [ITunesTopMoviesFeedEntry] = []
    private var isInsideEntry = false
    private var currentElementName: String?
    private var currentElementText: String = ""
    private var currentImageHeight: Int?
    private var currentLookupID: String?
    private var currentIDURL: URL?
    private var currentFallbackTitle: String?
    private var currentMovieName: String?
    private var currentSummary: String?
    private var currentStoreURL: URL?
    private var currentArtworkURL: URL?
    private var currentArtworkHeight = -1
    private var currentPreviewVideoURL: URL?
    private func resetCurrentEntryFields() {
        currentLookupID = nil
        currentIDURL = nil
        currentFallbackTitle = nil
        currentMovieName = nil
        currentSummary = nil
        currentStoreURL = nil
        currentArtworkURL = nil
        currentArtworkHeight = -1
        currentPreviewVideoURL = nil
        currentElementName = nil
        currentElementText = ""
        currentImageHeight = nil
    }

    private func addArtworkCandidate(url: URL, height: Int?) {
        let resolvedHeight = height ?? 0
        if currentArtworkURL == nil || resolvedHeight >= currentArtworkHeight {
            currentArtworkURL = url
            currentArtworkHeight = resolvedHeight
        }
    }

    private func appendCurrentEntryIfPossible() {
        guard let currentLookupID, !currentLookupID.isEmpty else { return }
        let resolvedTitle = currentMovieName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = currentFallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (resolvedTitle?.isEmpty == false ? resolvedTitle : fallbackTitle) ?? "Unknown Movie"
        entries.append(
            ITunesTopMoviesFeedEntry(
                rank: entries.count + 1,
                lookupID: currentLookupID,
                title: title,
                summary: currentSummary,
                artworkURL: currentArtworkURL,
                storeURL: currentStoreURL ?? currentIDURL,
                previewVideoURL: currentPreviewVideoURL,
            ),
        )
    }

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:],
    ) {
        if elementName == "entry" {
            isInsideEntry = true
            resetCurrentEntryFields()
            return
        }
        guard isInsideEntry else { return }
        if elementName == "id",
           let rawLookupID = attributeDict["im:id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawLookupID.isEmpty
        {
            currentLookupID = rawLookupID
        }
        if elementName == "link",
           let href = attributeDict["href"],
           let url = URL(string: href)
        {
            let rel = attributeDict["rel"]?.lowercased() ?? ""
            if rel == "enclosure" {
                currentPreviewVideoURL = url
            } else if rel == "alternate", currentStoreURL == nil {
                currentStoreURL = url
            }
        }
        if elementName == "id" ||
            elementName == "title" ||
            elementName == "summary" ||
            elementName == "im:name" ||
            elementName == "im:image"
        {
            currentElementName = elementName
            currentElementText = ""
            currentImageHeight = elementName == "im:image"
                ? Int(attributeDict["height"] ?? "")
                : nil
            return
        }
        currentElementName = nil
        currentElementText = ""
        currentImageHeight = nil
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        guard isInsideEntry, currentElementName != nil else { return }
        currentElementText += string
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
    ) {
        guard isInsideEntry else { return }
        if currentElementName == elementName {
            let trimmed = currentElementText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                switch elementName {
                case "id":
                    currentIDURL = URL(string: trimmed)
                case "title":
                    currentFallbackTitle = trimmed
                case "summary":
                    currentSummary = trimmed
                case "im:name":
                    currentMovieName = trimmed
                case "im:image":
                    if let imageURL = URL(string: trimmed) {
                        addArtworkCandidate(url: imageURL, height: currentImageHeight)
                    }
                default:
                    break
                }
            }
            currentElementName = nil
            currentElementText = ""
            currentImageHeight = nil
        }
        if elementName == "entry" {
            appendCurrentEntryIfPossible()
            isInsideEntry = false
            resetCurrentEntryFields()
        }
    }
}

private struct _SendableITunesTopArtworkResult: @unchecked Sendable {
    let index: Int
    let itemID: String
    let image: NSImage?
}

extension MenuView {
    private nonisolated func parseITunesTopMovieFeedEntries(from xmlData: Data) -> [ITunesTopMoviesFeedEntry] {
        let parser = XMLParser(data: xmlData)
        let delegate = ITunesTopMoviesFeedParserDelegate()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.entries
    }

    private nonisolated func upgradedArtworkURLString(from rawArtwork: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "/([0-9]+)x([0-9]+)bb\\.(png|jpg|jpeg)") else {
            return rawArtwork
        }
        let nsRange = NSRange(rawArtwork.startIndex ..< rawArtwork.endIndex, in: rawArtwork)
        let matches = regex.matches(in: rawArtwork, options: [], range: nsRange)
        guard let match = matches.last,
              match.numberOfRanges >= 4,
              let wholeMatchRange = Range(match.range(at: 0), in: rawArtwork),
              let extRange = Range(match.range(at: 3), in: rawArtwork)
        else {
            return rawArtwork
        }
        let fileExtension = String(rawArtwork[extRange])
        var replaced = rawArtwork
        replaced.replaceSubrange(wholeMatchRange, with: "/2000x3000bb.\(fileExtension)")
        return replaced
    }

    private nonisolated func highResolutionITunesArtworkURL(from lowResolutionURL: URL) -> URL? {
        let raw = lowResolutionURL.absoluteString
        let upgraded = upgradedArtworkURLString(from: raw)
        guard upgraded != raw else { return nil }
        return URL(string: upgraded)
    }

    nonisolated func iTunesTopErrorMessage(for error: Error, label: String) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCannotFindHost {
            return "Unable to resolve \(label) host"
        }
        if nsError.domain == NSURLErrorDomain {
            return "Unable to reach \(label)"
        }
        return "Unable to load \(label)"
    }

    private nonisolated func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "application/xml, text/xml;q=0.9, */*;q=0.8",
            forHTTPHeaderField: "Accept",
        )
        request.setValue("firstRow/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private nonisolated var iTunesStoreRegion: String {
        let supported: Set<String> = [
            "dz", "ao", "ai", "ag", "ar", "am", "au", "at", "az", "bs", "bh", "bb", "by", "be",
            "bz", "bj", "bm", "bt", "bo", "ba", "bw", "br", "vg", "bg", "kh", "cm", "ca", "cv",
            "ky", "td", "cl", "cn", "co", "cr", "hr", "cy", "cz", "ci", "cd", "dk", "dm", "do",
            "ec", "eg", "sv", "ee", "sz", "fj", "fi", "fr", "ga", "gm", "ge", "de", "gh", "gr",
            "gd", "gt", "gw", "gy", "hn", "hk", "hu", "is", "in", "id", "iq", "ie", "il", "it",
            "jm", "jp", "jo", "kz", "ke", "kr", "xk", "kw", "kg", "la", "lv", "lb", "lr", "ly",
            "lt", "lu", "mo", "mg", "mw", "my", "mv", "ml", "mt", "mr", "mu", "mx", "fm", "md",
            "mn", "me", "ms", "ma", "mz", "mm", "na", "np", "nl", "nz", "ni", "ne", "ng", "mk",
            "no", "om", "pa", "pg", "py", "pe", "ph", "pl", "pt", "qa", "cg", "ro", "ru", "rw",
            "sa", "sn", "rs", "sc", "sl", "sg", "sk", "si", "sb", "za", "es", "lk", "kn", "lc",
            "vc", "sr", "se", "ch", "tw", "tj", "tz", "th", "to", "tt", "tn", "tm", "tc", "tr",
            "ae", "ug", "ua", "gb", "us", "uy", "uz", "vu", "ve", "vn", "ye", "zm", "zw",
        ]
        let region: String
        if #available(macOS 13, iOS 16, tvOS 16, *) {
            region = Locale.current.region?.identifier.lowercased() ?? "us"
        } else {
            region = Locale.current.regionCode?.lowercased() ?? "us"
        }
        return supported.contains(region) ? region : "us"
    }

    private nonisolated var iTunesTopMoviesFeedURLString: String {
        "https://itunes.apple.com/\(iTunesStoreRegion)/rss/topmovies/limit=10/xml"
    }

    private nonisolated var iTunesTopTVEpisodesFeedURLString: String {
        "https://itunes.apple.com/\(iTunesStoreRegion)/rss/toptvepisodes/limit=10/xml"
    }

    private nonisolated var iTunesTopSongsFeedURLString: String {
        "https://itunes.apple.com/\(iTunesStoreRegion)/rss/topsongs/limit=10/xml"
    }

    private nonisolated var iTunesTopMusicVideosFeedURLString: String {
        "https://itunes.apple.com/\(iTunesStoreRegion)/rss/topmusicvideos/limit=10/xml"
    }

    @MainActor
    func resolveCachedITunesTopPreviewMediaURL(
        for kind: ITunesTopCarouselKind,
        id: String,
        fallbackURL: URL?,
    ) -> URL? {
        if let cached = iTunesTopState(for: kind).previewMediaURLCache[id] {
            return cached
        }
        if let fallbackURL {
            updateITunesTopState(kind) { $0.previewMediaURLCache[id] = fallbackURL }
        }
        return fallbackURL
    }

    @MainActor
    func resolveITunesTopMoviePreviewVideoURL(for movie: ITunesTopMovieEntry) async -> URL? {
        resolveCachedITunesTopPreviewMediaURL(
            for: .movies,
            id: movie.id,
            fallbackURL: movie.previewVideoURL,
        )
    }

    @MainActor
    func resolveITunesTopTVEpisodePreviewVideoURL(for episode: ITunesTopTVEpisodeEntry) async -> URL? {
        resolveCachedITunesTopPreviewMediaURL(
            for: .tvEpisodes,
            id: episode.id,
            fallbackURL: episode.previewVideoURL,
        )
    }

    @MainActor
    func resolveITunesTopSongPreviewAudioURL(for song: ITunesTopSongEntry) async -> URL? {
        resolveCachedITunesTopPreviewMediaURL(
            for: .songs,
            id: song.id,
            fallbackURL: song.previewAudioURL,
        )
    }

    @MainActor
    func resolveITunesTopMusicVideoPreviewVideoURL(for video: ITunesTopMusicVideoEntry) async -> URL? {
        resolveCachedITunesTopPreviewMediaURL(
            for: .musicVideos,
            id: video.id,
            fallbackURL: video.previewVideoURL,
        )
    }

    private nonisolated func fetchITunesTopFeedEntries(
        from feedURLString: String,
    ) async throws -> [ITunesTopMoviesFeedEntry] {
        guard let feedURL = URL(string: feedURLString) else {
            throw URLError(.badURL)
        }
        let feedData = try await fetchData(from: feedURL)
        return Array(parseITunesTopMovieFeedEntries(from: feedData).prefix(10))
    }

    private nonisolated func mapITunesTopFeedEntries<Entry>(
        from feedURLString: String,
        transform: (ITunesTopMoviesFeedEntry) -> Entry,
    ) async throws -> [Entry] {
        try await fetchITunesTopFeedEntries(from: feedURLString).map(transform)
    }

    nonisolated func fetchITunesTopMovies() async throws -> [ITunesTopMovieEntry] {
        try await mapITunesTopFeedEntries(from: iTunesTopMoviesFeedURLString) { entry in
            let normalizedSummary = normalizedITunesTopMovieSummary(entry.summary)
                ?? "No description available."
            return ITunesTopMovieEntry(
                id: "itunes_top_movie_\(entry.lookupID)",
                rank: entry.rank,
                title: entry.title,
                summary: normalizedSummary,
                lookupID: entry.lookupID,
                artworkURL: entry.artworkURL,
                storeURL: entry.storeURL,
                previewVideoURL: entry.previewVideoURL,
            )
        }
    }

    nonisolated func fetchITunesTopTVEpisodes() async throws -> [ITunesTopTVEpisodeEntry] {
        try await mapITunesTopFeedEntries(from: iTunesTopTVEpisodesFeedURLString) { entry in
            let normalizedSummary = normalizedITunesTopMovieSummary(entry.summary)
                ?? "No description available."
            return ITunesTopTVEpisodeEntry(
                id: "itunes_top_tv_episode_\(entry.lookupID)",
                rank: entry.rank,
                title: entry.title,
                summary: normalizedSummary,
                lookupID: entry.lookupID,
                artworkURL: entry.artworkURL,
                storeURL: entry.storeURL,
                previewVideoURL: entry.previewVideoURL,
            )
        }
    }

    nonisolated func normalizedITunesTopMovieSummary(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let withoutTags = raw.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression,
        )
        let normalizedWhitespace = withoutTags.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression,
        )
        let trimmed = normalizedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func fetchITunesTopSongs() async throws -> [ITunesTopSongEntry] {
        try await mapITunesTopFeedEntries(from: iTunesTopSongsFeedURLString) { entry in
            ITunesTopSongEntry(
                id: "itunes_top_song_\(entry.lookupID)",
                rank: entry.rank,
                title: entry.title,
                lookupID: entry.lookupID,
                artworkURL: entry.artworkURL,
                storeURL: entry.storeURL,
                previewAudioURL: entry.previewVideoURL,
            )
        }
    }

    nonisolated func fetchITunesTopMusicVideos() async throws -> [ITunesTopMusicVideoEntry] {
        try await mapITunesTopFeedEntries(from: iTunesTopMusicVideosFeedURLString) { entry in
            let normalizedSummary = normalizedITunesTopMovieSummary(entry.summary)
                ?? "No description available."
            return ITunesTopMusicVideoEntry(
                id: "itunes_top_music_video_\(entry.lookupID)",
                rank: entry.rank,
                title: entry.title,
                summary: normalizedSummary,
                lookupID: entry.lookupID,
                artworkURL: entry.artworkURL,
                storeURL: entry.storeURL,
                previewVideoURL: entry.previewVideoURL,
            )
        }
    }

    nonisolated func fetchRemoteArtworkImage(from url: URL, maxPixelSize: CGFloat = 900) async -> NSImage? {
        if let cached = cachedDecodedDisplayArtworkImage(
            sourceKey: url.absoluteString,
            maxPixelSize: maxPixelSize,
        ) {
            return cached
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 300).contains(httpResponse.statusCode)
            else {
                return nil
            }
            return cachedDecodedDisplayArtworkImage(
                from: data,
                sourceKey: url.absoluteString,
                maxPixelSize: maxPixelSize,
            )
        } catch {
            return nil
        }
    }

    nonisolated func fetchITunesTopMovieArtworkImage(
        from lowResolutionURL: URL,
        maxPixelSize: CGFloat = 900,
    ) async -> NSImage? {
        if let highResolutionURL = highResolutionITunesArtworkURL(from: lowResolutionURL),
           let upgradedImage = await fetchRemoteArtworkImage(
               from: highResolutionURL,
               maxPixelSize: maxPixelSize,
           )
        {
            return upgradedImage
        }
        return await fetchRemoteArtworkImage(from: lowResolutionURL, maxPixelSize: maxPixelSize)
    }

    func iTunesTopState(for kind: ITunesTopCarouselKind) -> ITunesTopKindState {
        iTunesTopStateByKind[kind] ?? ITunesTopKindState()
    }

    func updateITunesTopState(
        _ kind: ITunesTopCarouselKind,
        _ update: (inout ITunesTopKindState) -> Void,
    ) {
        var state = iTunesTopStateByKind[kind] ?? ITunesTopKindState()
        update(&state)
        iTunesTopStateByKind[kind] = state
    }

    func selectedITunesTopPreviewIndex(_ kind: ITunesTopCarouselKind, entryCount: Int) -> Int? {
        guard activeRootItemID == kind.rootItemID, isInSubmenu else { return nil }
        guard isInThirdMenu, thirdMenuMode == kind.thirdMenuMode else { return nil }
        guard entryCount > 0, entryCount > selectedThirdIndex else { return nil }
        return selectedThirdIndex
    }

    func resolveITunesTopMoviePreviewTarget() -> ITunesTopMovieEntry? {
        guard let index = selectedITunesTopPreviewIndex(.movies, entryCount: iTunesTopMovies.count) else { return nil }
        return iTunesTopMovies[index]
    }

    func resolveITunesTopTVEpisodePreviewTarget() -> ITunesTopTVEpisodeEntry? {
        guard let index = selectedITunesTopPreviewIndex(.tvEpisodes, entryCount: iTunesTopTVEpisodes.count) else {
            return nil
        }
        return iTunesTopTVEpisodes[index]
    }

    func resolveITunesTopMusicVideoPreviewTarget() -> ITunesTopMusicVideoEntry? {
        guard let index = selectedITunesTopPreviewIndex(.musicVideos, entryCount: iTunesTopMusicVideos.count) else {
            return nil
        }
        return iTunesTopMusicVideos[index]
    }

    enum ITunesTopLoadEntries {
        case movies([ITunesTopMovieEntry])
        case tvEpisodes([ITunesTopTVEpisodeEntry])
        case songs([ITunesTopSongEntry])
        case musicVideos([ITunesTopMusicVideoEntry])
        var count: Int {
            switch self {
            case let .movies(entries):
                entries.count
            case let .tvEpisodes(entries):
                entries.count
            case let .songs(entries):
                entries.count
            case let .musicVideos(entries):
                entries.count
            }
        }
    }

    func nextITunesTopPlaybackRequestID(_ kind: ITunesTopCarouselKind) -> Int {
        let nextID = currentITunesTopPlaybackRequestID(kind) &+ 1
        updateITunesTopState(kind) { $0.playbackRequestID = nextID }
        return nextID
    }

    func currentITunesTopPlaybackRequestID(_ kind: ITunesTopCarouselKind) -> Int {
        iTunesTopState(for: kind).playbackRequestID
    }

    func nextITunesTopRequestID(_ kind: ITunesTopCarouselKind) -> Int {
        let nextID = currentITunesTopRequestID(kind) &+ 1
        updateITunesTopState(kind) { $0.requestID = nextID }
        return nextID
    }

    func currentITunesTopRequestID(_ kind: ITunesTopCarouselKind) -> Int {
        iTunesTopState(for: kind).requestID
    }

    func setITunesTopLoading(_ isLoading: Bool, for kind: ITunesTopCarouselKind) {
        updateITunesTopState(kind) { $0.isLoading = isLoading }
    }

    func isLoadingITunesTop(_ kind: ITunesTopCarouselKind) -> Bool {
        iTunesTopState(for: kind).isLoading
    }

    func setITunesTopLoadError(_ error: String?, for kind: ITunesTopCarouselKind) {
        updateITunesTopState(kind) { $0.loadError = error }
    }

    func currentITunesTopLoadError(_ kind: ITunesTopCarouselKind) -> String? {
        iTunesTopState(for: kind).loadError
    }

    func currentITunesTopPreviewImage(_ kind: ITunesTopCarouselKind) -> NSImage? {
        iTunesTopState(for: kind).previewImage
    }

    func setITunesTopEntries(_ entries: ITunesTopLoadEntries, for kind: ITunesTopCarouselKind) {
        switch (kind, entries) {
        case let (.movies, .movies(resolvedEntries)):
            iTunesTopMovies = resolvedEntries
        case let (.tvEpisodes, .tvEpisodes(resolvedEntries)):
            iTunesTopTVEpisodes = resolvedEntries
        case let (.songs, .songs(resolvedEntries)):
            iTunesTopSongs = resolvedEntries
        case let (.musicVideos, .musicVideos(resolvedEntries)):
            iTunesTopMusicVideos = resolvedEntries
        default:
            clearITunesTopEntries(for: kind)
        }
    }

    func clearITunesTopEntries(for kind: ITunesTopCarouselKind) {
        switch kind {
        case .movies:
            iTunesTopMovies = []
        case .tvEpisodes:
            iTunesTopTVEpisodes = []
        case .songs:
            iTunesTopSongs = []
        case .musicVideos:
            iTunesTopMusicVideos = []
        }
    }

    nonisolated func fetchITunesTopEntries(for kind: ITunesTopCarouselKind) async throws -> ITunesTopLoadEntries {
        switch kind {
        case .movies:
            try await .movies(fetchITunesTopMovies())
        case .tvEpisodes:
            try await .tvEpisodes(fetchITunesTopTVEpisodes())
        case .songs:
            try await .songs(fetchITunesTopSongs())
        case .musicVideos:
            try await .musicVideos(fetchITunesTopMusicVideos())
        }
    }

    nonisolated func iTunesTopErrorMessage(for kind: ITunesTopCarouselKind, error: Error) -> String {
        iTunesTopErrorMessage(for: error, label: kind.errorLabel)
    }

    func shouldAcceptITunesTopLoadResult(_ kind: ITunesTopCarouselKind) -> Bool {
        guard activeRootItemID == kind.rootItemID, isInSubmenu else { return false }
        if isInThirdMenu {
            return thirdMenuMode == kind.thirdMenuMode
        }
        return shouldUseITunesTopCarouselSlot(kind)
    }

    func requestITunesTopLoad(_ kind: ITunesTopCarouselKind) {
        let requestID = nextITunesTopRequestID(kind)
        setITunesTopLoading(true, for: kind)
        setITunesTopLoadError(nil, for: kind)
        Task.detached(priority: .userInitiated) {
            do {
                let loadedEntries = try await self.fetchITunesTopEntries(for: kind)
                await MainActor.run {
                    guard self.currentITunesTopRequestID(kind) == requestID else { return }
                    guard self.shouldAcceptITunesTopLoadResult(kind) else { return }
                    self.setITunesTopEntries(loadedEntries, for: kind)
                    self.selectedThirdIndex = min(self.selectedThirdIndex, max(0, loadedEntries.count - 1))
                    self.setITunesTopLoadError(
                        loadedEntries.count == 0 ? kind.emptyLoadMessage : nil,
                        for: kind,
                    )
                    self.setITunesTopLoading(false, for: kind)
                    self.refreshDetailPreviewForCurrentContext()
                }
            } catch {
                await MainActor.run {
                    guard self.currentITunesTopRequestID(kind) == requestID else { return }
                    guard self.shouldAcceptITunesTopLoadResult(kind) else { return }
                    self.clearITunesTopEntries(for: kind)
                    self.selectedThirdIndex = 0
                    self.setITunesTopLoadError(self.iTunesTopErrorMessage(for: kind, error: error), for: kind)
                    self.setCurrentITunesTopCarouselArtworks([], for: kind)
                    self.setCurrentITunesTopCarouselIdentity("", for: kind)
                    _ = self.nextITunesTopCarouselRequestID(kind)
                    self.setITunesTopLoading(false, for: kind)
                    self.refreshDetailPreviewForCurrentContext()
                }
            }
        }
    }

    struct ITunesTopMenuResetSpec {
        let kind: ITunesTopCarouselKind
        let isLoading: Bool
        let invalidateLoadRequest: Bool
        let resetPlaybackRequestID: Bool
    }

    func advanceITunesTopPlaybackRequestID(for kind: ITunesTopCarouselKind) {
        _ = nextITunesTopPlaybackRequestID(kind)
    }

    func resetITunesTopCarouselAndPreviewState(
        for kinds: [ITunesTopCarouselKind],
        resetPlaybackRequestID: Bool = false,
    ) {
        for kind in kinds {
            setCurrentITunesTopCarouselArtworks([], for: kind)
            setCurrentITunesTopCarouselIdentity("", for: kind)
            _ = nextITunesTopCarouselRequestID(kind)
            setCurrentITunesTopPreviewTargetID(nil, for: kind)
            setCurrentITunesTopPreviewImage(nil, for: kind, animationDuration: 0)
            _ = nextITunesTopPreviewRequestID(kind)
            if resetPlaybackRequestID {
                advanceITunesTopPlaybackRequestID(for: kind)
            }
        }
    }

    func resetITunesTopMenuState(
        for kind: ITunesTopCarouselKind,
        isLoading: Bool,
        invalidateLoadRequest: Bool,
        resetPlaybackRequestID: Bool,
    ) {
        setITunesTopLoading(isLoading, for: kind)
        setITunesTopLoadError(nil, for: kind)
        clearITunesTopEntries(for: kind)
        resetITunesTopCarouselAndPreviewState(
            for: [kind],
            resetPlaybackRequestID: resetPlaybackRequestID,
        )
        if invalidateLoadRequest {
            _ = nextITunesTopRequestID(kind)
        }
    }

    func resetITunesTopMenuStates(_ specs: [ITunesTopMenuResetSpec]) {
        for spec in specs {
            resetITunesTopMenuState(
                for: spec.kind,
                isLoading: spec.isLoading,
                invalidateLoadRequest: spec.invalidateLoadRequest,
                resetPlaybackRequestID: spec.resetPlaybackRequestID,
            )
        }
    }

    func resetAllITunesTopMenusForNonITunesContext() {
        resetITunesTopMenuStates([.init(kind: .movies, isLoading: false, invalidateLoadRequest: true, resetPlaybackRequestID: false), .init(kind: .tvEpisodes, isLoading: false, invalidateLoadRequest: true, resetPlaybackRequestID: false), .init(kind: .songs, isLoading: false, invalidateLoadRequest: true, resetPlaybackRequestID: true), .init(kind: .musicVideos, isLoading: false, invalidateLoadRequest: true, resetPlaybackRequestID: true)])
    }

    func resetMusicITunesTopMenusForLibraryContext() {
        resetITunesTopMenuStates([.init(kind: .songs, isLoading: false, invalidateLoadRequest: true, resetPlaybackRequestID: true), .init(kind: .musicVideos, isLoading: false, invalidateLoadRequest: true, resetPlaybackRequestID: true)])
    }

    func enterITunesTopMenu(_ kind: ITunesTopCarouselKind, title: String) {
        transitionMenuForFolderSwap(
            revealWhen: { !shouldHideThirdMenuListUntilLoadCompletes },
        ) {
            thirdMenuMode = kind.thirdMenuMode
            isInThirdMenu = true
            selectedThirdIndex = 0
            headerText = title
            resetThirdMenuDirectoryState()
            switch kind {
            case .movies:
                resetITunesTopMenuState(
                    for: .movies,
                    isLoading: true,
                    invalidateLoadRequest: false,
                    resetPlaybackRequestID: false,
                )
                resetMusicCategoryStateForNonMusicITunesTop()
                activeMusicLibraryMediaType = .songs
                musicSongsShowsShuffleAction = false
            case .tvEpisodes:
                resetITunesTopMenuState(
                    for: .tvEpisodes,
                    isLoading: true,
                    invalidateLoadRequest: false,
                    resetPlaybackRequestID: false,
                )
                resetMusicCategoryStateForNonMusicITunesTop()
            case .songs:
                resetMusicCategoryAndSongStateForMusicITunesTop()
                resetITunesTopMenuState(
                    for: .songs,
                    isLoading: true,
                    invalidateLoadRequest: false,
                    resetPlaybackRequestID: true,
                )
                resetITunesTopMenuState(
                    for: .musicVideos,
                    isLoading: false,
                    invalidateLoadRequest: true,
                    resetPlaybackRequestID: true,
                )
            case .musicVideos:
                resetMusicCategoryAndSongStateForMusicITunesTop()
                resetITunesTopMenuState(
                    for: .musicVideos,
                    isLoading: true,
                    invalidateLoadRequest: false,
                    resetPlaybackRequestID: true,
                )
                resetITunesTopMenuState(
                    for: .songs,
                    isLoading: false,
                    invalidateLoadRequest: true,
                    resetPlaybackRequestID: true,
                )
            }
            submenuOpacity = 0
            thirdMenuOpacity = 1
            requestITunesTopLoad(kind)
            refreshDetailPreviewForCurrentContext()
        }
    }

    func currentITunesTopPreviewTargetID(_ kind: ITunesTopCarouselKind) -> String? {
        iTunesTopState(for: kind).previewTargetID
    }

    func setCurrentITunesTopPreviewTargetID(_ targetID: String?, for kind: ITunesTopCarouselKind) {
        updateITunesTopState(kind) { $0.previewTargetID = targetID }
    }

    func currentITunesTopPreviewRequestID(_ kind: ITunesTopCarouselKind) -> Int {
        iTunesTopState(for: kind).previewRequestID
    }

    func nextITunesTopPreviewRequestID(_ kind: ITunesTopCarouselKind) -> Int {
        let nextID = currentITunesTopPreviewRequestID(kind) &+ 1
        updateITunesTopState(kind) { $0.previewRequestID = nextID }
        return nextID
    }

    func setCurrentITunesTopPreviewImage(_ image: NSImage?, for kind: ITunesTopCarouselKind, animationDuration: Double) {
        let assignImage = {
            updateITunesTopState(kind) { $0.previewImage = image }
        }
        guard kind != .musicVideos, animationDuration > 0 else {
            assignImage()
            return
        }
        withAnimation(.easeInOut(duration: animationDuration)) {
            assignImage()
        }
    }

    func iTunesTopPreviewSelection(for kind: ITunesTopCarouselKind) -> (id: String, artworkURL: URL?)? {
        switch kind {
        case .movies:
            guard let selectedMovie = resolveITunesTopMoviePreviewTarget() else { return nil }
            return (selectedMovie.id, selectedMovie.artworkURL)
        case .tvEpisodes:
            guard let selectedEpisode = resolveITunesTopTVEpisodePreviewTarget() else { return nil }
            return (selectedEpisode.id, selectedEpisode.artworkURL)
        case .songs:
            guard let index = selectedITunesTopPreviewIndex(.songs, entryCount: iTunesTopSongs.count) else { return nil }
            let selectedSong = iTunesTopSongs[index]
            return (selectedSong.id, selectedSong.artworkURL)
        case .musicVideos:
            guard let index = selectedITunesTopPreviewIndex(.musicVideos, entryCount: iTunesTopMusicVideos.count) else {
                return nil
            }
            let selectedVideo = iTunesTopMusicVideos[index]
            return (selectedVideo.id, selectedVideo.artworkURL)
        }
    }

    func refreshITunesTopPreviewForCurrentContext(_ kind: ITunesTopCarouselKind) {
        let selectedEntry = iTunesTopPreviewSelection(for: kind)
        let selectedEntryID = selectedEntry?.id
        if currentITunesTopPreviewTargetID(kind) == selectedEntryID {
            return
        }
        setCurrentITunesTopPreviewTargetID(selectedEntryID, for: kind)
        let requestID = nextITunesTopPreviewRequestID(kind)
        guard let selectedEntry else {
            setCurrentITunesTopPreviewImage(nil, for: kind, animationDuration: 0.18)
            return
        }
        if let cached = currentITunesTopCarouselArtworkCache(kind)[selectedEntry.id] {
            setCurrentITunesTopPreviewImage(cached, for: kind, animationDuration: 0.18)
            return
        }
        guard let artworkURL = selectedEntry.artworkURL else {
            setCurrentITunesTopPreviewImage(nil, for: kind, animationDuration: 0.18)
            return
        }
        let selectedEntryIDSnapshot = selectedEntry.id
        Task.detached(priority: .userInitiated) { [artworkURL] in
            let downloadedImage = await self.fetchITunesTopMovieArtworkImage(from: artworkURL)
            await MainActor.run {
                guard self.currentITunesTopPreviewRequestID(kind) == requestID else { return }
                guard self.currentITunesTopPreviewTargetID(kind) == selectedEntryIDSnapshot else { return }
                if let downloadedImage {
                    self.mergeITunesTopCarouselArtworkCache([selectedEntryIDSnapshot: downloadedImage], for: kind)
                    self.setCurrentITunesTopPreviewImage(downloadedImage, for: kind, animationDuration: 0.22)
                } else {
                    self.setCurrentITunesTopPreviewImage(nil, for: kind, animationDuration: 0.18)
                }
            }
        }
    }

    struct ITunesTopCarouselArtworkItem {
        let id: String
        let artworkURL: URL?
    }

    func refreshITunesTopCarouselForCurrentContext(_ kind: ITunesTopCarouselKind) {
        if shouldUseITunesTopCarouselSlot(kind) {
            let items = iTunesTopCarouselArtworkItems(kind)
            guard !items.isEmpty else {
                _ = nextITunesTopCarouselRequestID(kind)
                if !isLoadingITunesTopCarousel(kind) {
                    requestITunesTopCarouselLoad(kind)
                }
                return
            }
            let identity = iTunesTopCarouselIdentityKey(items)
            if currentITunesTopCarouselIdentity(kind) == identity,
               !currentITunesTopCarouselArtworks(kind).isEmpty
            {
                return
            }
            requestITunesTopCarouselArtworks(for: kind, items: items, identity: identity)
        } else {
            if isLoadingITunesTopCarousel(kind) || !currentITunesTopCarouselArtworks(kind).isEmpty || !currentITunesTopCarouselIdentity(kind).isEmpty {
                resetITunesTopCarouselAndPreviewState(for: [kind])
                setITunesTopLoading(false, for: kind)
            }
        }
    }

    func requestITunesTopCarouselArtworks(
        for kind: ITunesTopCarouselKind,
        items: [ITunesTopCarouselArtworkItem],
        identity: String,
    ) {
        setCurrentITunesTopCarouselIdentity(identity, for: kind)
        let cachedArtworkSnapshot = currentITunesTopCarouselArtworkCache(kind)
        let cachedArtworks = items.map { cachedArtworkSnapshot[$0.id] }
        if cachedArtworks.allSatisfy({ $0 != nil }) {
            setCurrentITunesTopCarouselArtworks(cachedArtworks, for: kind)
            return
        }
        let requestID = nextITunesTopCarouselRequestID(kind)
        let itemsSnapshot = items
        Task.detached(priority: .userInitiated) {
            let loadResult = await self.resolveITunesTopCarouselArtworks(
                items: itemsSnapshot,
                cachedArtworkSnapshot: cachedArtworkSnapshot,
            )
            await MainActor.run {
                guard self.currentITunesTopCarouselRequestID(kind) == requestID else { return }
                guard self.currentITunesTopCarouselIdentity(kind) == identity else { return }
                guard self.isITunesTopCarouselContextActive(kind) else { return }
                self.mergeITunesTopCarouselArtworkCache(loadResult.downloadedArtworksByID, for: kind)
                if self.shouldUseITunesTopCarouselSlot(kind) {
                    self.setCurrentITunesTopCarouselArtworks(loadResult.resolvedArtworks, for: kind)
                }
            }
        }
    }

    nonisolated func resolveITunesTopCarouselArtworks(
        items: [ITunesTopCarouselArtworkItem],
        cachedArtworkSnapshot: [String: NSImage],
    ) async -> (resolvedArtworks: [NSImage?], downloadedArtworksByID: [String: NSImage]) {
        var resolvedArtworks = [NSImage?](repeating: nil, count: items.count)
        var downloadedArtworksByID: [String: NSImage] = [:]
        var pendingDownloads: [(index: Int, itemID: String, artworkURL: URL)] = []
        pendingDownloads.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if let cached = cachedArtworkSnapshot[item.id] {
                resolvedArtworks[index] = cached
                continue
            }
            guard let artworkURL = item.artworkURL else { continue }
            pendingDownloads.append((index: index, itemID: item.id, artworkURL: artworkURL))
        }
        guard !pendingDownloads.isEmpty else {
            return (resolvedArtworks, downloadedArtworksByID)
        }
        let maxConcurrentDownloads = min(
            max(1, iTunesTopArtworkParallelismLimit),
            pendingDownloads.count,
        )
        await withTaskGroup(of: _SendableITunesTopArtworkResult.self) { group in
            var nextPendingIndex = 0
            func scheduleNextDownloadIfAvailable() {
                guard pendingDownloads.indices.contains(nextPendingIndex) else { return }
                let pending = pendingDownloads[nextPendingIndex]
                nextPendingIndex += 1
                group.addTask {
                    let downloadedImage = await self.fetchITunesTopMovieArtworkImage(from: pending.artworkURL)
                    return _SendableITunesTopArtworkResult(
                        index: pending.index,
                        itemID: pending.itemID,
                        image: downloadedImage,
                    )
                }
            }
            for _ in 0 ..< maxConcurrentDownloads {
                scheduleNextDownloadIfAvailable()
            }
            while let result = await group.next() {
                guard let downloadedImage = result.image else { continue }
                resolvedArtworks[result.index] = downloadedImage
                downloadedArtworksByID[result.itemID] = downloadedImage
                scheduleNextDownloadIfAvailable()
            }
        }
        return (resolvedArtworks, downloadedArtworksByID)
    }

    func iTunesTopCarouselArtworkItems(_ kind: ITunesTopCarouselKind) -> [ITunesTopCarouselArtworkItem] {
        switch kind {
        case .movies:
            iTunesTopMovies.map { .init(id: $0.id, artworkURL: $0.artworkURL) }
        case .tvEpisodes:
            iTunesTopTVEpisodes.map { .init(id: $0.id, artworkURL: $0.artworkURL) }
        case .songs:
            iTunesTopSongs.map { .init(id: $0.id, artworkURL: $0.artworkURL) }
        case .musicVideos:
            iTunesTopMusicVideos.map { .init(id: $0.id, artworkURL: $0.artworkURL) }
        }
    }

    func shouldUseITunesTopCarouselSlot(_ kind: ITunesTopCarouselKind) -> Bool {
        switch kind {
        case .movies:
            shouldUseITunesTopMoviesCarouselSlot
        case .tvEpisodes:
            shouldUseITunesTopTVEpisodesCarouselSlot
        case .songs:
            shouldUseITunesTopSongsCarouselSlot
        case .musicVideos:
            shouldUseITunesTopMusicVideosCarouselSlot
        }
    }

    func isLoadingITunesTopCarousel(_ kind: ITunesTopCarouselKind) -> Bool {
        iTunesTopState(for: kind).isLoading
    }

    func requestITunesTopCarouselLoad(_ kind: ITunesTopCarouselKind) {
        requestITunesTopLoad(kind)
    }

    func currentITunesTopCarouselIdentity(_ kind: ITunesTopCarouselKind) -> String {
        iTunesTopState(for: kind).carouselIdentity
    }

    func setCurrentITunesTopCarouselIdentity(_ identity: String, for kind: ITunesTopCarouselKind) {
        updateITunesTopState(kind) { $0.carouselIdentity = identity }
    }

    func currentITunesTopCarouselArtworks(_ kind: ITunesTopCarouselKind) -> [NSImage?] {
        iTunesTopState(for: kind).carouselArtworks
    }

    func setCurrentITunesTopCarouselArtworks(_ artworks: [NSImage?], for kind: ITunesTopCarouselKind) {
        updateITunesTopState(kind) { $0.carouselArtworks = artworks }
    }

    func currentITunesTopCarouselArtworkCache(_ kind: ITunesTopCarouselKind) -> [String: NSImage] {
        iTunesTopState(for: kind).artworkCache
    }

    func mergeITunesTopCarouselArtworkCache(
        _ downloadedArtworksByID: [String: NSImage],
        for kind: ITunesTopCarouselKind,
    ) {
        updateITunesTopState(kind) {
            $0.artworkCache.merge(downloadedArtworksByID, uniquingKeysWith: { _, new in new })
        }
    }

    func nextITunesTopCarouselRequestID(_ kind: ITunesTopCarouselKind) -> Int {
        let nextID = currentITunesTopCarouselRequestID(kind) &+ 1
        updateITunesTopState(kind) { $0.carouselRequestID = nextID }
        return nextID
    }

    func currentITunesTopCarouselRequestID(_ kind: ITunesTopCarouselKind) -> Int {
        iTunesTopState(for: kind).carouselRequestID
    }

    func iTunesTopCarouselIdentityKey(_ items: [ITunesTopCarouselArtworkItem]) -> String {
        items.map(\.id).joined(separator: "|")
    }

    func isITunesTopCarouselContextActive(_ kind: ITunesTopCarouselKind) -> Bool {
        isInSubmenu && activeRootItemID == kind.rootItemID
    }
}

extension MenuView {
    struct ITunesTopMovieEntry: Identifiable {
        let id: String
        let rank: Int
        let title: String
        let summary: String
        let lookupID: String
        let artworkURL: URL?
        let storeURL: URL?
        let previewVideoURL: URL?
    }

    struct ITunesTopTVEpisodeEntry: Identifiable {
        let id: String
        let rank: Int
        let title: String
        let summary: String
        let lookupID: String
        let artworkURL: URL?
        let storeURL: URL?
        let previewVideoURL: URL?
    }

    struct ITunesTopSongEntry: Identifiable {
        let id: String
        let rank: Int
        let title: String
        let lookupID: String
        let artworkURL: URL?
        let storeURL: URL?
        let previewAudioURL: URL?
    }

    struct ITunesTopMusicVideoEntry: Identifiable {
        let id: String
        let rank: Int
        let title: String
        let summary: String
        let lookupID: String
        let artworkURL: URL?
        let storeURL: URL?
        let previewVideoURL: URL?
    }

    enum ITunesTopCarouselKind: CaseIterable, Hashable {
        case movies
        case tvEpisodes
        case songs
        case musicVideos
        var rootItemID: String {
            switch self {
            case .movies, .tvEpisodes, .musicVideos: "movies"
            case .songs: "music"
            }
        }

        var thirdMenuMode: ThirdMenuMode {
            switch self {
            case .movies: .moviesITunesTop
            case .tvEpisodes: .tvEpisodesITunesTop
            case .songs: .musicITunesTopSongs
            case .musicVideos: .musicITunesTopMusicVideos
            }
        }

        var emptyLoadMessage: String {
            switch self {
            case .movies: "No iTunes Top Movies Available"
            case .tvEpisodes: "No iTunes Top TV Episodes Available"
            case .songs: "No iTunes Top Songs Available"
            case .musicVideos: "No iTunes Top Music Videos Available"
            }
        }

        var errorLabel: String {
            switch self {
            case .movies: "iTunes Top Movies"
            case .tvEpisodes: "iTunes Top TV Episodes"
            case .songs: "iTunes Top Songs"
            case .musicVideos: "iTunes Top Music Videos"
            }
        }

        static var defaultStateMap: [Self: ITunesTopKindState] {
            Dictionary(uniqueKeysWithValues: allCases.map { ($0, ITunesTopKindState()) })
        }
    }

    struct ITunesTopKindState {
        var isLoading = false
        var loadError: String?
        var requestID = 0
        var artworkCache: [String: NSImage] = [:]
        var carouselArtworks: [NSImage?] = []
        var carouselIdentity = ""
        var carouselRequestID = 0
        var previewMediaURLCache: [String: URL] = [:]
        var previewTargetID: String?
        var previewImage: NSImage?
        var previewRequestID = 0
        var playbackRequestID = 0
    }

    enum TVShowsSortMode {
        case date
        case show
    }
}
