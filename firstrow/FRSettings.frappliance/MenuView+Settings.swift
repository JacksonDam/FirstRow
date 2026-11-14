import Foundation

/// The Settings menu's own rows, and the Screen Saver page.
extension MenuView {
    static let settingsThemeItemID = "settings_theme"
    static let settingsScreenSaverItemID = "settings_screensaver"
    static let settingsSoundEffectsItemID = "settings_soundeffects"
    static let settingsIntroMovieItemID = "settings_intromovie"
    static let settingsYouTubeItemID = "settings_youtube"
    private static let screenSaverPreviewItemID = "screensaver_preview"
    private static let screenSaverChoicePrefix = "screensaver_after_"

    /// What a Settings row shows on its right, or nil for rows that keep their own.
    func settingsTrailingText(forItemID id: String) -> String? {
        switch id {
        case Self.settingsSoundEffectsItemID: isUISoundEffectsEnabled ? L("On") : L("Off")
        case Self.settingsScreenSaverItemID: AppSettings.screenSaverDelayTitle(AppSettings.screenSaverDelay)
        case Self.settingsThemeItemID: AppSettings.theme.title
        case Self.settingsIntroMovieItemID: AppSettings.playsIntroMovieAtLaunch ? L("On") : L("Off")
        case Self.settingsYouTubeItemID: AppSettings.showsYouTube ? L("On") : L("Off")
        default: nil
        }
    }

    /// Handles a Settings row that changes a setting. Returns false for rows handled elsewhere.
    func triggerSettingsItem(_ item: SubmenuItemConfig) -> Bool {
        switch item.id {
        case Self.settingsSoundEffectsItemID:
            isUISoundEffectsEnabled.toggle()
            playSound(named: "Selection")
        case Self.settingsScreenSaverItemID:
            playSound(named: "Selection")
            enterScreenSaverSettings()
        case Self.settingsThemeItemID:
            playSound(named: "Selection")
            switchTheme(to: AppSettings.theme == .classic ? .modern : .classic)
        case Self.settingsIntroMovieItemID:
            // The look's intro movie at every launch (it always plays after the first-launch screens).
            AppSettings.playsIntroMovieAtLaunch.toggle()
            objectWillChange.send()
            playSound(named: "Selection")
        case Self.settingsYouTubeItemID:
            setShowsYouTube(!AppSettings.showsYouTube)
            playSound(named: "Selection")
        default:
            return false
        }
        return true
    }

    /// Puts YouTube on the main menu or takes it off. The main menu's selection stays on the
    /// item it was on (Settings, where this is changed), whose place in the menu moves by one.
    func setShowsYouTube(_ shows: Bool) {
        let selectedID = menuItems.indices.contains(selectedIndex) ? menuItems[selectedIndex].id : nil
        AppSettings.showsYouTube = shows
        menuItems = Self.shownRootItems()
        if let index = menuItems.firstIndex(where: { $0.id == selectedID }), index != selectedIndex {
            withTransaction(.instant) { selectedIndex = index }
        }
        objectWillChange.send()
    }

    /// Fades to black, changes the look, and fades back in on the same row.
    func switchTheme(to theme: InterfaceTheme) {
        transitionMenuForFolderSwap(useOverlayFade: true) {
            AppSettings.theme = theme
            self.objectWillChange.send()
        }
    }

    // MARK: - Screen Saver page

    func enterScreenSaverSettings() {
        transitionMenuForFolderSwap {
            self.thirdMenuMode = .screenSaverSettings
            self.isInThirdMenu = true
            let choices = AppSettings.screenSaverDelayChoices
            let current = choices.firstIndex(of: AppSettings.screenSaverDelay) ?? 0
            // The rows are Preview, then one per choice.
            self.selectedThirdIndex = current + 1
            self.headerText = L("Screen Saver")
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
    }

    func screenSaverSettingsListItems() -> [MenuListItemConfig] {
        let current = AppSettings.screenSaverDelay
        var items = [plainMenuListItem(id: Self.screenSaverPreviewItemID, title: L("Preview"))]
        for (index, seconds) in AppSettings.screenSaverDelayChoices.enumerated() {
            let title = seconds > 0 ? L("Start After %@", AppSettings.screenSaverDelayTitle(seconds)) : L("Never Start")
            items.append(plainMenuListItem(
                id: Self.screenSaverChoicePrefix + String(Int(seconds)),
                title: title,
                trailingSymbolName: seconds == current ? "checkmark" : nil,
                showsTopDivider: index == 0,
            ))
        }
        return items
    }

    func triggerScreenSaverSettingsAction() {
        let items = screenSaverSettingsListItems()
        guard items.indices.contains(selectedThirdIndex) else { return }
        let id = items[selectedThirdIndex].id
        if id == Self.screenSaverPreviewItemID {
            presentFullscreenScene(key: screenSaverFullscreenKey)
            return
        }
        guard id.hasPrefix(Self.screenSaverChoicePrefix),
              let seconds = Double(id.dropFirst(Self.screenSaverChoicePrefix.count))
        else { return }
        AppSettings.screenSaverDelay = seconds
        resetScreenSaverIdleTimer()
        objectWillChange.send()
    }

    func exitScreenSaverSettings() {
        transitionMenuForFolderSwap {
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
        }
    }
}
