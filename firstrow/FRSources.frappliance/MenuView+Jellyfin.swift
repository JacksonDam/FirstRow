import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A song that streams from a Jellyfin server.
struct JellyfinTrackReference {
    let serverKey: String
    let itemID: String
    let imageURL: URL?
}

/// What a Jellyfin page lists.
enum JellyfinList: Equatable {
    case resume
    case nextUp
    case movies(libraryID: String, title: String)
    case shows(libraryID: String, title: String)
    case music(libraryID: String, title: String)
    case artists(libraryID: String)
    case albums(libraryID: String?, artistID: String?, title: String)
    case playlists
    case folder(id: String, title: String)
    case seasons(seriesID: String, title: String)
    case episodes(seriesID: String, seasonID: String, title: String)

    var title: String {
        switch self {
        case .resume: "Continue Watching"
        case .nextUp: "Next Up"
        case let .movies(_, title), let .shows(_, title), let .music(_, title), let .folder(_, title),
             let .seasons(_, title), let .episodes(_, _, title), let .albums(_, _, title):
            title
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }

    var emptyTitle: String {
        switch self {
        case .resume: "Nothing to Continue"
        case .nextUp: "No Episodes Up Next"
        case .movies: "No Movies"
        case .shows: "No Shows"
        case .music, .folder: "Nothing Here"
        case .artists: "No Artists"
        case .albums: "No Albums"
        case .playlists: "No Playlists"
        case .seasons: "No Seasons"
        case .episodes: "No Episodes"
        }
    }
}

enum JellyfinPage: Equatable {
    /// Servers found on the network, and typing an address.
    case addServer
    /// Quick Connect, or a user name and password.
    case signIn(JellyfinServerInfo)
    /// A signed-in server: Continue Watching, Next Up and its libraries.
    case home(serverKey: String)
    case list(serverKey: String, JellyfinList)
}

struct JellyfinPageState {
    var page: JellyfinPage
    var selectedIndex = 0
    /// The row to select again once the page has loaded, after coming back to it.
    var selectedRowID: String?
    var items: [JellyfinItem] = []
    var hasResume = false
    var hasNextUp = false
    var isLoaded = false
}

/// The Jellyfin pages' state, kept together so the menu holds one value for all of it.
struct JellyfinMenuState {
    var pages: [JellyfinPageState] = []
    var isLoading = false
    var error: String?
    var status: String?
    var discovered: [JellyfinServerInfo] = []
    var isDiscovering = false
    /// The pages to go back to from a song list opened from them.
    var songsReturnPages: [JellyfinPageState]?
    var previewItemID: String?
    var previewImage: NSImage?
    var requestID = 0
    var quickConnectRequestID = 0
}

/// Sources: the device itself, Jellyfin servers First Row is signed in to, and adding one.
extension MenuView {
    static let jellyfinAddServerItemID = "jellyfin_add_server"
    static let jellyfinServerItemPrefix = "jellyfin_server|"

    var currentJellyfinPage: JellyfinPageState? {
        jellyfin.pages.last
    }

    var isShowingJellyfinSongs: Bool {
        activeRootItemID == "sources" && thirdMenuMode == .musicSongs && jellyfin.songsReturnPages != nil
    }

    /// Where song lists and their previews work: Music, and the song lists of Jellyfin and
    /// the other servers under Sources.
    var isMusicLibraryContext: Bool {
        activeRootItemID == "music" || isShowingJellyfinSongs || isShowingServerSongs
    }

    // MARK: - The Sources menu

    func sourcesSubmenuItems() -> [SubmenuItemConfig] {
        var items = MenuConfiguration.submenuItems(forRootID: "sources")
        for (index, server) in JellyfinStore.shared.servers.enumerated() {
            items.append(SubmenuItemConfig(
                id: Self.jellyfinServerItemPrefix + server.key,
                title: server.serverName,
                leadsToMenu: true,
                showsTopDivider: index == 0,
            ))
        }
        // (The other kinds of server and the shared folders, after Jellyfin's and Emby's.)
        let others = serverSubmenuItems(startsGroup: JellyfinStore.shared.servers.isEmpty)
        items += others
        items.append(SubmenuItemConfig(
            id: Self.addServerItemID,
            title: "Add Server",
            trailingText: "...",
            showsTopDivider: JellyfinStore.shared.servers.isEmpty && others.isEmpty,
        ))
        return items
    }

    /// Opens Jellyfin's pages on a server found elsewhere, and goes on to signing in to it.
    func enterJellyfin(connectingTo info: JellyfinServerInfo) {
        enterJellyfin(pages: [JellyfinPageState(page: .addServer)])
        Task { @MainActor in
            // (Once the page is up.)
            for _ in 0 ..< 60 where self.isMenuFolderSwapTransitioning {
                try? await firstRowSleep(0.05)
            }
            guard self.thirdMenuMode == .jellyfin, self.currentJellyfinPage?.page == .addServer else { return }
            self.connectToJellyfinServer(typedOrFound: info.url, knownInfo: info)
        }
    }

