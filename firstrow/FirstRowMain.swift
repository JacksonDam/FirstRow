#if os(macOS)
    import AppKit
#else
    import UIKit
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
        #else
            UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(IOSAppDelegate.self))
        #endif
    }
}
