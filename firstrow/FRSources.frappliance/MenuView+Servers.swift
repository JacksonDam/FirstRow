import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A page of a server's menus.
enum ServerPage: Equatable {
    /// Choosing a server to add: those found on the network, and the kinds there are.
    case add
    /// The ways of adding a Plex server: signing in to Plex, or by its address.
    case plex
    /// What a server shows first.
    case top(serverID: String)
    /// Something of a server's that was opened: a folder, a show, an album.
    case list(serverID: String, ServerItem)
}

struct ServerPageState {
    var page: ServerPage
    var selectedIndex = 0
    /// The row to select again once the page has loaded, after coming back to it.
    var selectedRowID: String?
    var items: [ServerItem] = []
    var isLoaded = false
}

/// The servers' pages' state, kept together so the menu holds one value for all of it.
struct ServerMenuState {
    var pages: [ServerPageState] = []
    var isLoading = false
    var error: String?
    var status: String?
    var found: [FoundMediaServer] = []
    var isLooking = false
    /// The pages to go back to from a song list opened from them.
    var songsReturnPages: [ServerPageState]?
    var previewItemID: String?
    var previewImage: NSImage?
    var requestID = 0
}

/// A movie playing from a server, and what the server was last told about it.
struct ServerPlaybackSession {
    var serverID: String
    var item: ServerItem
    var video: ServerVideo
    var lastReport = Date.distantPast
    var lastPosition: Double = 0
    var lastPaused = false
    var hasStarted = false
}

/// The makers of each kind of server's client.
@MainActor
enum MediaServerClients {
    static func client(for record: MediaServerRecord) -> (any MediaServerClient)? {
        switch record.kind {
        case .plex: PlexClient(record: record)
        case .kodi: KodiClient(record: record)
        case .upnp: UPnPClient(record: record)
        case .sharedFolder: SharedFolderClient(record: record)
        }
    }

    /// The servers of every kind on the local network. (Those found by the names they
    /// announce are looked at only when one is chosen: `asks` says to.)
    static func discover() async -> [FoundMediaServer] {
        #if FIRSTROW_PORTABLE
            return await UPnPClient.discover()
        #else
            async let upnp = UPnPClient.discover()
            async let plex = LocalNetwork.services(ofType: "_plexmediasvr._tcp")
            async let kodi = LocalNetwork.services(ofType: "_xbmc-jsonrpc-h._tcp")
            async let shared = SharedFolderClient.isAvailable ? LocalNetwork.services(ofType: "_smb._tcp", models: true) : []
            var found: [FoundMediaServer] = []
            for server in await plex {
                found.append(FoundMediaServer(kind: .plex, name: server.name, address: "http://\(server.host):\(server.port)", details: ["asks": "1"]))
            }
            for server in await kodi {
                found.append(FoundMediaServer(kind: .kodi, name: server.name, address: "http://\(server.host):\(server.port)", details: ["asks": "1"]))
            }
            // (This computer's own shared folders aren't offered to itself. A Mac is known
            // as one: it takes a name and password only on a condition, which is said.)
            for server in await shared where !LocalNetwork.isThisComputer(server.host) {
                var details = ["asks": "1"]
                if server.isMac { details["mac"] = "1" }
                found.append(FoundMediaServer(kind: .sharedFolder, name: server.name, address: server.port == 445 ? server.host : "\(server.host):\(server.port)", details: details))
            }
            // (A Plex server or Kodi that also answers as a UPnP server is listed once, as itself.)
            let named = Set(found.map { $0.name.lowercased() })
            found += await upnp.filter { server in !named.contains { server.name.lowercased().contains($0) } }
            return found
        #endif
    }

    /// The server of a kind at an address someone typed.
    static func find(_ kind: MediaServerKind, at typed: String, user: String?, password: String?) async throws -> FoundMediaServer {
        switch kind {
        case .plex: try await PlexClient.find(at: typed, caller: .current)
        case .kodi: try await KodiClient.find(at: typed, user: user, password: password)
        case .upnp: try await UPnPClient.find(at: typed)
        case .sharedFolder: try await SharedFolderClient.find(at: typed, user: user, password: password)
        }
    }

    /// The kinds that can be added here.
    static var kinds: [MediaServerKind] {
        SharedFolderClient.isAvailable ? [.plex, .kodi, .upnp, .sharedFolder] : [.plex, .kodi, .upnp]
    }
}

/// Sources: the media servers and shared folders other than Jellyfin's and Emby's, and
/// adding one (see `MediaServers.swift`).
extension MenuView {
    static let addServerItemID = "server_add"
    static let serverItemPrefix = "server|"

    var currentServerPage: ServerPageState? {
        servers.pages.last
    }

    var isShowingServerSongs: Bool {
        activeRootItemID == "sources" && thirdMenuMode == .musicSongs && servers.songsReturnPages != nil
    }

    // MARK: - The Sources menu