    /// Handles the Jellyfin rows of Sources. Returns false for rows handled elsewhere.
    func triggerSourcesItem(_ item: SubmenuItemConfig) -> Bool {
        if triggerServerSourcesItem(item) { return true }
        if item.id == Self.jellyfinAddServerItemID {
            playSound(named: "Selection")
            enterJellyfin(pages: [JellyfinPageState(page: .addServer)])
            return true
        }
        if item.id.hasPrefix(Self.jellyfinServerItemPrefix) {
            let key = String(item.id.dropFirst(Self.jellyfinServerItemPrefix.count))
            guard JellyfinStore.shared.server(withKey: key) != nil else {
                playLimitSoundOnceForCurrentHold()
                return true
            }
            playSound(named: "Selection")
            enterJellyfin(pages: [JellyfinPageState(page: .home(serverKey: key))])
            return true
        }
        return false
    }

    // MARK: - Rows

    func jellyfinMenuListItems() -> [MenuListItemConfig] {
        guard let state = currentJellyfinPage else { return [] }
        var items: [MenuListItemConfig] = []
        if let status = jellyfin.status {
            items.append(menuMessageItem(id: "jellyfin_status", title: status))
        } else if let error = jellyfin.error {
            items.append(menuMessageItem(id: "jellyfin_error", title: error))
        }
        switch state.page {
        case .addServer:
            for (index, server) in jellyfin.discovered.enumerated() {
                items.append(plainMenuListItem(id: "jellyfin_found_\(index)", title: server.name, trailingText: "..."))
            }
            if jellyfin.isDiscovering, jellyfin.discovered.isEmpty, jellyfin.status == nil {
                items.append(menuMessageItem(id: "jellyfin_searching", title: "Looking for Servers..."))
            } else if !jellyfin.isDiscovering {
                items.append(plainMenuListItem(id: "jellyfin_search_again", title: jellyfin.discovered.isEmpty ? "No Servers Found: Look Again" : "Look Again", showsTopDivider: !jellyfin.discovered.isEmpty))
            }
            items.append(plainMenuListItem(id: "jellyfin_enter_address", title: "Enter Address", trailingText: "...", showsTopDivider: jellyfin.isDiscovering && !jellyfin.discovered.isEmpty))
        case let .signIn(info):
            if !info.isEmby {
                items.append(plainMenuListItem(id: "jellyfin_quick_connect", title: "Quick Connect", trailingText: "..."))
            }
            items.append(plainMenuListItem(id: "jellyfin_password", title: "User Name and Password", trailingText: "..."))
        case .home:
            guard state.isLoaded else { return items }
            if state.hasResume {
                items.append(plainMenuListItem(id: "jellyfin_resume", title: "Continue Watching", leadsToMenu: true))
            }
            if state.hasNextUp {
                items.append(plainMenuListItem(id: "jellyfin_next_up", title: "Next Up", leadsToMenu: true))
            }
            for (index, view) in state.items.enumerated() {
                items.append(plainMenuListItem(id: "jellyfin_view_\(index)", title: view.title, leadsToMenu: true, showsTopDivider: index == 0 && (state.hasResume || state.hasNextUp)))
            }
            items.append(plainMenuListItem(id: "jellyfin_sign_out", title: "Sign Out", showsTopDivider: true))
        case let .list(_, list):
            if case .music = list {
                return items + [
                    plainMenuListItem(id: "jellyfin_music_artists", title: "Artists", leadsToMenu: true),
                    plainMenuListItem(id: "jellyfin_music_albums", title: "Albums", leadsToMenu: true),
                    plainMenuListItem(id: "jellyfin_music_songs", title: "Songs", leadsToMenu: true),
                    plainMenuListItem(id: "jellyfin_music_playlists", title: "Playlists", leadsToMenu: true),
                ]
            }
            guard state.isLoaded else { return items }
            if state.items.isEmpty, jellyfin.error == nil {
                return [menuMessageItem(id: "jellyfin_empty", title: list.emptyTitle)]
            }
            for (index, item) in state.items.enumerated() {
                items.append(jellyfinRow(for: item, index: index, in: list))
            }
        }
        return items
    }

    private func jellyfinRow(for item: JellyfinItem, index: Int, in list: JellyfinList) -> MenuListItemConfig {
        let type = item.type ?? ""
        let leads = !item.isVideo && type != "Audio"
        var title = item.title
        var trailing: String?
        switch type {
        case "Episode":
            if list == .resume || list == .nextUp {
                title = item.seriesName ?? item.title
                trailing = item.episodeLabel
            } else if let number = item.indexNumber {
                title = "\(number). \(item.title)"
            }
        default:
            break
        }
        let unwatchedSeries = (type == "Series" || type == "Season") && (item.userData?.unplayedItemCount ?? 0) > 0
        return plainMenuListItem(
            id: "jellyfin_item_\(index)",
            title: title,
            leadsToMenu: leads,
            trailingText: trailing,
            showsBlueDot: item.isUnplayedVideo || unwatchedSeries,
        )
    }

    /// Index into the page's items for a row, allowing for a message row above them.
    private func jellyfinItemIndex(forRowID id: String) -> Int? {
        guard id.hasPrefix("jellyfin_item_") else { return nil }
        return Int(id.dropFirst("jellyfin_item_".count))
    }

    var shouldHideJellyfinMenuUntilLoaded: Bool {
        guard let state = currentJellyfinPage else { return false }
        switch state.page {
        case .addServer, .signIn:
            return false
        case let .list(_, list):
            if case .music = list { return false }
            return !state.isLoaded && jellyfin.error == nil
        case .home:
            return !state.isLoaded && jellyfin.error == nil
        }
    }

