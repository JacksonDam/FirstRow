import SwiftUI

extension Notification.Name {
    static let firstRowCommandEscapeRequested = Notification.Name("firstRowCommandEscapeRequested")
    static let firstRowQuitRequested = Notification.Name("firstRowQuitRequested")
    static let firstRowTerminateRequested = Notification.Name("firstRowTerminateRequested")
    static let firstRowImmersivePresentationRequested = Notification.Name("firstRowImmersivePresentationRequested")
    static let firstRowIntroReady = Notification.Name("firstRowIntroReady")
    static let firstRowIntroBegin = Notification.Name("firstRowIntroBegin")
}

@main
struct FirstRowShell: App {
    #if os(macOS)
        @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
        }
        #if os(macOS)
        .windowStyle(HiddenTitleBarWindowStyle()).commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .windowSize) {}
            CommandGroup(replacing: .windowArrangement) {}
            CommandGroup(after: .appTermination) {
                Button("Quit First Row") {
                    NotificationCenter.default.post(name: .firstRowCommandEscapeRequested, object: nil)
                }.keyboardShortcut(.escape, modifiers: [.command])
            }
        }
        #endif
    }
}