    /// The rows for the servers that have been added, and for adding one.
    func serverSubmenuItems(startsGroup: Bool) -> [SubmenuItemConfig] {
        var items: [SubmenuItemConfig] = []
        for (index, server) in MediaServerStore.shared.servers.enumerated() {
            items.append(SubmenuItemConfig(
                id: Self.serverItemPrefix + server.id,
                title: server.name,
                leadsToMenu: true,
                showsTopDivider: startsGroup && index == 0,
            ))
        }
        return items
    }

    /// Handles the servers' rows of Sources. Returns false for rows handled elsewhere.
    func triggerServerSourcesItem(_ item: SubmenuItemConfig) -> Bool {
        if item.id == Self.addServerItemID {
            playSound(named: "Selection")
            enterServers(pages: [ServerPageState(page: .add)])
            return true
        }
        if item.id.hasPrefix(Self.serverItemPrefix) {
            let id = String(item.id.dropFirst(Self.serverItemPrefix.count))
            guard MediaServerStore.shared.server(withID: id) != nil else {
                playLimitSoundOnceForCurrentHold()
                return true
            }
            playSound(named: "Selection")
            enterServers(pages: [ServerPageState(page: .top(serverID: id))])
            return true
        }
        return false
    }

    // MARK: - Rows

    func serverMenuListItems() -> [MenuListItemConfig] {
        guard let state = currentServerPage else { return [] }
        var items: [MenuListItemConfig] = []
        if let status = servers.status {
            items.append(menuMessageItem(id: "server_status", title: status))
        } else if let error = servers.error {
            items.append(menuMessageItem(id: "server_error", title: error))
        }
        switch state.page {
        case .add:
            for (index, server) in servers.found.enumerated() {
                let kind = server.details["jellyfin"] != nil ? "Jellyfin or Emby" : server.kind == .upnp ? "UPnP" : server.kind.title
                items.append(plainMenuListItem(id: "server_found_\(index)", title: server.name, trailingText: kind))
            }
            if servers.isLooking, servers.found.isEmpty, servers.status == nil {
                items.append(menuMessageItem(id: "server_looking", title: "Looking for Servers..."))
            }
            items.append(plainMenuListItem(id: "server_kind_jellyfin", title: "Jellyfin or Emby", trailingText: "...", showsTopDivider: !items.isEmpty))
            for kind in MediaServerClients.kinds {
                items.append(plainMenuListItem(id: "server_kind_\(kind.rawValue)", title: kind.title, trailingText: "..."))
            }
            if !servers.isLooking {
                items.append(plainMenuListItem(id: "server_look_again", title: "Look Again", showsTopDivider: true))
            }
        case .plex:
            items.append(plainMenuListItem(id: "server_plex_sign_in", title: "Sign In to Plex", trailingText: "..."))
            items.append(plainMenuListItem(id: "server_plex_address", title: "Enter the Server's Address", trailingText: "..."))
        case .top, .list:
            guard state.isLoaded else { return items }
            if state.items.isEmpty, servers.error == nil {
                items.append(menuMessageItem(id: "server_empty", title: "Nothing Here"))
            }
            for (index, item) in state.items.enumerated() {
                items.append(plainMenuListItem(
                    id: "server_item_\(index)",
                    title: serverRowTitle(item),
                    leadsToMenu: item.opens,
                    trailingText: item.trailing,
                    showsBlueDot: item.isUnwatched,
                ))
            }
            if case .top = state.page {
                items.append(plainMenuListItem(id: "server_remove", title: "Remove This Server", showsTopDivider: true))
            }
        }
        return items
    }

    private func serverRowTitle(_ item: ServerItem) -> String {
        if item.kind == .song, item.trackNumber > 0 { return "\(item.trackNumber). \(item.title)" }
        return item.title
    }

    private func serverItemIndex(forRowID id: String) -> Int? {
        guard id.hasPrefix("server_item_") else { return nil }
        return Int(id.dropFirst("server_item_".count))
    }

    var shouldHideServerMenuUntilLoaded: Bool {
        guard let state = currentServerPage else { return false }
        switch state.page {
        case .add, .plex: return false
        case .top, .list: return !state.isLoaded && servers.error == nil
        }
    }

    func serverTitle(for page: ServerPage) -> String {
        switch page {
        case .add:
            return "Add Server"
        case .plex:
            return "Plex"
        case let .top(id):
            return truncatedHeaderTitle(MediaServerStore.shared.server(withID: id)?.name ?? "Server", fallback: "Server")
        case let .list(_, item):
            return truncatedHeaderTitle(item.title, fallback: "Server")
        }
    }

    private func serverClient(withID id: String) -> (any MediaServerClient)? {
        MediaServerStore.shared.server(withID: id).flatMap { MediaServerClients.client(for: $0) }
    }

    private var currentServerID: String? {
        for state in servers.pages.reversed() {
            switch state.page {
            case let .top(id), let .list(id, _): return id
            case .add, .plex: continue
            }
        }
        return nil
    }

    /// Shows a message above the rows (or clears it) while keeping the same row selected.
    private func showServerMessage(error: String? = nil, status: String? = nil) {
        let rows = serverMenuListItems()
        let selectedID = rows.indices.contains(selectedThirdIndex) ? rows[selectedThirdIndex].id : nil
        servers.error = error
        servers.status = status
        if let selectedID, let index = serverMenuListItems().firstIndex(where: { $0.id == selectedID }) {
            selectedThirdIndex = index
        }
    }

