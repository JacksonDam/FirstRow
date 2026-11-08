import Foundation

/// The Settings menu's own rows, and the Screen Saver page.
extension MenuView {
    static let settingsThemeItemID = "settings_theme"
    static let settingsMouseItemID = "settings_mouse"
    static let settingsTouchItemID = "settings_touch"
    static let settingsScreenSaverItemID = "settings_screensaver"
    static let settingsSoundEffectsItemID = "settings_soundeffects"
    private static let screenSaverPreviewItemID = "screensaver_preview"
    private static let screenSaverChoicePrefix = "screensaver_after_"

    /// What a Settings row shows on its right, or nil for rows that keep their own.
    func settingsTrailingText(forItemID id: String) -> String? {
        switch id {
        case Self.settingsSoundEffectsItemID: isUISoundEffectsEnabled ? "On" : "Off"
        case Self.settingsScreenSaverItemID: AppSettings.screenSaverDelayTitle(AppSettings.screenSaverDelay)
        case Self.settingsThemeItemID: AppSettings.theme.title
        case Self.settingsMouseItemID: AppSettings.isMouseEnabled ? "On" : "Off"
        case Self.settingsTouchItemID: AppSettings.isTouchEnabled ? "On" : "Off"
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
        case Self.settingsMouseItemID:
            AppSettings.isMouseEnabled.toggle()
            objectWillChange.send()
            playSound(named: "Selection")
        case Self.settingsTouchItemID:
            AppSettings.isTouchEnabled.toggle()
            pointer.clearPin()
            isTouchSelecting = false
            objectWillChange.send()
            playSound(named: "Selection")
        default:
            return false
        }
        return true
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
            self.headerText = "Screen Saver"
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
    }

    func screenSaverSettingsListItems() -> [MenuListItemConfig] {
        let current = AppSettings.screenSaverDelay
        var items = [plainMenuListItem(id: Self.screenSaverPreviewItemID, title: "Preview")]
        for (index, seconds) in AppSettings.screenSaverDelayChoices.enumerated() {
            let title = seconds > 0 ? "Start After \(AppSettings.screenSaverDelayTitle(seconds))" : "Never Start"
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
