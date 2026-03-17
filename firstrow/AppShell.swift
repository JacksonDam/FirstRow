import SwiftUI

extension Notification.Name {
    static let firstRowQuitRequested = Notification.Name("firstRowQuitRequested")
}

@main
struct FirstRowShell: App {
    #if os(macOS)
        @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(iOS)
        @UIApplicationDelegateAdaptor(IOSAppDelegate.self) var appDelegate
    #endif
    var body: some Scene {
        WindowGroup {
            ContentView()
            #if os(iOS)
                .statusBar(hidden: true)
            #endif
                .ignoresSafeArea()
        }
        #if os(macOS)
        .windowStyle(HiddenTitleBarWindowStyle()).commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .windowSize) {}
            CommandGroup(replacing: .windowArrangement) {}
            CommandGroup(after: .appTermination) {
                Button("Quit First Row") {
                    NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
                }.keyboardShortcut(.escape, modifiers: [.command])
            }
        }
        #endif
    }
}