    // MARK: - Moving between pages

    func enterServers(pages: [ServerPageState]) {
        servers.requestID &+= 1
        transitionMenuForFolderSwap(useOverlayFade: true, revealWhen: { !self.shouldHideServerMenuUntilLoaded }) {
            self.thirdMenuMode = .server
            self.isInThirdMenu = true
            self.servers.pages = pages
            self.servers.error = nil
            self.servers.status = nil
            self.servers.songsReturnPages = nil
            self.selectedThirdIndex = 0
            self.headerText = self.serverTitle(for: pages.last?.page ?? .add)
            self.clearServerPreview()
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
            self.loadCurrentServerPage()
        }
    }

    private func pushServerPage(_ page: ServerPage) {
        transitionMenuForFolderSwap(revealWhen: { !self.shouldHideServerMenuUntilLoaded }) {
            self.rememberServerSelection()
            self.servers.pages.append(ServerPageState(page: page))
            self.servers.error = nil
            self.servers.status = nil
            self.selectedThirdIndex = 0
            self.headerText = self.serverTitle(for: page)
            self.clearServerPreview()
            self.loadCurrentServerPage()
        }
    }

    /// Replaces every page with a server's first page, once it has been added.
    private func showServerTop(_ id: String) {
        transitionMenuForFolderSwap(useOverlayFade: true, revealWhen: { !self.shouldHideServerMenuUntilLoaded }) {
            self.servers.pages = [ServerPageState(page: .top(serverID: id))]
            self.servers.error = nil
            self.servers.status = nil
            self.selectedThirdIndex = 0
            self.headerText = self.serverTitle(for: .top(serverID: id))
            self.clearServerPreview()
            self.loadCurrentServerPage()
        }
    }

    func navigateUpInServerMenu() {
        servers.requestID &+= 1
        guard servers.pages.count > 1 else {
            exitServersToSources()
            return
        }
        transitionMenuForFolderSwap(revealWhen: { !self.shouldHideServerMenuUntilLoaded }) {
            self.servers.pages.removeLast()
            self.servers.error = nil
            self.servers.status = nil
            self.servers.isLoading = false
            self.showReturnedServerPage()
        }
    }

    private func rememberServerSelection() {
        let rows = serverMenuListItems()
        guard var current = servers.pages.popLast() else { return }
        current.selectedIndex = selectedThirdIndex
        current.selectedRowID = rows.indices.contains(selectedThirdIndex) ? rows[selectedThirdIndex].id : nil
        servers.pages.append(current)
    }

    private func showReturnedServerPage() {
        guard let page = currentServerPage else { return }
        headerText = serverTitle(for: page.page)
        clearServerPreview()
        if page.isLoaded || page.page == .add || page.page == .plex {
            selectServerRememberedRow()
            refreshDetailPreviewForCurrentContext()
        } else {
            selectedThirdIndex = 0
            loadCurrentServerPage()
        }
    }

    private func selectServerRememberedRow() {
        guard let index = servers.pages.indices.last else { return }
        let page = servers.pages[index]
        let rows = serverMenuListItems()
        if let id = page.selectedRowID, let row = rows.firstIndex(where: { $0.id == id }) {
            selectedThirdIndex = row
        } else {
            selectedThirdIndex = min(page.selectedIndex, max(0, rows.count - 1))
        }
        servers.pages[index].selectedRowID = nil
    }

    private func exitServersToSources() {
        transitionMenuForFolderSwap(useOverlayFade: true) {
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.servers.pages = []
            self.servers.error = nil
            self.servers.status = nil
            self.servers.isLoading = false
            self.servers.isLooking = false
            self.clearServerPreview()
            let items = self.currentSubmenuItems()
            self.selectedSubIndex = min(self.selectedSubIndex, max(0, items.count - 1))
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
        }
    }

    /// Back from a song list opened from a server's page, to that page.
    func returnFromServerSongs() {
        guard let pages = servers.songsReturnPages else { return }
        servers.requestID &+= 1
        transitionMenuForFolderSwap(revealWhen: { !self.shouldHideServerMenuUntilLoaded }) {
            self.servers.songsReturnPages = nil
            self.thirdMenuMode = .server
            self.servers.pages = pages
            self.servers.error = nil
            self.isLoadingMusicSongs = false
            self.musicSongsLoadError = nil
            self.musicSongsShowsShuffleAction = false
            self.resetMusicPreviewState()
            self.showReturnedServerPage()
        }
    }

    // MARK: - Loading