    func jellyfinTitle(for page: JellyfinPage) -> String {
        switch page {
        case .addServer:
            return "Add Server"
        case let .signIn(info):
            return truncatedHeaderTitle(info.name, fallback: "Sign In")
        case let .home(key):
            return truncatedHeaderTitle(JellyfinStore.shared.server(withKey: key)?.serverName ?? "Jellyfin", fallback: "Jellyfin")
        case let .list(_, list):
            return truncatedHeaderTitle(list.title, fallback: "Jellyfin")
        }
    }

    private func jellyfinClient(forKey key: String) -> JellyfinClient? {
        JellyfinStore.shared.server(withKey: key).flatMap { JellyfinClient(record: $0) }
    }

    private var currentJellyfinServerKey: String? {
        for state in jellyfin.pages.reversed() {
            switch state.page {
            case let .home(key), let .list(key, _): return key
            default: continue
            }
        }
        return nil
    }

    /// Shows a message above the rows (or clears it) while keeping the same row selected.
    private func showJellyfinMessage(error: String? = nil, status: String? = nil) {
        let rows = jellyfinMenuListItems()
        let selectedID = rows.indices.contains(selectedThirdIndex) ? rows[selectedThirdIndex].id : nil
        jellyfin.error = error
        jellyfin.status = status
        if let selectedID, let index = jellyfinMenuListItems().firstIndex(where: { $0.id == selectedID }) {
            selectedThirdIndex = index
        }
    }

    // MARK: - Moving between pages

    func enterJellyfin(pages: [JellyfinPageState]) {
        jellyfin.requestID &+= 1
        transitionMenuForFolderSwap(useOverlayFade: true, revealWhen: { !self.shouldHideJellyfinMenuUntilLoaded }) {
            self.thirdMenuMode = .jellyfin
            self.isInThirdMenu = true
            self.jellyfin.pages = pages
            self.jellyfin.error = nil
            self.jellyfin.status = nil
            self.jellyfin.songsReturnPages = nil
            self.selectedThirdIndex = 0
            self.headerText = self.jellyfinTitle(for: pages.last?.page ?? .addServer)
            self.clearJellyfinPreview()
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
            self.loadCurrentJellyfinPage()
        }
    }

    func pushJellyfinPage(_ page: JellyfinPage) {
        transitionMenuForFolderSwap(revealWhen: { !self.shouldHideJellyfinMenuUntilLoaded }) {
            self.rememberJellyfinSelection()
            self.jellyfin.pages.append(JellyfinPageState(page: page))
            self.jellyfin.error = nil
            self.jellyfin.status = nil
            self.selectedThirdIndex = 0
            self.headerText = self.jellyfinTitle(for: page)
            self.clearJellyfinPreview()
            self.loadCurrentJellyfinPage()
        }
    }

    /// Replaces every page with a server's home page, after signing in to it.
    private func showJellyfinHome(_ key: String) {
        transitionMenuForFolderSwap(useOverlayFade: true, revealWhen: { !self.shouldHideJellyfinMenuUntilLoaded }) {
            self.jellyfin.pages = [JellyfinPageState(page: .home(serverKey: key))]
            self.jellyfin.error = nil
            self.jellyfin.status = nil
            self.selectedThirdIndex = 0
            self.headerText = self.jellyfinTitle(for: .home(serverKey: key))
            self.clearJellyfinPreview()
            self.loadCurrentJellyfinPage()
        }
    }

    func navigateUpInJellyfinMenu() {
        jellyfin.requestID &+= 1
        jellyfin.quickConnectRequestID &+= 1
        guard jellyfin.pages.count > 1 else {
            exitJellyfinToSources()
            return
        }
        transitionMenuForFolderSwap(revealWhen: { !self.shouldHideJellyfinMenuUntilLoaded }) {
            self.jellyfin.pages.removeLast()
            self.jellyfin.error = nil
            self.jellyfin.status = nil
            self.jellyfin.isLoading = false
            self.showReturnedJellyfinPage()
        }
    }

    /// Saves which row is selected on the current page, before another page goes over it.
    private func rememberJellyfinSelection() {
        let rows = jellyfinMenuListItems()
        guard var current = jellyfin.pages.popLast() else { return }
        current.selectedIndex = selectedThirdIndex
        current.selectedRowID = rows.indices.contains(selectedThirdIndex) ? rows[selectedThirdIndex].id : nil
        jellyfin.pages.append(current)
    }

    /// Shows the page that's on top again, loading it first if playback made it stale.
    private func showReturnedJellyfinPage() {
        guard let page = currentJellyfinPage else { return }
        headerText = jellyfinTitle(for: page.page)
        clearJellyfinPreview()
        if page.isLoaded {
            selectJellyfinRememberedRow()
            refreshDetailPreviewForCurrentContext()
        } else {
            selectedThirdIndex = 0
            loadCurrentJellyfinPage()
        }
    }

    private func selectJellyfinRememberedRow() {
        guard let index = jellyfin.pages.indices.last else { return }
        let page = jellyfin.pages[index]
        let rows = jellyfinMenuListItems()
        if let id = page.selectedRowID, let row = rows.firstIndex(where: { $0.id == id }) {
            selectedThirdIndex = row
        } else {
            selectedThirdIndex = min(page.selectedIndex, max(0, rows.count - 1))
        }
        jellyfin.pages[index].selectedRowID = nil
    }

