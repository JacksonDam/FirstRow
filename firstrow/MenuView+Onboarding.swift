import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// The first-launch screens.
enum OnboardingStep: Equatable {
    /// Classic or Modern.
    case theme
    /// How to get about, and Get Started.
    case guide
}

/// The screens First Row opens with the first time: pick a look (Classic on the left, picked out
/// to start with, or Modern on the right; the screens take on the look picked out as it moves),
/// then how to get about. Arrows and Select, the pointer or a finger all work. On a foldable
/// standing upright Classic is above the fold and Modern below it.
extension MenuView {
    func beginOnboardingIfNeeded() {
        // Test runs go straight to the menus, unless they're testing this (then it always shows).
        let testing = FirstRowHarness.isActive && ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_ONBOARDING"] == "1"
        if FirstRowHarness.isActive, !testing { return }
        guard testing || !AppSettings.hasCompletedOnboarding else { return }
        onboardingFocus = 0
        onboardingOpacity = 1
        onboardingContentOpacity = 1
        onboardingStep = .theme
        // Classic, picked out to start with, is the look until another is picked out.
        if AppSettings.theme != .classic { AppSettings.theme = .classic }
    }

    /// The look the screens wear: the one picked out on the first, the one chosen after it.
    var onboardingLook: InterfaceTheme {
        AppSettings.theme
    }

    /// The step before this one, if there's one to go back to.
    private var previousOnboardingStep: OnboardingStep? {
        onboardingStep == .guide ? .theme : nil
    }

    /// The option picked out on returning to a step: what was chosen there.
    private func onboardingFocus(for step: OnboardingStep) -> Int {
        switch step {
        case .theme: AppSettings.theme == .modern ? 1 : 0
        case .guide: 0
        }
    }

    // MARK: - Input

    func handleOnboardingKey(_ key: KeyCode, isRepeat: Bool) {
        guard !isOnboardingTransitioning, let step = onboardingStep else { return }
        registerUserInteractionForScreenSaver()
        switch key {
        case .leftArrow where step != .guide:
            moveOnboardingFocus(to: 0)
        case .rightArrow where step != .guide:
            moveOnboardingFocus(to: 1)
        case .upArrow where step != .guide && upright != nil:
            moveOnboardingFocus(to: 0)
        case .downArrow where step != .guide && upright != nil:
            moveOnboardingFocus(to: 1)
        case .enter, .space:
            if !isRepeat { chooseOnboardingOption(onboardingFocus) }
        case .escape, .delete:
            goBackInOnboarding()
        default:
            break
        }
    }

    /// Back a screen (Menu, Escape, or the Back button); there's nothing before the first.
    private func goBackInOnboarding() {
        guard let previous = previousOnboardingStep else {
            playLimitSoundOnceForCurrentHold()
            return
        }
        playSound(named: "Exit")
        showOnboardingStep(previous, focus: onboardingFocus(for: previous))
    }

    func handleOnboardingPointer(_ event: PointerEvent) {
        guard !isOnboardingTransitioning else { return }
        let control = pointer.hitTester?.touchControl(at: event.location)
        let option = control == nil ? pointer.hitTester?.onboardingOption(at: event.location) : nil
        switch event {
        case .moved:
            if let option { moveOnboardingFocus(to: option) }
        case let .pressed(button, _):
            if button == .back {
                goBackInOnboarding()
                return
            }
            onboardingPressedOption = button == .primary ? option : nil
            onboardingPressedControl = button == .primary ? control : nil
            pointer.hitTester?.highlightTouchControl(onboardingPressedControl)
        case let .released(button, _):
            defer {
                onboardingPressedOption = nil
                onboardingPressedControl = nil
            }
            pointer.hitTester?.highlightTouchControl(nil)
            guard button == .primary else { return }
            if let control, control == onboardingPressedControl {
                pressOnScreenControl(control)
                return
            }
            guard let option, option == onboardingPressedOption else { return }
            moveOnboardingFocus(to: option)
            chooseOnboardingOption(option)
        case .scrolled:
            break
        }
    }

    #if os(iOS)
        func handleOnboardingTouch(_ phase: TouchPhase, at point: CGPoint) {
            guard !isOnboardingTransitioning else { return }
            let control = pointer.hitTester?.touchControl(at: point)
            let option = control == nil ? pointer.hitTester?.onboardingOption(at: point) : nil
            switch phase {
            case .began:
                onboardingPressedControl = control
                onboardingPressedOption = option
                pointer.hitTester?.highlightTouchControl(control)
                if let option { moveOnboardingFocus(to: option) }
            case .moved:
                if option != onboardingPressedOption { onboardingPressedOption = nil }
                if control != onboardingPressedControl {
                    pointer.hitTester?.highlightTouchControl(nil)
                }
            case .ended:
                defer {
                    onboardingPressedOption = nil
                    onboardingPressedControl = nil
                }
                pointer.hitTester?.highlightTouchControl(nil)
                if let control, control == onboardingPressedControl {
                    pressOnScreenControl(control)
                    return
                }
                guard let option, option == onboardingPressedOption else { return }
                chooseOnboardingOption(option)
            case .cancelled:
                onboardingPressedOption = nil
                onboardingPressedControl = nil
                pointer.hitTester?.highlightTouchControl(nil)
            }
        }
    #endif

    // MARK: - Moving on