    private func loadCurrentServerPage(quietly: Bool = false) {
        guard let state = currentServerPage else { return }
        let requestID = servers.requestID &+ 1
        servers.requestID = requestID
        let pageIndex = servers.pages.count - 1
        func finish(_ items: [ServerItem]?) {
            guard servers.requestID == requestID, servers.pages.indices.contains(pageIndex) else { return }
            let rows = serverMenuListItems()
            let selectedID = quietly && rows.indices.contains(selectedThirdIndex) ? rows[selectedThirdIndex].id : nil
            if let items { servers.pages[pageIndex].items = items }
            servers.pages[pageIndex].isLoaded = true
            servers.isLoading = false
            if let selectedID, let index = serverMenuListItems().firstIndex(where: { $0.id == selectedID }) {
                selectedThirdIndex = index
            } else if servers.pages[pageIndex].selectedRowID != nil {
                selectServerRememberedRow()
            }
            let count = serverMenuListItems().count
            if selectedThirdIndex >= count { selectedThirdIndex = max(0, count - 1) }
            refreshDetailPreviewForCurrentContext()
        }
        func load(_ id: String, _ work: @escaping (any MediaServerClient) async throws -> [ServerItem]) {
            guard let client = serverClient(withID: id) else {
                servers.error = MediaServerError.unreachable.localizedDescription
                finish(nil)
                return
            }
            servers.isLoading = !quietly
            Task { @MainActor in
                do {
                    let items = try await work(client)
                    finish(items)
                } catch {
                    guard self.servers.requestID == requestID else { return }
                    // A folder that wants a name and password asks for them here.
                    let wantsSignIn = (error as? MediaServerError).map { if case .signInNeeded = $0 { true } else { false } } ?? false
                    let record = MediaServerStore.shared.server(withID: id)
                    let canSignIn = record?.kind == .sharedFolder || record?.kind == .kodi
                    self.servers.error = wantsSignIn && record?.user != nil ? MediaServerError.signInFailed.localizedDescription : error.localizedDescription
                    finish(nil)
                    guard wantsSignIn, canSignIn, let record else { return }
                    // (Once the menu has finished changing, which an answer that comes at
                    // once is ahead of: the menu would come back in over the question.)
                    while self.isMenuFolderSwapTransitioning { try? await firstRowSleep(0.05) }
                    guard self.servers.requestID == requestID, self.thirdMenuMode == .server else { return }
                    self.askForSignIn(to: record)
                }
            }
        }
        switch state.page {
        case .add:
            lookForServers()
        case .plex:
            break
        case let .top(id):
            load(id) { try await $0.top() }
        case let .list(id, item):
            load(id) { try await $0.children(of: item) }
        }
    }

    /// Reloads what is showing after a movie, so what has been watched and where it stopped
    /// catch up.
    func refreshServerPageAfterPlayback() {
        if thirdMenuMode == .server, let page = currentServerPage, page.page != .add, page.page != .plex {
            loadCurrentServerPage(quietly: true)
        }
    }

    private func lookForServers() {
        servers.isLooking = true
        servers.found = []
        let requestID = servers.requestID
        Task { @MainActor in
            async let others = MediaServerClients.discover()
            async let jellyfin = JellyfinDiscovery.discover()
            var found = await others
            for server in await jellyfin {
                found.append(FoundMediaServer(kind: .upnp, name: server.name, address: server.url, details: ["jellyfin": server.id]))
                // (Many a Jellyfin or Emby server answers as a UPnP one too: it's listed once, as itself.)
                if let host = URL(string: server.url)?.host {
                    found.removeAll { $0.details["jellyfin"] == nil && URL(string: $0.address)?.host == host && $0.name.localizedCaseInsensitiveContains(server.name) }
                }
            }
            guard self.servers.requestID == requestID, self.currentServerPage?.page == .add else { return }
            // (Not the ones already added.)
            let kept = MediaServerStore.shared.servers
            found.removeAll { server in kept.contains { $0.kind == server.kind && $0.address == server.address } }
            let rows = self.serverMenuListItems()
            let selectedID = rows.indices.contains(self.selectedThirdIndex) ? rows[self.selectedThirdIndex].id : nil
            self.servers.found = found
            self.servers.isLooking = false
            if let selectedID, let index = self.serverMenuListItems().firstIndex(where: { $0.id == selectedID }) {
                self.selectedThirdIndex = index
            }
        }
    }

    // MARK: - Actions