    private func exitJellyfinToSources() {
        transitionMenuForFolderSwap(useOverlayFade: true) {
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.jellyfin.pages = []
            self.jellyfin.error = nil
            self.jellyfin.status = nil
            self.jellyfin.isLoading = false
            self.jellyfin.isDiscovering = false
            self.clearJellyfinPreview()
            let items = self.currentSubmenuItems()
            self.selectedSubIndex = min(self.selectedSubIndex, max(0, items.count - 1))
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
        }
    }

    /// Back from a song list opened from a Jellyfin page, to that page.
    func returnFromJellyfinSongs() {
        guard let pages = jellyfin.songsReturnPages else { return }
        jellyfin.requestID &+= 1
        transitionMenuForFolderSwap(revealWhen: { !self.shouldHideJellyfinMenuUntilLoaded }) {
            self.jellyfin.songsReturnPages = nil
            self.thirdMenuMode = .jellyfin
            self.jellyfin.pages = pages
            self.jellyfin.error = nil
            self.isLoadingMusicSongs = false
            self.musicSongsLoadError = nil
            self.musicSongsShowsShuffleAction = false
            self.resetMusicPreviewState()
            self.showReturnedJellyfinPage()
        }
    }

    // MARK: - Loading

    private func loadCurrentJellyfinPage(quietly: Bool = false) {
        guard let state = currentJellyfinPage else { return }
        let requestID = jellyfin.requestID &+ 1
        jellyfin.requestID = requestID
        let pageIndex = jellyfin.pages.count - 1
        func finish(_ update: (inout JellyfinPageState) -> Void) {
            guard jellyfin.requestID == requestID, jellyfin.pages.indices.contains(pageIndex) else { return }
            let rows = jellyfinMenuListItems()
            let selectedID = quietly && rows.indices.contains(selectedThirdIndex) ? rows[selectedThirdIndex].id : nil
            update(&jellyfin.pages[pageIndex])
            jellyfin.pages[pageIndex].isLoaded = true
            jellyfin.isLoading = false
            if let selectedID, let index = jellyfinMenuListItems().firstIndex(where: { $0.id == selectedID }) {
                selectedThirdIndex = index
            } else if jellyfin.pages[pageIndex].selectedRowID != nil {
                selectJellyfinRememberedRow()
            }
            let count = jellyfinMenuListItems().count
            if selectedThirdIndex >= count { selectedThirdIndex = max(0, count - 1) }
            refreshDetailPreviewForCurrentContext()
        }
        switch state.page {
        case .addServer:
            startJellyfinDiscovery()
        case .signIn:
            break
        case let .home(key):
            guard let client = jellyfinClient(forKey: key) else { return }
            jellyfin.isLoading = !quietly
            Task { @MainActor in
                do {
                    async let views = client.views()
                    async let resume = client.resumeItems(limit: 1)
                    async let nextUp = client.nextUp(limit: 1)
                    let loadedViews = try await views
                    let hasResume = await (try? resume)?.isEmpty == false
                    let hasNextUp = await (try? nextUp)?.isEmpty == false
                    finish { state in
                        state.items = loadedViews
                        state.hasResume = hasResume
                        state.hasNextUp = hasNextUp
                    }
                } catch {
                    guard self.jellyfin.requestID == requestID else { return }
                    self.jellyfin.error = error.localizedDescription
                    finish { _ in }
                }
            }
        case let .list(key, list):
            if case .music = list { return }
            guard let client = jellyfinClient(forKey: key) else { return }
            jellyfin.isLoading = !quietly
            Task { @MainActor in
                do {
                    let items = try await self.loadJellyfinItems(list, client: client)
                    finish { $0.items = items }
                } catch {
                    guard self.jellyfin.requestID == requestID else { return }
                    self.jellyfin.error = error.localizedDescription
                    finish { _ in }
                }
            }
        }
    }

    private func loadJellyfinItems(_ list: JellyfinList, client: JellyfinClient) async throws -> [JellyfinItem] {
        switch list {
        case .resume:
            return try await client.resumeItems()
        case .nextUp:
            return try await client.nextUp()
        case let .movies(libraryID, _):
            return try await client.children(of: libraryID, types: "Movie", recursive: true)
        case let .shows(libraryID, _):
            return try await client.children(of: libraryID, types: "Series", recursive: true)
        case .music:
            return []
        case let .artists(libraryID):
            return try await client.albumArtists(libraryID: libraryID)
        case let .albums(libraryID, artistID, _):
            var extra: [(String, String)] = []
            if let artistID { extra.append(("albumArtistIds", artistID)) }
            return try await client.children(of: artistID == nil ? libraryID : nil, types: "MusicAlbum", recursive: true, sortBy: artistID == nil ? "SortName" : "ProductionYear,SortName", extra: extra)
        case .playlists:
            return try await client.children(of: nil, types: "Playlist", recursive: true, extra: [("mediaTypes", "Audio")])
        case let .folder(id, _):
            return try await client.children(of: id)
        case let .seasons(seriesID, _):
            return try await client.seasons(seriesID: seriesID)
        case let .episodes(seriesID, seasonID, _):
            return try await client.episodes(seriesID: seriesID, seasonID: seasonID)
        }
    }

    /// Reloads the page after playing something, so its dots and Continue Watching catch up.
    func refreshJellyfinPageAfterPlayback() {
        if thirdMenuMode == .jellyfin {
            loadCurrentJellyfinPage(quietly: true)
        }
        // Pages further back are stale too: forget them so they load again.
        for index in jellyfin.pages.indices.dropLast() where jellyfin.pages[index].isLoaded {
            if case .list = jellyfin.pages[index].page { jellyfin.pages[index].isLoaded = false }
            if case .home = jellyfin.pages[index].page { jellyfin.pages[index].isLoaded = false }
        }
    }