    private func moveOnboardingFocus(to option: Int) {
        guard option != onboardingFocus, onboardingStep != .guide else { return }
        withAnimation(.smooth(duration: 0.3)) {
            onboardingFocus = option
        }
        // On the first screen the look itself changes with the option picked out (and its sounds
        // with it), so the screens show what it's like.
        if onboardingStep == .theme {
            let theme: InterfaceTheme = option == 1 ? .modern : .classic
            if AppSettings.theme != theme {
                withAnimation(.smoothInOut(duration: 0.45)) {
                    AppSettings.theme = theme
                    objectWillChange.send()
                }
            }
        }
        playSound(named: "SelectionChange")
    }

    private func chooseOnboardingOption(_ option: Int) {
        guard let step = onboardingStep else { return }
        playSound(named: "Selection")
        switch step {
        case .theme:
            let theme: InterfaceTheme = option == 1 ? .modern : .classic
            if AppSettings.theme != theme { AppSettings.theme = theme }
            showOnboardingStep(.guide, focus: 0)
        case .guide:
            finishOnboarding()
        }
    }

    /// Fades one screen's contents out and the next one's in.
    private func showOnboardingStep(_ step: OnboardingStep, focus: Int) {
        isOnboardingTransitioning = true
        withAnimation(.smoothInOut(duration: 0.22)) {
            onboardingContentOpacity = 0
        }
        Task { @MainActor in
            try? await firstRowSleep(0.24)
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                onboardingStep = step
                onboardingFocus = focus
            }
            withAnimation(.smooth(duration: 0.34)) {
                onboardingContentOpacity = 1
            }
            isOnboardingTransitioning = false
        }
    }

    /// Done: the screens fade to black and the look's intro movie plays, the menus coming in on its
    /// hit (or, with no movie, the menus come up from behind).
    private func finishOnboarding() {
        AppSettings.hasCompletedOnboarding = true
        isOnboardingTransitioning = true
        if onOnboardingFinished?() != true {
            withAnimation(.smoothInOut(duration: 0.6)) {
                onboardingOpacity = 0
            }
        }
        Task { @MainActor in
            try? await firstRowSleep(0.65)
            onboardingStep = nil
            isOnboardingTransitioning = false
            resetScreenSaverIdleTimer()
        }
    }

    // MARK: - What the screens say

    struct OnboardingOption {
        let title: String
    }

    /// A line of the controls screen: a symbol and what to do.
    struct OnboardingTip {
        let symbol: String
        let text: String
    }

    var onboardingTitle: String {
        switch onboardingStep {
        case .guide:
            "Getting Around"
        default:
            "Welcome to First Row"
        }
    }

    var onboardingSubtitle: String {
        switch onboardingStep {
        case .guide:
            onboardingGuideSubtitle
        default:
            "Choose how First Row looks. You can change this later in Settings."
        }
    }

    var onboardingOptions: [OnboardingOption] {
        switch onboardingStep {
        case .guide:
            []
        default:
            [OnboardingOption(title: InterfaceTheme.classic.title), OnboardingOption(title: InterfaceTheme.modern.title)]
        }
    }

    private var onboardingGuideSubtitle: String {
        #if os(iOS)
            "With touch"
        #elseif os(tvOS)
            "With the Siri Remote"
        #else
            "With the mouse, the keyboard or a remote"
        #endif
    }

    /// How to quit, in this system's keys.
    private static var quitShortcutText: String {
        #if os(macOS)
            "Press Command-Esc to quit"
        #else
            "Press Ctrl-Esc or Ctrl-Q to quit"
        #endif
    }

    /// The controls, for this device's ways of getting about.
    var onboardingTips: [OnboardingTip] {
        #if os(iOS)
            return [
                OnboardingTip(symbol: "hand.tap.fill", text: "Tap a row to open it"),
                OnboardingTip(symbol: "arrow.up.and.down", text: "Drag a list to scroll it; hold and slide to move through it"),
                OnboardingTip(symbol: "chevron.left", text: "Tap Back at the top left, or swipe in from the left edge, to go back"),
                OnboardingTip(symbol: "music.note.list", text: "In Now Playing, swipe in from the right edge for the song list"),
                OnboardingTip(symbol: "play.fill", text: "In a movie, tap to show its controls"),
            ]
        #elseif os(tvOS)
            return [
                OnboardingTip(symbol: "hand.draw.fill", text: "Swipe or click the edges of the clickpad to move"),
                OnboardingTip(symbol: "circle.fill", text: "Click the centre to choose"),
                OnboardingTip(symbol: "chevron.left", text: "Press Back to go back"),
                OnboardingTip(symbol: "playpause.fill", text: "Press Play/Pause to play or pause"),
                OnboardingTip(symbol: "captions.bubble", text: "In a movie, swipe down for subtitles, audio and speed"),
            ]
        #else
            return [
                OnboardingTip(symbol: "cursorarrow", text: "Click a row, or move with the arrows and choose with Return"),
                OnboardingTip(symbol: "chevron.left", text: "Click Back, or press Esc or the remote's Menu, to go back"),
                OnboardingTip(symbol: "playpause.fill", text: "Space or Play/Pause to play or pause"),
                OnboardingTip(symbol: "arrow.left.and.right", text: "Left and right to skip, or hold to scrub"),
                OnboardingTip(symbol: "xmark", text: Self.quitShortcutText),
            ]
        #endif
    }
}
