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
    case tab = 48
}

/// Where the last input came from. Hints for pointing and touching (the faint bars) stay
/// away while the keyboard or the old Apple Remote is in use, which can't use them.
enum MenuInputSource {
    case keyboard
    /// The white or aluminium infrared Apple Remote.
    case appleRemote
    case siriRemote
    case pointer
    case touch
}

extension MenuView {
    /// Notes the input that just came in, for the hints that depend on it.
    func noteInputSource(_ source: MenuInputSource) {
        if lastInputSource != source { lastInputSource = source }
    }

    /// The pointing and touching hints (the faint bars, the on-screen buttons) are for the
    /// pointer and fingers: a key or any remote puts them away until the pointer moves or a
    /// finger touches again.
    var showsPointingHints: Bool {
        lastInputSource == .pointer || lastInputSource == .touch
    }

    /// There are round on-screen buttons (Back, the transports) for fingers and the pointer:
    /// everywhere but Apple TV. They show while `showsPointingHints` does.
    var showsOnScreenControls: Bool {
        #if os(tvOS)
            false
        #else
            true
        #endif
    }

    /// `willBeLetGo` for a key whose release will be told of too (`handleKeyUp`): Return can
    /// then be held on a movie to ask about deleting it, and acts as a press when it's let go.
    func handleKeyDown(_ key: KeyCode, isRepeat: Bool = false, modifiers: NSEvent.ModifierFlags = [], willBeLetGo: Bool = false) {
        // The file picker is answering keys of its own.
        if isChoosingMediaSource { return }
        if key == .enter, willBeLetGo, onboardingStep == nil, !isTextEntryActive {
            if isRepeat, isConfirmPressDown { return }
            if !isRepeat, confirmPressBegan() { return }
        }
        if onboardingStep != nil {
            handleOnboardingKey(key, isRepeat: isRepeat)
            return
        }
        if key == .upArrow || key == .downArrow || key == .leftArrow || key == .rightArrow {
            if isRepeat { return }
            handleDirectionalPressBegan(key, modifiers: modifiers)
            return
        }
        endDirectionalHoldSession()
        handleKeyInput(key, isRepeat: isRepeat, modifiers: modifiers)
    }

    func handleKeyUp(_ key: KeyCode) {
        if key == .enter { confirmPressEnded() }
        handleDirectionalPressEnded(key)
    }

    /// Called once the menus are on screen.
    func start() {
        beginOnboardingIfNeeded()
        beginStartupMusicLibraryPreloadIfNeeded()
        preloadITunesTopChartsInBackground()
        registerUserInteractionForScreenSaver()
        startScreenSaverIdleMonitor()
        pauseScreenSaverIdleWhileInBackground()
        startupSoundWarmUpWorkItem?.cancel()
        startupSoundWarmUpWorkItem = Task {
            try? await firstRowSleep(0.75)
            guard !Task.isCancelled else { return }
            SoundEffectPlayer.shared.warmUp(soundNames: ["Selection", "SelectionChange", "Exit", "Limit"].map(Self.themedSoundName))
        }
    }

    func stop() {
        startupSoundWarmUpWorkItem?.cancel()
        startupSoundWarmUpWorkItem = nil
        endDirectionalHoldSession()
        stopScreenSaverIdleMonitor()
    }
}