    private func startJellyfinDiscovery() {
        jellyfin.isDiscovering = true
        jellyfin.discovered = []
        let requestID = jellyfin.requestID
        Task { @MainActor in
            let found = await JellyfinDiscovery.discover()
            guard self.jellyfin.requestID == requestID, self.currentJellyfinPage?.page == .addServer else { return }
            let rows = self.jellyfinMenuListItems()
            let selectedID = rows.indices.contains(self.selectedThirdIndex) ? rows[self.selectedThirdIndex].id : nil
            self.jellyfin.discovered = found
            self.jellyfin.isDiscovering = false
            // Stay on the row that was selected, unless it was the "looking" row that just went away.
            if let selectedID, let index = self.jellyfinMenuListItems().firstIndex(where: { $0.id == selectedID }) {
                self.selectedThirdIndex = index
            }
        }
    }

    // MARK: - Actions

    func triggerJellyfinMenuAction() {
        let rows = jellyfinMenuListItems()
        guard rows.indices.contains(selectedThirdIndex), let state = currentJellyfinPage else { return }
        let id = rows[selectedThirdIndex].id
        switch state.page {
        case .addServer:
            if id == "jellyfin_enter_address" {
                askForJellyfinAddress()
            } else if id == "jellyfin_search_again" {
                showJellyfinMessage()
                startJellyfinDiscovery()
            } else if id.hasPrefix("jellyfin_found_"), let index = Int(id.dropFirst("jellyfin_found_".count)), jellyfin.discovered.indices.contains(index) {
                connectToJellyfinServer(typedOrFound: jellyfin.discovered[index].url, knownInfo: jellyfin.discovered[index])
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        case let .signIn(info):
            if id == "jellyfin_quick_connect" {
                startJellyfinQuickConnect(info)
            } else if id == "jellyfin_password" {
                askForJellyfinCredentials(info)
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        case let .home(key):
            if id == "jellyfin_resume" {
                pushJellyfinPage(.list(serverKey: key, .resume))
            } else if id == "jellyfin_next_up" {
                pushJellyfinPage(.list(serverKey: key, .nextUp))
            } else if id == "jellyfin_sign_out" {
                signOutOfJellyfin(key)
            } else if id.hasPrefix("jellyfin_view_"), let index = Int(id.dropFirst("jellyfin_view_".count)), state.items.indices.contains(index) {
                openJellyfinView(state.items[index], serverKey: key)
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        case let .list(key, list):
            if case let .music(libraryID, _) = list {
                switch id {
                case "jellyfin_music_artists": pushJellyfinPage(.list(serverKey: key, .artists(libraryID: libraryID)))
                case "jellyfin_music_albums": pushJellyfinPage(.list(serverKey: key, .albums(libraryID: libraryID, artistID: nil, title: "Albums")))
                case "jellyfin_music_playlists": pushJellyfinPage(.list(serverKey: key, .playlists))
                case "jellyfin_music_songs":
                    openJellyfinSongs(title: "Songs", serverKey: key) { client in
                        try await client.children(of: libraryID, types: "Audio", recursive: true, sortBy: "AlbumArtist,Album,ParentIndexNumber,IndexNumber,SortName")
                    }
                default: playLimitSoundOnceForCurrentHold()
                }
                return
            }
            guard let index = jellyfinItemIndex(forRowID: id), state.items.indices.contains(index) else {
                if id == "jellyfin_error" { loadCurrentJellyfinPage() } else { playLimitSoundOnceForCurrentHold() }
                return
            }
            openJellyfinItem(state.items[index], at: index, in: state.items, serverKey: key)
        }
    }

    private func openJellyfinView(_ view: JellyfinItem, serverKey key: String) {
        switch view.collectionType ?? "" {
        case "movies":
            pushJellyfinPage(.list(serverKey: key, .movies(libraryID: view.id, title: view.title)))
        case "tvshows":
            pushJellyfinPage(.list(serverKey: key, .shows(libraryID: view.id, title: view.title)))
        case "music":
            pushJellyfinPage(.list(serverKey: key, .music(libraryID: view.id, title: view.title)))
        default:
            pushJellyfinPage(.list(serverKey: key, .folder(id: view.id, title: view.title)))
        }
    }

    private func openJellyfinItem(_ item: JellyfinItem, at index: Int, in items: [JellyfinItem], serverKey key: String) {
        if item.isVideo {
            playJellyfinVideo(item, serverKey: key)
            return
        }
        switch item.type ?? "" {
        case "Series":
            pushJellyfinPage(.list(serverKey: key, .seasons(seriesID: item.id, title: item.title)))
        case "Season":
            pushJellyfinPage(.list(serverKey: key, .episodes(seriesID: item.seriesID ?? "", seasonID: item.id, title: item.title)))
        case "MusicArtist":
            pushJellyfinPage(.list(serverKey: key, .albums(libraryID: nil, artistID: item.id, title: item.title)))
        case "MusicAlbum":
            openJellyfinSongs(title: item.title, serverKey: key) { client in
                try await client.children(of: item.id, types: "Audio", sortBy: "ParentIndexNumber,IndexNumber,SortName")
            }
        case "Playlist":
            openJellyfinSongs(title: item.title, serverKey: key) { client in
                try await client.playlistItems(item.id).filter { $0.type == "Audio" }
            }
        case "Audio":
            // A song inside a folder: play it with the songs around it.
            let songs = items.filter { $0.type == "Audio" }
            guard let client = jellyfinClient(forKey: key), let position = songs.firstIndex(where: { $0.id == item.id }) else { return }
            let entries = jellyfinSongEntries(songs, client: client, serverKey: key)
            startPlaybackForMusicLibraryEntry(entries[position], trackIndex: position, trackCount: entries.count, playbackQueue: entries)
        default:
            if item.isFolder == true {
                pushJellyfinPage(.list(serverKey: key, .folder(id: item.id, title: item.title)))
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        }
    }

    // MARK: - Songs

    /// Opens Jellyfin songs in the Music songs list, with its previews and Now Playing.
    private func openJellyfinSongs(title: String, serverKey key: String, load: @escaping @MainActor (JellyfinClient) async throws -> [JellyfinItem]) {
        guard let client = jellyfinClient(forKey: key) else { return }
        jellyfin.requestID &+= 1
        let requestID = jellyfin.requestID
        rememberJellyfinSelection()
        let returnPages = jellyfin.pages
        transitionMenuForFolderSwap(revealWhen: { !self.isLoadingMusicSongs }) {
            self.prepareMusicLibraryThirdMenu(
                mode: .musicSongs,
                title: self.truncatedHeaderTitle(title, fallback: "Songs"),
                categoryKind: nil,
                categoryTitle: "",
                shuffleMode: false,
                libraryMediaType: .songs,
                showsShuffleAction: true,
            )
            self.jellyfin.songsReturnPages = returnPages
            self.clearJellyfinPreview()
            Task { @MainActor in
                do {
                    let items = try await load(client)
                    guard self.jellyfin.requestID == requestID, self.thirdMenuMode == .musicSongs else { return }
                    let songs = self.jellyfinSongEntries(items, client: client, serverKey: key)
                    self.musicSongsThirdMenuItems = songs
                    self.musicSongsLoadError = songs.isEmpty ? "No Songs" : nil
                } catch {
                    guard self.jellyfin.requestID == requestID, self.thirdMenuMode == .musicSongs else { return }
                    self.musicSongsLoadError = error.localizedDescription
                }
                self.isLoadingMusicSongs = false
                self.refreshDetailPreviewForCurrentContext()
            }
        }
    }

    func jellyfinSongEntries(_ items: [JellyfinItem], client: JellyfinClient, serverKey key: String) -> [MusicLibrarySongEntry] {
        items.enumerated().map { index, item in
            let imageURL = client.primaryImageURL(for: item, maxHeight: 900)
            return MusicLibrarySongEntry(
                id: "jellyfin|\(key)|\(item.id)|\(index)",
                title: item.title,
                artist: item.albumArtist ?? item.artists?.first ?? "",
                album: item.album ?? "",
                genre: item.genres?.first ?? "",
                composer: "",
                durationSeconds: item.durationSeconds,
                trackNumber: item.indexNumber ?? 0,
                discNumber: item.parentIndexNumber ?? 0,
                artworkAlbumKey: imageURL.map { "jellyfin-art::\($0.absoluteString)" },
                url: client.audioURL(for: item),
                artwork: nil,
                jellyfin: JellyfinTrackReference(serverKey: key, itemID: item.id, imageURL: imageURL),
            )
        }
    }

    func loadJellyfinArtwork(for song: MusicLibrarySongEntry, cacheKey: String) async -> NSImage? {
        guard let url = song.jellyfin?.imageURL else { return nil }
        return await loadJellyfinImage(url, cacheKey: cacheKey)
    }

    func loadJellyfinImage(_ url: URL, cacheKey: String? = nil) async -> NSImage? {
        let key = cacheKey ?? "jellyfin-art::\(url.absoluteString)"
        if let cached = cachedDecodedDisplayArtworkImage(sourceKey: key, maxPixelSize: 900) {
            return cached
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode), !data.isEmpty
        else { return nil }
        return cachedDecodedDisplayArtworkImage(from: data, sourceKey: key, maxPixelSize: 900)
    }

    // MARK: - Adding a server and signing in

    private func askForJellyfinAddress() {
        requestTextEntry(
            title: "Server Address",
            prompt: "Type the Jellyfin or Emby server's address, like 192.168.1.20 or media.example.com.",
        ) { [weak self] text in
            guard let self, let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.connectToJellyfinServer(typedOrFound: text, knownInfo: nil)
        }
    }

    /// Checks the server answers, then moves on to signing in to it.
    private func connectToJellyfinServer(typedOrFound address: String, knownInfo: JellyfinServerInfo?) {
        let candidates = JellyfinClient.candidateURLs(for: address)
        guard !candidates.isEmpty else { return }
        showJellyfinMessage(status: "Connecting...")
        let requestID = jellyfin.requestID
        Task { @MainActor in
            var found: JellyfinServerInfo?
            for url in candidates {
                let client = JellyfinClient(baseURL: url)
                if let info = try? await client.publicInfo(), let id = info.id {
                    var urlText = url.absoluteString
                    while urlText.hasSuffix("/") { urlText.removeLast() }
                    found = JellyfinServerInfo(id: id, name: info.serverName ?? knownInfo?.name ?? url.host ?? "Server", url: urlText, isEmby: info.isEmby)
                    break
                }
            }
            guard self.jellyfin.requestID == requestID, self.thirdMenuMode == .jellyfin else { return }
            guard let found else {
                self.showJellyfinMessage(error: JellyfinError.unreachable.localizedDescription)
                self.playSound(named: "Limit")
                return
            }
            self.showJellyfinMessage()
            self.pushJellyfinPage(.signIn(found))
        }
    }

    private func askForJellyfinCredentials(_ info: JellyfinServerInfo) {
        requestTextEntry(title: "User Name", prompt: "Sign in to \(info.name).") { [weak self] user in
            guard let self, let user, !user.isEmpty else { return }
            self.requestTextEntry(title: "Password", prompt: "Enter the password for \(user).", isSecure: true) { [weak self] password in
                guard let self, let password else { return }
                self.signInToJellyfin(info, user: user, password: password)
            }
        }
    }

    private func signInToJellyfin(_ info: JellyfinServerInfo, user: String, password: String) {
        guard let url = URL(string: info.url) else { return }
        showJellyfinMessage(status: "Signing In...")
        let requestID = jellyfin.requestID
        Task { @MainActor in
            let client = JellyfinClient(baseURL: url)
            do {
                let result = try await client.authenticate(username: user, password: password)
                guard self.jellyfin.requestID == requestID else { return }
                self.finishJellyfinSignIn(info, result: result)
            } catch {
                guard self.jellyfin.requestID == requestID else { return }
                self.showJellyfinMessage(error: error.localizedDescription)
                self.playSound(named: "Limit")
            }
        }
    }

    private func startJellyfinQuickConnect(_ info: JellyfinServerInfo) {
        guard let url = URL(string: info.url) else { return }
        showJellyfinMessage()
        jellyfin.quickConnectRequestID &+= 1
        let requestID = jellyfin.quickConnectRequestID
        Task { @MainActor in
            let client = JellyfinClient(baseURL: url)
            guard await client.quickConnectEnabled() else {
                guard self.jellyfin.quickConnectRequestID == requestID else { return }
                self.showJellyfinMessage(error: JellyfinError.quickConnectDisabled.localizedDescription)
                self.playSound(named: "Limit")
                return
            }
            let start: JellyfinQuickConnect
            do {
                start = try await client.initiateQuickConnect()
            } catch {
                guard self.jellyfin.quickConnectRequestID == requestID else { return }
                self.showJellyfinMessage(error: error.localizedDescription)
                self.playSound(named: "Limit")
                return
            }
            guard self.jellyfin.quickConnectRequestID == requestID else { return }
            self.presentCodeDisplay(CodeDisplayState(
                title: "Quick Connect",
                message: "On a device signed in to \(info.name), open Quick Connect in your profile and enter this code.",
                code: start.code,
                status: "Waiting for approval...",
            )) {
                self.jellyfin.quickConnectRequestID &+= 1
            }
            // Asks every two seconds until it's approved, cancelled or ten minutes pass.
            for _ in 0 ..< 300 {
                try? await firstRowSleep(2)
                guard self.jellyfin.quickConnectRequestID == requestID else { return }
                guard let state = try? await client.quickConnectState(secret: start.secret) else { continue }
                guard self.jellyfin.quickConnectRequestID == requestID else { return }
                if state.authenticated {
                    self.updateCodeDisplayStatus("Signing In...")
                    do {
                        let result = try await client.authenticate(quickConnectSecret: start.secret)
                        guard self.jellyfin.quickConnectRequestID == requestID else { return }
                        self.dismissCodeDisplay()
                        self.playSound(named: "Selection")
                        self.finishJellyfinSignIn(info, result: result)
                    } catch {
                        guard self.jellyfin.quickConnectRequestID == requestID else { return }
                        self.dismissCodeDisplay()
                        self.showJellyfinMessage(error: error.localizedDescription)
                    }
                    return
                }
            }
            guard self.jellyfin.quickConnectRequestID == requestID else { return }
            self.dismissCodeDisplay()
            self.showJellyfinMessage(error: "The Code Ran Out")
        }
    }

    private func finishJellyfinSignIn(_ info: JellyfinServerInfo, result: JellyfinAuthResult) {
        let record = JellyfinServerRecord(
            serverID: result.serverID ?? info.id,
            serverName: info.name,
            url: info.url,
            userID: result.user.id,
            userName: result.user.name ?? "",
            accessToken: result.accessToken,
        )
        JellyfinStore.shared.save(record)
        jellyfin.status = nil
        objectWillChange.send()
        showJellyfinHome(record.key)
    }

    private func signOutOfJellyfin(_ key: String) {
        guard let record = JellyfinStore.shared.server(withKey: key) else { return }
        if let client = JellyfinClient(record: record) {
            Task { await client.signOut() }
        }
        JellyfinStore.shared.remove(record)
        objectWillChange.send()
        exitJellyfinToSources()
    }

    // MARK: - Preview

    private func clearJellyfinPreview() {
        jellyfin.previewItemID = nil
        jellyfin.previewImage = nil
    }

    /// The item under the selection on the current page, if it has a picture to show.
    var selectedJellyfinItem: JellyfinItem? {
        guard thirdMenuMode == .jellyfin, let state = currentJellyfinPage else { return nil }
        let rows = jellyfinMenuListItems()
        guard rows.indices.contains(selectedThirdIndex) else { return nil }
        let id = rows[selectedThirdIndex].id
        if case .home = state.page {
            guard id.hasPrefix("jellyfin_view_"), let index = Int(id.dropFirst("jellyfin_view_".count)), state.items.indices.contains(index) else { return nil }
            return state.items[index]
        }
        guard let index = jellyfinItemIndex(forRowID: id), state.items.indices.contains(index) else { return nil }
        return state.items[index]
    }

    func refreshJellyfinPreviewForCurrentContext() {
        if thirdMenuMode == .server || isShowingServerSongs {
            refreshServerPreviewForCurrentContext()
            return
        }
        if isShowingJellyfinSongs {
            refreshMusicPreviewForCurrentContext()
            return
        }
        guard let item = selectedJellyfinItem, let key = currentJellyfinServerKey, let client = jellyfinClient(forKey: key),
              let url = client.primaryImageURL(for: item, maxHeight: 900)
        else {
            clearJellyfinPreview()
            return
        }
        guard jellyfin.previewItemID != item.id else { return }
        jellyfin.previewItemID = item.id
        jellyfin.previewImage = nil
        Task { @MainActor in
            let image = await self.loadJellyfinImage(url)
            guard self.jellyfin.previewItemID == item.id else { return }
            self.jellyfin.previewImage = image
        }
    }

    func jellyfinGapContentItems(icon: (Double, Animation?) -> GapItemSpec, pass: RenderPass, memo: inout GapContentMemo) -> [GapItemSpec] {
        if thirdMenuMode == .server {
            return serverGapContentItems(icon: icon, pass: pass, memo: &memo)
        }
        let item = selectedJellyfinItem
        let image = (item?.id == jellyfin.previewItemID) ? jellyfin.previewImage : nil
        let key = image == nil ? "none" : (item?.id ?? "none")
        let animation = pass.animation(.easeInOut(duration: 0.22), when: memo.jellyfinPreviewKey != nil && memo.jellyfinPreviewKey != key)
        memo.jellyfinPreviewKey = key
        var items = [icon(image == nil ? 1 : 0, animation)]
        guard let item, let image else { return items }
        if item.type == "CollectionFolder" || item.type == "UserView" || item.type == "Folder" {
            // A library's picture, tilted like a movie's preview.
            let descriptor = MovieGapPreviewDescriptor(id: "jellyfin:\(item.id)", image: image, aspectRatio: aspectRatio(for: image, fallback: 16.0 / 9.0), sizeScale: 1.0)
            items.append(GapItemSpec(
                key: "jellyfin_preview:\(item.id)",
                kind: .moviePreview(moviePreviewSpec(descriptor)),
                animation: animation,
                transition: animation,
                fade: .easeInOut(duration: 0.22),
            ))
            return items
        }
        let isSquare = ["MusicAlbum", "MusicArtist", "Playlist", "Audio"].contains(item.type ?? "")
        items.append(GapItemSpec(
            key: "jellyfin_metadata",
            kind: .metadata(MetadataPreviewSpec(
                image: image,
                aspectRatio: aspectRatio(for: image, fallback: 2.0 / 3.0),
                forcedPreviewAspectRatio: isSquare ? 1.0 : nil,
                sizeScale: isSquare ? 0.92 : 0.75,
                title: item.type == "Episode" ? (item.seriesName ?? item.title) : item.title,
                description: jellyfinPreviewDescription(item),
                lines: jellyfinPreviewLines(item),
                baseIconSize: iconSize,
                offsetX: isSquare ? musicGapPreviewHorizontalOffset - 56 : movieGapPreviewHorizontalOffset,
                offsetY: isSquare ? gapContentVerticalOffset - 8 : gapContentVerticalOffset + 8,
                identity: "jellyfin:\(item.id)",
                transitionDelay: item.isVideo || item.type == "Series" ? 3 : 0,
                animatesTransition: item.isVideo || item.type == "Series",
            )),
            animation: animation,
            transition: animation,
            fade: .easeInOut(duration: 0.22),
        ))
        return items
    }

    private func jellyfinPreviewDescription(_ item: JellyfinItem) -> String? {
        guard let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty else { return nil }
        if item.type == "Episode" {
            return "\(item.title)\n\(overview)"
        }
        return overview
    }

    private func jellyfinPreviewLines(_ item: JellyfinItem) -> [MetadataPreviewSpec.Line] {
        var lines: [MetadataPreviewSpec.Line] = []
        switch item.type ?? "" {
        case "Episode":
            if let label = item.episodeLabel { lines.append(.init(label: "Episode", value: label)) }
            if item.overview == nil { lines.append(.init(label: "Title", value: item.title)) }
        case "MusicAlbum":
            if let artist = item.albumArtist { lines.append(.init(label: "Artist", value: artist)) }
        case "Series":
            if let count = item.childCount { lines.append(.init(label: "Seasons", value: "\(count)")) }
        default:
            break
        }
        if let year = item.productionYear { lines.append(.init(label: "Year", value: "\(year)")) }
        if item.durationSeconds > 0, item.isVideo {
            lines.append(.init(label: "Length", value: formatfirstRowPlaybackTime(item.durationSeconds)))
        }
        if let rating = item.officialRating, !rating.isEmpty { lines.append(.init(label: "Rated", value: rating)) }
        if item.resumeSeconds > 1, item.isVideo {
            lines.append(.init(label: "Stopped At", value: formatfirstRowPlaybackTime(item.resumeSeconds)))
        }
        return lines
    }
}