    func triggerServerMenuAction() {
        let rows = serverMenuListItems()
        guard rows.indices.contains(selectedThirdIndex), let state = currentServerPage else { return }
        let id = rows[selectedThirdIndex].id
        switch state.page {
        case .add:
            if id == "server_look_again" {
                showServerMessage()
                lookForServers()
            } else if id == "server_kind_jellyfin" {
                playSound(named: "Selection")
                enterJellyfin(pages: [JellyfinPageState(page: .addServer)])
            } else if id == "server_kind_plex" {
                playSound(named: "Selection")
                pushServerPage(.plex)
            } else if id.hasPrefix("server_kind_"), let kind = MediaServerKind(rawValue: String(id.dropFirst("server_kind_".count))) {
                askForServerAddress(kind)
            } else if id.hasPrefix("server_found_"), let index = Int(id.dropFirst("server_found_".count)), servers.found.indices.contains(index) {
                addFoundServer(servers.found[index])
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        case .plex:
            if id == "server_plex_sign_in" {
                signInToPlex()
            } else if id == "server_plex_address" {
                askForServerAddress(.plex)
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        case let .top(serverID), let .list(serverID, _):
            if id == "server_remove" {
                removeServer(serverID)
                return
            }
            guard let index = serverItemIndex(forRowID: id), state.items.indices.contains(index) else {
                if id == "server_error" { loadCurrentServerPage() } else { playLimitSoundOnceForCurrentHold() }
                return
            }
            openServerItem(state.items[index], in: state.items, serverID: serverID)
        }
    }

    private func openServerItem(_ item: ServerItem, in items: [ServerItem], serverID: String) {
        if item.isVideo {
            playServerVideo(item, serverID: serverID)
            return
        }
        switch item.kind {
        case .song:
            // A song among other things: played with the songs around it.
            let songs = items.filter { $0.kind == .song }
            guard let position = songs.firstIndex(where: { $0.id == item.id }) else { return }
            let entries = serverSongEntries(songs, serverID: serverID)
            guard entries.indices.contains(position), entries[position].url != nil else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            startPlaybackForMusicLibraryEntry(entries[position], trackIndex: position, trackCount: entries.count, playbackQueue: entries)
        case .album, .playlist:
            openServerSongs(item, serverID: serverID)
        case .photo:
            playLimitSoundOnceForCurrentHold()
        default:
            playSound(named: "Selection")
            pushServerPage(.list(serverID: serverID, item))
        }
    }

    // MARK: - Songs

    /// Opens an album's or a playlist's songs in the Music songs list, with its previews and
    /// Now Playing. (What turns out to hold something other than songs opens as a folder.)
    private func openServerSongs(_ item: ServerItem, serverID: String) {
        guard let client = serverClient(withID: serverID) else { return }
        servers.requestID &+= 1
        let requestID = servers.requestID
        showServerMessage(status: "Opening...")
        Task { @MainActor in
            do {
                let found = try await client.children(of: item)
                guard self.servers.requestID == requestID, self.thirdMenuMode == .server else { return }
                self.showServerMessage()
                let songs = found.filter { $0.kind == .song }
                guard !songs.isEmpty, songs.count == found.count else {
                    self.playSound(named: "Selection")
                    self.pushServerPage(.list(serverID: serverID, item))
                    return
                }
                self.playSound(named: "Selection")
                self.rememberServerSelection()
                let returnPages = self.servers.pages
                let entries = self.serverSongEntries(songs, serverID: serverID)
                self.transitionMenuForFolderSwap {
                    self.prepareMusicLibraryThirdMenu(
                        mode: .musicSongs,
                        title: self.truncatedHeaderTitle(item.title, fallback: "Songs"),
                        categoryKind: nil,
                        categoryTitle: "",
                        shuffleMode: false,
                        libraryMediaType: .songs,
                        showsShuffleAction: true,
                    )
                    self.servers.songsReturnPages = returnPages
                    self.clearServerPreview()
                    self.musicSongsThirdMenuItems = entries
                    self.musicSongsLoadError = nil
                    self.isLoadingMusicSongs = false
                    self.refreshDetailPreviewForCurrentContext()
                }
            } catch {
                guard self.servers.requestID == requestID else { return }
                self.showServerMessage(error: error.localizedDescription)
                self.playSound(named: "Limit")
            }
        }
    }

    func serverSongEntries(_ items: [ServerItem], serverID: String) -> [MusicLibrarySongEntry] {
        items.enumerated().map { index, item in
            MusicLibrarySongEntry(
                id: "server|\(serverID)|\(item.id)|\(index)",
                title: item.title,
                artist: item.artist ?? "",
                album: item.album ?? "",
                genre: "",
                composer: "",
                durationSeconds: item.durationSeconds,
                trackNumber: item.trackNumber,
                discNumber: item.discNumber,
                artworkAlbumKey: item.imageURL.map { "jellyfin-art::\($0.absoluteString)" },
                url: item.mediaURL,
                artwork: nil,
                // (A song that streams from a server, with a picture to fetch.)
                jellyfin: JellyfinTrackReference(serverKey: "", itemID: item.id, imageURL: item.imageURL),
            )
        }
    }

    // MARK: - Adding and removing servers

    private func askForServerAddress(_ kind: MediaServerKind) {
        let prompt = switch kind {
        case .plex: "Type the Plex server's address, like 192.168.1.20."
        case .kodi: "Type the address of the computer running Kodi, like 192.168.1.20. Kodi's remote control over HTTP has to be turned on in its settings."
        case .upnp: "Type the media server's address, like 192.168.1.20."
        case .sharedFolder: "Type the name or address of the computer or network drive, like nas.local or 192.168.1.20."
        }
        requestTextEntry(title: kind == .sharedFolder ? "Computer or Drive" : "Server Address", prompt: prompt) { [weak self] text in
            guard let self, let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.connectToServer(kind, typed: text, user: nil, password: nil)
        }
    }

    /// Finds the server at an address, asking for a name and password if it wants them.
    /// (`isMac`: it was found on the network, and says it is a Mac.)
    private func connectToServer(_ kind: MediaServerKind, typed: String, user: String?, password: String?, isMac: Bool = false) {
        showServerMessage(status: "Connecting...")
        let requestID = servers.requestID
        Task { @MainActor in
            do {
                var found = try await MediaServerClients.find(kind, at: typed, user: user, password: password)
                guard self.servers.requestID == requestID, self.thirdMenuMode == .server else { return }
                if isMac { found.details["mac"] = "1" }
                self.showServerMessage()
                self.keepServer(found, user: user, password: password)
            } catch MediaServerError.signInNeeded where user == nil {
                guard self.servers.requestID == requestID, self.thirdMenuMode == .server else { return }
                self.showServerMessage()
                self.askForServerSignIn(kind, typed: typed, isMac: isMac)
            } catch {
                guard self.servers.requestID == requestID, self.thirdMenuMode == .server else { return }
                let wrongSignIn = user != nil && (error as? MediaServerError).map { if case .signInNeeded = $0 { true } else { false } } ?? false
                self.showServerMessage(error: wrongSignIn ? MediaServerError.signInFailed.localizedDescription : error.localizedDescription)
                self.playSound(named: "Limit")
            }
        }
    }

    private func askForServerSignIn(_ kind: MediaServerKind, typed: String, isMac: Bool = false) {
        requestTextEntry(title: "User Name", prompt: Self.signInPrompt(for: typed, isMac: isMac)) { [weak self] user in
            guard let self, let user, !user.isEmpty else { return }
            self.requestTextEntry(title: "Password", prompt: "Enter the password for \(user).", isSecure: true) { [weak self] password in
                guard let self, let password else { return }
                self.connectToServer(kind, typed: typed, user: user, password: password, isMac: isMac)
            }
        }
    }

    /// What the question for a name says. A Mac takes a name and password from an app like
    /// this one only for an account that has Windows File Sharing turned on (it keeps no
    /// password in the form such a sign-in needs otherwise), so that is said where it is asked.
    private static func signInPrompt(for name: String, isMac: Bool) -> String {
        guard isMac else { return "Sign in to \(name)." }
        return "Sign in to \(name). A Mac wants Windows File Sharing turned on for the account first: System Settings, General, Sharing, File Sharing, Options."
    }

    /// Signs in to Plex with a code shown here and typed at plex.tv/link, then keeps every
    /// server the account can use.
    private func signInToPlex() {
        showServerMessage(status: "Asking Plex for a Code...")
        servers.requestID &+= 1
        let requestID = servers.requestID
        let caller = PlexCaller.current
        Task { @MainActor in
            let code: PlexAccount.Code
            do {
                code = try await PlexAccount.requestCode(caller: caller)
            } catch {
                guard self.servers.requestID == requestID else { return }
                self.showServerMessage(error: "Can't Reach Plex")
                self.playSound(named: "Limit")
                return
            }
            guard self.servers.requestID == requestID, self.thirdMenuMode == .server else { return }
            self.showServerMessage()
            self.presentCodeDisplay(CodeDisplayState(
                title: "Sign In to Plex",
                message: "On a phone or computer, go to plex.tv/link, sign in and enter this code.",
                code: code.code,
                status: "Waiting for the code...",
            )) {
                self.servers.requestID &+= 1
            }
            // Asks every two seconds until the code has been entered, cancelled or has run out.
            for _ in 0 ..< 420 {
                try? await firstRowSleep(2)
                guard self.servers.requestID == requestID else { return }
                guard let token = await PlexAccount.token(for: code, caller: caller) else { continue }
                guard self.servers.requestID == requestID else { return }
                self.updateCodeDisplayStatus("Finding Your Servers...")
                let found = (try? await PlexAccount.servers(token: token, caller: caller)) ?? []
                guard self.servers.requestID == requestID else { return }
                self.dismissCodeDisplay()
                guard !found.isEmpty else {
                    self.showServerMessage(error: "No Plex Servers Could Be Reached")
                    self.playSound(named: "Limit")
                    return
                }
                self.playSound(named: "Selection")
                for server in found.dropFirst() {
                    MediaServerStore.shared.save(MediaServerRecord(
                        id: UUID().uuidString.lowercased(), kind: .plex, name: server.name, address: server.address,
                        token: server.details["token"], details: nil,
                    ))
                }
                self.keepServer(found[0], user: nil, password: nil)
                return
            }
            guard self.servers.requestID == requestID else { return }
            self.dismissCodeDisplay()
            self.showServerMessage(error: "The Code Ran Out")
        }
    }

    /// Asks who to sign in to a server as, keeps the answer with the server and looks again.
    private func askForSignIn(to record: MediaServerRecord) {
        requestTextEntry(title: "User Name", prompt: Self.signInPrompt(for: record.name, isMac: record.details?["mac"] != nil), initialText: record.user ?? "") { [weak self] user in
            guard let self, let user, !user.isEmpty else { return }
            self.requestTextEntry(title: "Password", prompt: "Enter the password for \(user).", isSecure: true) { [weak self] password in
                guard let self, let password else { return }
                var signedIn = record
                signedIn.user = user
                signedIn.password = password
                MediaServerStore.shared.save(signedIn)
                guard self.thirdMenuMode == .server else { return }
                self.servers.error = nil
                self.loadCurrentServerPage()
            }
        }
    }

    private func addFoundServer(_ server: FoundMediaServer) {
        if let id = server.details["jellyfin"] {
            // (A Jellyfin or Emby server: its own menus sign in to it.)
            playSound(named: "Selection")
            enterJellyfin(connectingTo: JellyfinServerInfo(id: id, name: server.name, url: server.address))
            return
        }
        playSound(named: "Selection")
        if server.details["asks"] != nil {
            // (Found by the name it announces: it's asked what it is now.)
            connectToServer(server.kind, typed: server.address, user: nil, password: nil, isMac: server.details["mac"] != nil)
            return
        }
        keepServer(server, user: nil, password: nil)
    }

    private func keepServer(_ server: FoundMediaServer, user: String?, password: String?) {
        let record = MediaServerRecord(
            id: UUID().uuidString.lowercased(),
            kind: server.kind,
            name: server.name,
            address: server.address,
            user: user,
            password: password,
            token: server.details["token"],
            details: server.details.filter { $0.key != "token" }.isEmpty ? nil : server.details.filter { $0.key != "token" },
        )
        MediaServerStore.shared.save(record)
        objectWillChange.send()
        // (As the store has it: one already there keeps its place.)
        let kept = MediaServerStore.shared.servers.first { $0.kind == record.kind && $0.address == record.address && $0.user == record.user } ?? record
        showServerTop(kept.id)
    }

    private func removeServer(_ id: String) {
        guard let record = MediaServerStore.shared.server(withID: id) else { return }
        playSound(named: "Selection")
        MediaServerStore.shared.remove(record)
        objectWillChange.send()
        exitServersToSources()
    }

    // MARK: - Playing movies

    func playServerVideo(_ item: ServerItem, serverID: String) {
        guard !isMovieTransitioning, !isMoviePlaybackVisible, !isStartingServerPlayback, let client = serverClient(withID: serverID) else { return }
        isStartingServerPlayback = true
        resetScreenSaverIdleTimer()
        Task { @MainActor in
            defer { self.isStartingServerPlayback = false }
            let video: ServerVideo
            do {
                video = try await client.video(for: item)
            } catch {
                self.playSound(named: "Limit")
                let unreachable = (error as? MediaServerError).map { if case .unreachable = $0 { true } else { false } } ?? false
                self.presentFullscreenScene(key: self.featureErrorFullscreenKey, payload: [
                    "header": "This video can't be played.",
                    "subcaption": unreachable ? "The server can't be reached." : "The server gave nothing to play.",
                ])
                return
            }
            guard self.thirdMenuMode == .server, !self.isMovieTransitioning, !self.isMoviePlaybackVisible else { return }
            self.playSound(named: "Selection")
            self.serverVideoSession = ServerPlaybackSession(serverID: serverID, item: item, video: video)
            // The resume prompt reads these, as it does for a movie closed part way through.
            let url = video.url.standardizedFileURL
            if item.resumeSeconds > 5, item.durationSeconds <= 0 || item.resumeSeconds < item.durationSeconds - 10 {
                self.lastClosedMovieURL = url
                self.lastClosedMovieTimestamp = item.resumeSeconds
            } else if self.lastClosedMovieURL?.standardizedFileURL == url {
                // (The server keeps track, and says it's at the start.)
                self.lastClosedMovieURL = nil
                self.lastClosedMovieTimestamp = 0
            }
            self.beginMoviePlayback(for: url)
        }
    }

    /// The server movie that is at an address, if that's what is being played.
    func serverVideo(at url: URL) -> ServerVideo? {
        guard let session = serverVideoSession, session.video.url.standardizedFileURL == url.standardizedFileURL else { return nil }
        return session.video
    }

    /// Called as the movie player starts a URL.
    func serverMoviePlaybackDidActivate(url: URL, startSeconds: Double) {
        guard var session = serverVideoSession else { return }
        guard session.video.url.standardizedFileURL == url.standardizedFileURL else {
            serverVideoSession = nil
            return
        }
        session.hasStarted = true
        session.lastReport = Date()
        session.lastPosition = startSeconds
        serverVideoSession = session
        if let client = serverClient(withID: session.serverID) {
            let item = session.item
            Task { await client.note(.started, of: item, seconds: startSeconds) }
        }
        startServerProgressTimer()
    }

    /// Called as the movie player stops, before it lets go of the player.
    func serverMoviePlaybackWillEnd(atEnd: Bool = false) {
        guard let session = serverVideoSession else { return }
        serverVideoSession = nil
        serverProgressTimer?.invalidate()
        serverProgressTimer = nil
        guard session.hasStarted, let client = serverClient(withID: session.serverID) else { return }
        var position = moviePlaybackCurrentSeconds
        if let seconds = moviePlayer?.positionSeconds { position = max(position, seconds) }
        let finished = atEnd || (moviePlaybackDurationSeconds > 0 && position >= moviePlaybackDurationSeconds - 1)
        let item = session.item
        Task { @MainActor in
            await client.note(finished ? .ended : .stopped, of: item, seconds: position)
            self.refreshServerPageAfterPlayback()
        }
    }

    private func startServerProgressTimer() {
        guard serverProgressTimer == nil else { return }
        let timer = Timer(after: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible { self?.reportServerProgressIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        serverProgressTimer = timer
    }

    /// Every ten seconds, and straight away on a pause, a resume or a jump.
    private func reportServerProgressIfDue() {
        guard var session = serverVideoSession, session.hasStarted, isMoviePlaybackVisible else { return }
        let now = Date()
        let position = moviePlaybackCurrentSeconds
        let paused = (moviePlayer?.rate ?? 0) < 0.01
        let expected = session.lastPosition + (session.lastPaused ? 0 : now.timeIntervalSince(session.lastReport))
        let jumped = abs(position - expected) > 4
        guard paused != session.lastPaused || jumped || now.timeIntervalSince(session.lastReport) >= 10 else { return }
        session.lastReport = now
        session.lastPosition = position
        session.lastPaused = paused
        serverVideoSession = session
        if let client = serverClient(withID: session.serverID) {
            let item = session.item
            Task { await client.note(paused ? .paused : .playing, of: item, seconds: position) }
        }
    }

    // MARK: - Preview

    private func clearServerPreview() {
        servers.previewItemID = nil
        servers.previewImage = nil
    }

    /// The item under the selection on the current page.
    var selectedServerItem: ServerItem? {
        guard thirdMenuMode == .server, let state = currentServerPage else { return nil }
        let rows = serverMenuListItems()
        guard rows.indices.contains(selectedThirdIndex), let index = serverItemIndex(forRowID: rows[selectedThirdIndex].id),
              state.items.indices.contains(index)
        else { return nil }
        return state.items[index]
    }

    func refreshServerPreviewForCurrentContext() {
        if isShowingServerSongs {
            refreshMusicPreviewForCurrentContext()
            return
        }
        guard let item = selectedServerItem, let url = item.imageURL else {
            clearServerPreview()
            return
        }
        guard servers.previewItemID != item.id else { return }
        servers.previewItemID = item.id
        servers.previewImage = nil
        Task { @MainActor in
            let image = await self.loadJellyfinImage(url)
            guard self.servers.previewItemID == item.id else { return }
            self.servers.previewImage = image
        }
    }

    func serverGapContentItems(icon: (Double, Animation?) -> GapItemSpec, pass: RenderPass, memo: inout GapContentMemo) -> [GapItemSpec] {
        let item = selectedServerItem
        let image = (item?.id == servers.previewItemID) ? servers.previewImage : nil
        let key = image == nil ? "none" : (item?.id ?? "none")
        let animation = pass.animation(.easeInOut(duration: 0.22), when: memo.serverPreviewKey != nil && memo.serverPreviewKey != key)
        memo.serverPreviewKey = key
        var items = [icon(image == nil ? 1 : 0, animation)]
        guard let item, let image else { return items }
        let isSquare = [.album, .artist, .playlist, .song].contains(item.kind)
        var lines: [MetadataPreviewSpec.Line] = []
        if let artist = item.artist, !artist.isEmpty, isSquare { lines.append(.init(label: "Artist", value: artist)) }
        if let year = item.year { lines.append(.init(label: "Year", value: "\(year)")) }
        if item.durationSeconds > 0, item.isVideo { lines.append(.init(label: "Length", value: formatfirstRowPlaybackTime(item.durationSeconds))) }
        if let rating = item.rating, !rating.isEmpty { lines.append(.init(label: "Rated", value: rating)) }
        if item.resumeSeconds > 1, item.isVideo { lines.append(.init(label: "Stopped At", value: formatfirstRowPlaybackTime(item.resumeSeconds))) }
        let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(GapItemSpec(
            key: "server_metadata",
            kind: .metadata(MetadataPreviewSpec(
                image: image,
                aspectRatio: aspectRatio(for: image, fallback: 2.0 / 3.0),
                forcedPreviewAspectRatio: isSquare ? 1.0 : nil,
                sizeScale: isSquare ? 0.92 : 0.75,
                title: item.kind == .episode ? (item.showTitle ?? item.title) : item.title,
                description: (overview?.isEmpty ?? true) ? nil : (item.kind == .episode && item.showTitle != nil ? "\(item.title)\n\(overview ?? "")" : overview),
                lines: lines,
                baseIconSize: iconSize,
                offsetX: isSquare ? musicGapPreviewHorizontalOffset - 56 : movieGapPreviewHorizontalOffset,
                offsetY: isSquare ? gapContentVerticalOffset - 8 : gapContentVerticalOffset + 8,
                identity: "server:\(item.id)",
                transitionDelay: item.isVideo || item.kind == .show ? 3 : 0,
                animatesTransition: item.isVideo || item.kind == .show,
            )),
            animation: animation,
            transition: animation,
            fade: .easeInOut(duration: 0.22),
        ))
        return items
    }
}
