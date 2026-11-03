import Foundation
#if os(macOS)
    import AppKit
    import UniformTypeIdentifiers
#endif

/// Settings > Media Folders: the folders, iTunes library file and iPhoto library First Row
/// reads besides the standard libraries, managed from the menus like everything else.
///
/// The pages stack up inside the third-level menu: the list of kinds, then the folders of
/// one kind (with "Add Folder…"), then what can be done with one folder or library. Back
/// (Escape, Delete, Menu) goes up a page.
extension MenuView {
    enum MediaFoldersPage: Equatable {
        case overview
        case folders(MediaSources.FolderKind)
        case folder(MediaSources.FolderKind, index: Int)
        case library(MediaSources.LibraryKind)
    }

    struct MediaFoldersPageState: Equatable {
        var page: MediaFoldersPage
        var selectedIndex: Int
    }

    static let mediaFoldersItemID = "settings_media_folders"

    var currentMediaFoldersPage: MediaFoldersPage {
        mediaFoldersPages.last?.page ?? .overview
    }

    // MARK: - Rows

    func mediaFoldersListItems() -> [MenuListItemConfig] {
        _ = mediaSourcesRevision
        let sources = MediaSources.shared
        switch currentMediaFoldersPage {
        case .overview:
            var items = MediaSources.FolderKind.allCases.map { kind in
                plainMenuListItem(id: "media_kind_\(kind.rawValue)", title: kind.title, leadsToMenu: true, trailingText: "(\(sources.folderEntries(kind).count))")
            }
            for (index, kind) in MediaSources.LibraryKind.allCases.enumerated() {
                let name = sources.library(kind) == nil ? "Off" : "On"
                items.append(.init(
                    id: "media_library_\(kind.rawValue)",
                    title: kind.title,
                    leadsToMenu: true,
                    leadingImageAssetName: nil,
                    leadingImage: nil,
                    trailingText: name,
                    trailingSymbolName: nil,
                    showsTopDivider: index == 0,
                    showsBlueDot: false,
                    showsLightRowBackground: false,
                    alignsTextToDividerStart: false,
                ))
            }
            return items
        case let .folders(kind):
            let entries = sources.folderEntries(kind)
            var items = entries.enumerated().map { index, entry in
                plainMenuListItem(
                    id: "media_folder_\(index)",
                    title: entry.url.map { FileManager.default.displayName(atPath: $0.path) } ?? URL(fileURLWithPath: entry.displayPath).lastPathComponent,
                    leadsToMenu: true,
                    trailingText: entry.url == nil ? "Not Found" : nil,
                )
            }
            items.append(.init(
                id: "media_add_folder",
                title: "Add Folder",
                leadsToMenu: false,
                leadingImageAssetName: nil,
                leadingImage: nil,
                trailingText: "...",
                trailingSymbolName: nil,
                showsTopDivider: !entries.isEmpty,
                showsBlueDot: false,
                showsLightRowBackground: false,
                alignsTextToDividerStart: false,
            ))
            return items
        case .folder:
            return [plainMenuListItem(id: "media_remove_folder", title: "Remove from First Row")]
        case let .library(kind):
            if sources.library(kind) != nil {
                return [
                    plainMenuListItem(id: "media_choose_library", title: kind.chooseAnotherTitle, trailingText: "..."),
                    plainMenuListItem(id: "media_clear_library", title: "Stop Using It"),
                ]
            }
            return [plainMenuListItem(id: "media_choose_library", title: kind.chooseTitle, trailingText: "...")]
        }
    }

    func mediaFoldersHeaderTitle(for page: MediaFoldersPage) -> String {
        switch page {
        case .overview:
            "Media Folders"
        case let .folders(kind):
            "\(kind.title) Folders"
        case let .folder(kind, index):
            truncatedHeaderTitle(MediaSources.shared.folderEntries(kind).indices.contains(index)
                ? URL(fileURLWithPath: MediaSources.shared.folderEntries(kind)[index].displayPath).lastPathComponent
                : "\(kind.title) Folder", fallback: "\(kind.title) Folder")
        case let .library(kind):
            kind.title
        }
    }

