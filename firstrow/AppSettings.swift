import Foundation

/// How the menus look: the original glossy style, or the flat style of today's Apple TV.
enum InterfaceTheme: String, CaseIterable {
    case classic
    case modern

    var title: String {
        switch self {
        case .classic: "Classic"
        case .modern: "Modern"
        }
    }
}

/// Settings that more than the menus read (the renderer, sounds, input).
enum AppSettings {
    /// Posted on the main thread when one of these settings changes.
    static let didChangeNotification = Notification.Name("FirstRowSettingsDidChange")

    private static let themeKey = "interfaceTheme"
    private static let mouseKey = "isMouseEnabled"
    private static let touchKey = "isTouchEnabled"
    private static let screenSaverDelayKey = "screenSaverStartAfterSeconds"
    private static let onboardingKey = "hasCompletedOnboarding"
    private static let legacyScreenSaverKey = "isScreenSaverEnabled"

    static var theme: InterfaceTheme {
        get { UserDefaults.standard.string(forKey: themeKey).flatMap(InterfaceTheme.init(rawValue:)) ?? .classic }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// The first-launch screens (the look, then mouse or touch) have been answered.
    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingKey) }
    }

    /// Pointing and clicking in the menus and playback screens.
    static var isMouseEnabled: Bool {
        get { UserDefaults.standard.object(forKey: mouseKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: mouseKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Direct touch on iPhone and iPad: touching a row selects it, sliding moves the selection,
    /// lifting chooses, and lists scroll with a drag.
    static var isTouchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: touchKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: touchKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// The idle time before the screen saver starts; 0 means never.
    static var screenSaverDelay: TimeInterval {
        get {
            if let seconds = UserDefaults.standard.object(forKey: screenSaverDelayKey) as? Double {
                return max(0, seconds)
            }
            // Before 2.0 the screen saver was on (after a minute) or off.
            let wasEnabled = UserDefaults.standard.object(forKey: legacyScreenSaverKey) as? Bool ?? true
            return wasEnabled ? 60 : 0
        }
        set {
            UserDefaults.standard.set(max(0, newValue), forKey: screenSaverDelayKey)
            UserDefaults.standard.set(newValue > 0, forKey: legacyScreenSaverKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// The choices Settings > Screen Saver offers, in seconds (0 = never).
    static let screenSaverDelayChoices: [TimeInterval] = [0, 60, 120, 300, 600, 900, 1800, 3600]

    static func screenSaverDelayTitle(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "Never" }
        if seconds >= 3600 {
            let hours = Int((seconds / 3600).rounded())
            return hours == 1 ? "1 Hour" : "\(hours) Hours"
        }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 Minute" : "\(minutes) Minutes"
    }
}
