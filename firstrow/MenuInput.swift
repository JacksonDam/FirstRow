import Foundation
#if os(macOS)
    import AppKit
#else
    enum NSEvent {
        struct ModifierFlags: OptionSet {
            let rawValue: Int
            static let command = ModifierFlags(rawValue: 1 << 0)
        }
    }
#endif

enum KeyCode: UInt16 {
    case none = 0
    case space = 49
    case leftArrow = 123
    case rightArrow = 124
    case upArrow = 126
    case downArrow = 125
    case enter = 36
    case escape = 53
    case delete = 51
}

extension MenuView {
    func handleKeyDown(_ key: KeyCode, isRepeat: Bool = false, modifiers: NSEvent.ModifierFlags = []) {
        // The file picker is answering keys of its own.
        if isChoosingMediaSource { return }
        if key == .upArrow || key == .downArrow || key == .leftArrow || key == .rightArrow {
            if isRepeat { return }
            handleDirectionalPressBegan(key, modifiers: modifiers)
            return
        }
        endDirectionalHoldSession()
        handleKeyInput(key, isRepeat: isRepeat, modifiers: modifiers)
    }

    func handleKeyUp(_ key: KeyCode) {
        handleDirectionalPressEnded(key)
    }

    /// Called once the menus are on screen.
    func start() {
        beginStartupMusicLibraryPreloadIfNeeded()
        preloadITunesTopChartsInBackground()
        registerUserInteractionForScreenSaver()
        startScreenSaverIdleMonitor()
        startupSoundWarmUpWorkItem?.cancel()
        startupSoundWarmUpWorkItem = Task {
            try? await firstRowSleep(0.75)
            guard !Task.isCancelled else { return }
            SoundEffectPlayer.shared.warmUp(soundNames: ["Selection", "SelectionChange", "Exit", "Limit"])
        }
    }

    func stop() {
        startupSoundWarmUpWorkItem?.cancel()
        startupSoundWarmUpWorkItem = nil
        endDirectionalHoldSession()
        stopScreenSaverIdleMonitor()
    }
}
