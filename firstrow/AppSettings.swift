import Foundation

/// How the menus look: the original glossy style, or the flat style of today's Apple TV.
enum InterfaceTheme: String, CaseIterable {
    case classic
    case modern

    var title: String {
        switch self {
        case .classic: L("Classic")
        case .modern: L("Modern")
        }
    }
}

/// Settings that more than the menus read (the renderer, sounds, input).
enum AppSettings {
    /// Posted on the main thread when one of these settings changes.
    static let didChangeNotification = Notification.Name("FirstRowSettingsDidChange")

    private static let themeKey = "interfaceTheme"
    private static let screenSaverDelayKey = "screenSaverStartAfterSeconds"
    private static let onboardingKey = "hasCompletedOnboarding"
    private static let introMovieKey = "introMovieEnabled"
    private static let youtubeKey = "showsYouTube"
    private static let legacyScreenSaverKey = "isScreenSaverEnabled"

    /// The look in use. It's asked for dozens of times in every pass over the interface, so
    /// it's remembered here, not read from the settings store each time.
    static var theme: InterfaceTheme {
        get {
            themeLock.lock()
            defer { themeLock.unlock() }
            if let rememberedTheme { return rememberedTheme }
            let stored = UserDefaults.standard.string(forKey: themeKey).flatMap(InterfaceTheme.init(rawValue:)) ?? .classic
            rememberedTheme = stored
            return stored
        }
        set {
            themeLock.lock()
            rememberedTheme = newValue
            themeLock.unlock()
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    private static let themeLock = NSLock()
    nonisolated(unsafe) private static var rememberedTheme: InterfaceTheme?
    nonisolated(unsafe) private static var rememberedScreenSaverDelay: TimeInterval?

    /// The first-launch screens (the look, then how to get about) have been gone through.
    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingKey) }
    }

    /// The look's intro movie plays every time First Row opens (it always plays once, after the
    /// first-launch screens). On until it's turned off, which covers anyone coming from a
    /// version that had no such setting.
    static var playsIntroMovieAtLaunch: Bool {
        get { UserDefaults.standard.object(forKey: introMovieKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: introMovieKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// YouTube is on the main menu. Off until it's turned on in Settings.
    static var showsYouTube: Bool {
        get { UserDefaults.standard.bool(forKey: youtubeKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: youtubeKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// The idle time before the screen saver starts; 0 means never.
    static var screenSaverDelay: TimeInterval {
        get {
            // (Kept in memory like the look: the idle monitor asks every second.)
            themeLock.lock()
            defer { themeLock.unlock() }
            if let rememberedScreenSaverDelay { return rememberedScreenSaverDelay }
            let stored: TimeInterval
            if let seconds = UserDefaults.standard.object(forKey: screenSaverDelayKey) as? Double {
                stored = max(0, seconds)
            } else {
                // Before 2.0 the screen saver was on (after a minute) or off.
                let wasEnabled = UserDefaults.standard.object(forKey: legacyScreenSaverKey) as? Bool ?? true
                stored = wasEnabled ? 60 : 0
            }
            rememberedScreenSaverDelay = stored
            return stored
        }
        set {
            themeLock.lock()
            rememberedScreenSaverDelay = max(0, newValue)
            themeLock.unlock()
            UserDefaults.standard.set(max(0, newValue), forKey: screenSaverDelayKey)
            UserDefaults.standard.set(newValue > 0, forKey: legacyScreenSaverKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// The choices Settings > Screen Saver offers, in seconds (0 = never).
    static let screenSaverDelayChoices: [TimeInterval] = [0, 60, 120, 300, 600, 900, 1800, 3600]

    static func screenSaverDelayTitle(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return L("Never") }
        if seconds >= 3600 {
            let hours = Int((seconds / 3600).rounded())
            return hours == 1 ? L("1 Hour") : L("%@ Hours", hours)
        }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? L("1 Minute") : L("%@ Minutes", minutes)
    }
}
