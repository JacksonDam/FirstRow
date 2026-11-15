#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import CoreText
    import FirstRowPortable
#endif

@main
enum FirstRowMain {
    static func main() {
        #if os(macOS)
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) {
                application.run()
            }
        #elseif canImport(UIKit)
            UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(IOSAppDelegate.self))
        #else
            // (Characters the look's own font lacks are drawn first with a font made for the
            // language First Row is in.)
            FontRegistry.preferredFallbackNames = AppLanguage.current.fallbackFontNames
            PortableApplication.run { PortableAppHost() }
        #endif
    }
}
