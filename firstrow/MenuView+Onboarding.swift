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
    /// Touch controls (iPhone and iPad) or the mouse (computers), where there's one to use.
    case controls
}

/// The screens First Row opens with the first time: pick a look (Classic on the left, picked out
/// to start with, or Modern on the right), then, where there's a mouse or a touch screen, whether
/// to use it. Arrows and Select, the pointer or a finger all work, whatever the settings.
extension MenuView {
    /// Whether there's a pointing choice to offer after the look.
    static var onboardingOffersControls: Bool {
        #if os(tvOS)
            false
        #else
            true
        #endif
    }

    func beginOnboardingIfNeeded() {
        guard !AppSettings.hasCompletedOnboarding else { return }
        // Test runs go straight to the menus, unless they're testing this.
        if FirstRowHarness.isActive, ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_ONBOARDING"] != "1" { return }
        onboardingFocus = 0
        onboardingOpacity = 1
        onboardingContentOpacity = 1
        onboardingStep = .theme
        setOnboardingTakesTouches(true)
    }

    // MARK: - Input

    func handleOnboardingKey(_ key: KeyCode, isRepeat: Bool) {
        guard !isOnboardingTransitioning, onboardingStep != nil else { return }
        registerUserInteractionForScreenSaver()
        switch key {
        case .leftArrow:
            moveOnboardingFocus(to: 0)
        case .rightArrow:
            moveOnboardingFocus(to: 1)
        case .enter, .space:
            if !isRepeat { chooseOnboardingOption(onboardingFocus) }
        case .escape, .delete:
            // Back to the look from the second screen; nothing to go back to from the first.
            if onboardingStep == .controls {
                playSound(named: "Exit")
                showOnboardingStep(.theme, focus: AppSettings.theme == .modern ? 1 : 0)
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        default:
            break
        }
    }

    func handleOnboardingPointer(_ event: PointerEvent) {
        guard !isOnboardingTransitioning else { return }
        let option = pointer.hitTester?.onboardingOption(at: event.location)
        switch event {
        case .moved:
            if let option { moveOnboardingFocus(to: option) }
        case let .pressed(button, _):
            onboardingPressedOption = button == .primary ? option : nil
        case let .released(button, _):
            defer { onboardingPressedOption = nil }
            guard button == .primary, let option, option == onboardingPressedOption else { return }
            moveOnboardingFocus(to: option)
            chooseOnboardingOption(option)
        case .scrolled:
            break
        }
    }

    #if os(iOS)
        func handleOnboardingTouch(_ phase: TouchPhase, at point: CGPoint) {
            guard !isOnboardingTransitioning else { return }
            let option = pointer.hitTester?.onboardingOption(at: point)
            switch phase {
            case .began:
                onboardingPressedOption = option
                if let option { moveOnboardingFocus(to: option) }
            case .moved:
                if option != onboardingPressedOption { onboardingPressedOption = nil }
            case .ended:
                defer { onboardingPressedOption = nil }
                guard let option, option == onboardingPressedOption else { return }
                noteInputSource(.touch)
                chooseOnboardingOption(option)
            case .cancelled:
                onboardingPressedOption = nil
            }
        }
    #endif

    // MARK: - Moving on

    private func moveOnboardingFocus(to option: Int) {
        guard option != onboardingFocus else { return }
        playSound(named: "SelectionChange")
        withAnimation(.smooth(duration: 0.3)) {
            onboardingFocus = option
        }
    }

    private func chooseOnboardingOption(_ option: Int) {
        guard let step = onboardingStep else { return }
        playSound(named: "Selection")
        switch step {
        case .theme:
            let theme: InterfaceTheme = option == 1 ? .modern : .classic
            if AppSettings.theme != theme { AppSettings.theme = theme }
            if Self.onboardingOffersControls {
                showOnboardingStep(.controls, focus: onboardingControlsEnabled ? 1 : 0)
            } else {
                finishOnboarding()
            }
        case .controls:
            #if os(iOS)
                AppSettings.isTouchEnabled = option == 1
                noteInputSource(option == 1 ? .touch : .keyboard)
            #elseif !os(tvOS)
                AppSettings.isMouseEnabled = option == 1
                noteInputSource(option == 1 ? .pointer : .keyboard)
            #endif
            finishOnboarding()
        }
    }

    /// Whether touch (iPhone and iPad) or the mouse (computers) is on now.
    private var onboardingControlsEnabled: Bool {
        #if os(iOS)
            AppSettings.isTouchEnabled
        #elseif os(tvOS)
            false
        #else
            AppSettings.isMouseEnabled
        #endif
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

    /// Done: the menus come up from behind.
    private func finishOnboarding() {
        AppSettings.hasCompletedOnboarding = true
        isOnboardingTransitioning = true
        withAnimation(.smoothInOut(duration: 0.6)) {
            onboardingOpacity = 0
        }
        Task { @MainActor in
            try? await firstRowSleep(0.65)
            onboardingStep = nil
            isOnboardingTransitioning = false
            setOnboardingTakesTouches(false)
            resetScreenSaverIdleTimer()
        }
    }

    /// While the screens are up, a finger picks an option directly, whatever the touch setting.
    private func setOnboardingTakesTouches(_ takes: Bool) {
        #if os(iOS)
            TouchNavigationInputView.takesDirectTouch = takes
        #endif
    }

    // MARK: - What the screens say

    struct OnboardingOption {
        let title: String
        /// A symbol to draw large on the card (the look screen draws pictures of the looks).
        let symbol: String?
    }

    var onboardingTitle: String {
        switch onboardingStep {
        case .controls:
            #if os(iOS)
                "Touch Controls"
            #else
                "Mouse Controls"
            #endif
        default:
            "Welcome to First Row"
        }
    }

    var onboardingSubtitle: String {
        switch onboardingStep {
        case .controls:
            #if os(iOS)
                "Touch rows and buttons directly, or use gestures like a remote. You can change this in Settings."
            #else
                "Point, click and scroll, with on-screen buttons. You can change this later in Settings."
            #endif
        default:
            "Choose how First Row looks. You can change this later in Settings."
        }
    }

    var onboardingOptions: [OnboardingOption] {
        switch onboardingStep {
        case .controls:
            #if os(iOS)
                [OnboardingOption(title: "Gestures", symbol: "hand.draw.fill"), OnboardingOption(title: "Touch", symbol: "hand.tap.fill")]
            #else
                [OnboardingOption(title: "Keyboard and Remote", symbol: "keyboard"), OnboardingOption(title: "Mouse", symbol: "computermouse.fill")]
            #endif
        default:
            [OnboardingOption(title: InterfaceTheme.classic.title, symbol: nil), OnboardingOption(title: InterfaceTheme.modern.title, symbol: nil)]
        }
    }
}