    // MARK: - Moving between pages

    /// Settings > Media Folders.
    func enterMediaFoldersMenu() {
        transitionMenuForFolderSwap {
            self.thirdMenuMode = .mediaFolders
            self.isInThirdMenu = true
            self.mediaFoldersPages = [MediaFoldersPageState(page: .overview, selectedIndex: 0)]
            self.selectedThirdIndex = 0
            self.headerText = self.mediaFoldersHeaderTitle(for: .overview)
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
    }

    private func pushMediaFoldersPage(_ page: MediaFoldersPage) {
        transitionMenuForFolderSwap {
            if var current = self.mediaFoldersPages.popLast() {
                current.selectedIndex = self.selectedThirdIndex
                self.mediaFoldersPages.append(current)
            }
            self.mediaFoldersPages.append(MediaFoldersPageState(page: page, selectedIndex: 0))
            self.selectedThirdIndex = 0
            self.headerText = self.mediaFoldersHeaderTitle(for: page)
        }
    }

    /// Back from a page: to the page before it, or out to Settings from the first one.
    func navigateUpInMediaFolders() {
        guard mediaFoldersPages.count > 1 else {
            exitMediaFoldersToSettings()
            return
        }
        transitionMenuForFolderSwap {
            self.mediaFoldersPages.removeLast()
            let previous = self.mediaFoldersPages.last ?? MediaFoldersPageState(page: .overview, selectedIndex: 0)
            self.selectedThirdIndex = min(previous.selectedIndex, max(0, self.mediaFoldersListItems().count - 1))
            self.headerText = self.mediaFoldersHeaderTitle(for: previous.page)
        }
    }

    private func exitMediaFoldersToSettings() {
        transitionMenuForFolderSwap {
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.mediaFoldersPages = []
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
        }
    }

    // MARK: - Actions

    func triggerMediaFoldersAction() {
        let items = mediaFoldersListItems()
        guard items.indices.contains(selectedThirdIndex) else { return }
        let item = items[selectedThirdIndex]
        switch currentMediaFoldersPage {
        case .overview:
            if let kind = MediaSources.FolderKind.allCases.first(where: { item.id == "media_kind_\($0.rawValue)" }) {
                pushMediaFoldersPage(.folders(kind))
            } else if let kind = MediaSources.LibraryKind.allCases.first(where: { item.id == "media_library_\($0.rawValue)" }) {
                pushMediaFoldersPage(.library(kind))
            }
        case let .folders(kind):
            if item.id == "media_add_folder" {
                chooseMediaFolders(kind)
            } else {
                pushMediaFoldersPage(.folder(kind, index: selectedThirdIndex))
            }
        case let .folder(kind, index):
            MediaSources.shared.removeFolder(at: index, kind: kind)
            mediaSourcesRevision &+= 1
            navigateUpInMediaFolders()
        case let .library(kind):
            if item.id == "media_clear_library" {
                MediaSources.shared.setLibrary(nil, kind: kind)
                mediaSourcesRevision &+= 1
                navigateUpInMediaFolders()
            } else {
                chooseMediaLibrary(kind)
            }
        }
    }

    /// Command-comma: Settings > Media Folders, from the main menu or the Settings menu.
    func showMediaFoldersFromShortcut() {
        guard activeFullscreenScene == nil, !isMoviePlaybackVisible, !isMovieResumePromptVisible,
              !isMenuFolderSwapTransitioning, !isFullscreenSceneTransitioning
        else { return }
        if thirdMenuMode == .mediaFolders { return }
        if activeRootItemID == "settings", isInSubmenu, !isInThirdMenu, !isEnteringSubmenu {
            if let index = currentSubmenuItems().firstIndex(where: { $0.id == Self.mediaFoldersItemID }) {
                withTransaction(.instant) { selectedSubIndex = index }
            }
            playSound(named: "Selection")
            enterMediaFoldersMenu()
            return
        }
        guard !isInSubmenu, !isEnteringSubmenu, !isReturningToRoot,
              let settingsIndex = menuItems.firstIndex(where: { $0.id == "settings" })
        else { return }
        withTransaction(.instant) { selectedIndex = settingsIndex }
        playSound(named: "Selection")
        startSubmenuTransition()
        Task { @MainActor in
            try? await firstRowSleep(iconFlightAnimationDuration + 0.35)
            guard activeRootItemID == "settings", isInSubmenu, !isInThirdMenu else { return }
            if let index = currentSubmenuItems().firstIndex(where: { $0.id == Self.mediaFoldersItemID }) {
                selectedSubIndex = index
            }
            enterMediaFoldersMenu()
        }
    }

    // MARK: - Choosing files

    private func chooseMediaFolders(_ kind: MediaSources.FolderKind) {
        #if os(macOS)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.prompt = "Add"
            panel.message = "Choose folders of \(kind.title.lowercased()) for First Row."
            presentMediaSourcePanel(panel) { [weak self] urls in
                guard let self, !urls.isEmpty else { return }
                for url in urls {
                    MediaSources.shared.addFolder(url, kind: kind)
                }
                self.mediaSourcesRevision &+= 1
            }
        #endif
    }

    private func chooseMediaLibrary(_ kind: MediaSources.LibraryKind) {
        #if os(macOS)
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            switch kind {
            case .iTunesXML:
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowedContentTypes = [.xml]
                panel.message = "Choose an iTunes library file (iTunes Music Library.xml or iTunes Library.xml). In iTunes or Music, File > Library > Export Library makes one."
            case .iPhoto:
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.treatsFilePackagesAsDirectories = false
                panel.message = "Choose your iPhoto Library."
            }
            panel.prompt = "Choose"
            presentMediaSourcePanel(panel) { [weak self] urls in
                guard let self, let url = urls.first else { return }
                MediaSources.shared.setLibrary(url, kind: kind)
                self.mediaSourcesRevision &+= 1
                self.navigateUpInMediaFolders()
            }
        #endif
    }

    #if os(macOS)
        /// Shows the system's file picker over First Row, with the pointer, until it's answered.
        private func presentMediaSourcePanel(_ panel: NSOpenPanel, completion: @escaping @MainActor ([URL]) -> Void) {
            guard !isChoosingMediaSource else { return }
            isChoosingMediaSource = true
            panel.level = .modalPanel
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            NSCursor.setHiddenUntilMouseMoves(false)
            panel.begin { [weak self] response in
                MainActor.assumeIsolatedIfPossible {
                    self?.isChoosingMediaSource = false
                    NSApplication.shared.windows.first { $0 is FirstRowWindow }?.makeKeyAndOrderFront(nil)
                    completion(response == .OK ? panel.urls : [])
                }
            }
        }
    #endif

    func truncatedHeaderTitle(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let maxWidth: CGFloat = 720
        guard FontMetrics.width(trimmed, fontName: firstRowBoldFontName, size: 60) > maxWidth else { return trimmed }
        var shortened = trimmed
        while !shortened.isEmpty, FontMetrics.width(shortened + "…", fontName: firstRowBoldFontName, size: 60) > maxWidth {
            shortened.removeLast()
        }
        return shortened.trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension MediaSources.LibraryKind {
    var title: String {
        switch self {
        case .iTunesXML: "iTunes Library"
        case .iPhoto: "iPhoto Library"
        }
    }

    var chooseTitle: String {
        switch self {
        case .iTunesXML: "Choose Library File"
        case .iPhoto: "Choose Library"
        }
    }

    var chooseAnotherTitle: String {
        switch self {
        case .iTunesXML: "Choose Another File"
        case .iPhoto: "Choose Another Library"
        }
    }
}
