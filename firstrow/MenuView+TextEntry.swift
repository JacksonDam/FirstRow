import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

extension Notification.Name {
    /// Posted when text entry closes, so the Apple TV remote's view can take presses again.
    static let firstRowTextEntryDidEnd = Notification.Name("firstRowTextEntryDidEnd")
    /// Harness only: `userInfo["text"]` is typed as if from a keyboard.
    static let firstRowHarnessTypeText = Notification.Name("firstRowHarnessTypeText")
}

/// Typing on screen: a title, the text so far and a grid of keys to pick with the arrows,
/// with a real keyboard working too. iPhone, iPad and Apple TV use the system's own fields.
struct TextEntryState: Equatable {
    var title: String
    var prompt: String
    var text: String
    var isSecure: Bool
    var focusRow = 0
    var focusColumn = 0
    var isShifted = false
    /// The last input came from a keyboard, so Return means Done rather than the focused key.
    var lastInputWasTyping = false
}

/// A big code to type into another device, as Quick Connect shows.
struct CodeDisplayState: Equatable {
    var title: String
    var message: String
    var code: String
    var status: String
}

enum TextEntryKey: Equatable {
    case character(String)
    case text(String)
    case space
    case delete
    case shift
    case done
    case cancel

    /// How many standard key widths it takes.
    var units: CGFloat {
        switch self {
        case .character: 1
        case .text, .shift, .delete, .cancel, .done: 2
        case .space: 5
        }
    }

    func label(shifted: Bool) -> String {
        switch self {
        case let .character(value): shifted ? value.uppercased() : value
        case let .text(value): value
        case .space: "Space"
        case .delete: "Delete"
        case .shift: shifted ? "abc" : "ABC"
        case .done: "Done"
        case .cancel: "Cancel"
        }
    }

    static let rows: [[TextEntryKey]] = [
        "abcdefghijklm".map { .character(String($0)) },
        "nopqrstuvwxyz".map { .character(String($0)) },
        "1234567890.-_".map { .character(String($0)) },
        [.character("@"), .character(":"), .character("/"), .text(".com"), .character("?"), .character("&"), .character("="), .character("+"), .character("!"), .character("#")],
        [.shift, .space, .delete, .cancel, .done],
    ]
}

extension MenuView {
    static let textEntryMaximumLength = 256

    var isTextEntryActive: Bool {
        textEntry != nil || codeDisplay != nil
    }

    /// Asks for text. `completion` gets nil if it was cancelled.
    /// `isSearch` for words to look for, rather than a server's address or a name: where the
    /// system's own keyboard does the typing, it is the keyboard for searching.
    func requestTextEntry(title: String, prompt: String, initialText: String = "", isSecure: Bool = false, isSearch: Bool = false, completion: @escaping (String?) -> Void) {
        #if canImport(UIKit) && !os(macOS) && !FIRSTROW_PORTABLE
            presentSystemTextEntry(title: title, prompt: prompt, initialText: initialText, isSecure: isSecure, isSearch: isSearch, completion: completion)
        #else
            textEntryCompletion = completion
            textEntry = TextEntryState(title: title, prompt: prompt, text: initialText, isSecure: isSecure)
            showTextEntryLayer()
            #if FIRSTROW_PORTABLE
                PortableApplication.setTextInputActive(true)
            #endif
        #endif
    }

    /// Shows a code full screen until `dismissCodeDisplay` or Back (which calls `onCancel`).
    func presentCodeDisplay(_ state: CodeDisplayState, onCancel: @escaping () -> Void) {
        codeDisplayCancel = onCancel
        codeDisplay = state
        showTextEntryLayer()
    }

    func updateCodeDisplayStatus(_ status: String) {
        codeDisplay?.status = status
    }

    func dismissCodeDisplay() {
        guard codeDisplay != nil else { return }
        codeDisplayCancel = nil
        hideTextEntryLayer { self.codeDisplay = nil }
    }

    /// How strongly the menu shows. Under a typing screen that is up it doesn't, whatever
    /// else has brought the menu back in meanwhile (a list that finished changing, say).
    var menuOpacityOnScreen: Double {
        menuSceneOpacity * (1 - textEntryOpacity)
    }

    private func showTextEntryLayer() {
        withAnimation(.easeInOut(duration: 0.3)) {
            menuSceneOpacity = 0
            textEntryOpacity = 1
        }
    }

    private func hideTextEntryLayer(then clear: @escaping () -> Void) {
        withAnimation(.easeInOut(duration: 0.3)) {
            menuSceneOpacity = 1
            textEntryOpacity = 0
        }
        Task {
            try? await firstRowSleep(0.3)
            guard self.textEntryOpacity <= 0.001 else { return }
            clear()
        }
    }

    private func finishTextEntry(_ result: String?) {
        guard textEntry != nil else { return }
        let completion = textEntryCompletion
        textEntryCompletion = nil
        #if FIRSTROW_PORTABLE
            PortableApplication.setTextInputActive(false)
        #endif
        // With no completion left, the entry takes no more input while it fades.
        hideTextEntryLayer { if self.textEntryCompletion == nil { self.textEntry = nil } }
        completion?(result)
        NotificationCenter.default.post(name: .firstRowTextEntryDidEnd, object: nil)
    }

    // MARK: - Input

    func handleTextEntryInput(_ key: KeyCode) {
        if codeDisplay != nil {
            if key == .escape || key == .delete {
                playSound(named: "Exit")
                let cancel = codeDisplayCancel
                dismissCodeDisplay()
                cancel?()
            }
            return
        }
        guard var entry = textEntry, textEntryCompletion != nil else { return }
        let rows = TextEntryKey.rows
        switch key {
        case .upArrow, .downArrow:
            let target = entry.focusRow + (key == .upArrow ? -1 : 1)
            guard rows.indices.contains(target) else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            entry.focusColumn = Self.nearestColumn(in: target, to: Self.keyCenterUnits(row: entry.focusRow, column: entry.focusColumn))
            entry.focusRow = target
            entry.lastInputWasTyping = false
            textEntry = entry
            playSound(named: "SelectionChange")
        case .leftArrow, .rightArrow:
            let target = entry.focusColumn + (key == .leftArrow ? -1 : 1)
            guard rows[entry.focusRow].indices.contains(target) else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            entry.focusColumn = target
            entry.lastInputWasTyping = false
            textEntry = entry
            playSound(named: "SelectionChange")
        case .enter:
            if entry.lastInputWasTyping {
                playSound(named: "Selection")
                finishTextEntry(entry.text)
            } else {
                press(rows[entry.focusRow][entry.focusColumn])
            }
        case .delete:
            if entry.text.isEmpty {
                playSound(named: "Exit")
                finishTextEntry(nil)
            } else {
                entry.text.removeLast()
                textEntry = entry
                playSound(named: "SelectionChange")
            }
        case .escape:
            playSound(named: "Exit")
            finishTextEntry(nil)
        default:
            // Typed spaces arrive as text; the key itself (or a controller's X) does nothing here.
            break
        }
    }

    /// Characters typed on a keyboard.
    func handleTypedText(_ typed: String) {
        if textEntry == nil, handleYouTubeSearchTypedText(typed) { return }
        guard var entry = textEntry, textEntryCompletion != nil else { return }
        let printable = typed.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700 ... 0xF8FF).contains(scalar.value)
        }
        guard !printable.isEmpty else { return }
        registerUserInteractionForScreenSaver()
        entry.text = String((entry.text + String(String.UnicodeScalarView(printable))).prefix(Self.textEntryMaximumLength))
        entry.lastInputWasTyping = true
        textEntry = entry
    }

    private func press(_ key: TextEntryKey) {
        guard var entry = textEntry else { return }
        switch key {
        case let .character(value):
            entry.text += entry.isShifted ? value.uppercased() : value
        case let .text(value):
            entry.text += value
        case .space:
            entry.text += " "
        case .delete:
            guard !entry.text.isEmpty else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            entry.text.removeLast()
        case .shift:
            entry.isShifted.toggle()
        case .done:
            playSound(named: "Selection")
            finishTextEntry(entry.text)
            return
        case .cancel:
            playSound(named: "Exit")
            finishTextEntry(nil)
            return
        }
        entry.text = String(entry.text.prefix(Self.textEntryMaximumLength))
        textEntry = entry
        playSound(named: "Selection")
    }

    /// The middle of a key, in key widths from the row's left edge (rows are centred).
    static func keyCenterUnits(row: Int, column: Int) -> CGFloat {
        let keys = TextEntryKey.rows[row]
        let total = keys.reduce(0) { $0 + $1.units }
        let widest: CGFloat = 13
        var x = (widest - total) * 0.5
        for (index, key) in keys.enumerated() {
            if index == column { return x + key.units * 0.5 }
            x += key.units
        }
        return x
    }

    static func nearestColumn(in row: Int, to centerUnits: CGFloat) -> Int {
        let keys = TextEntryKey.rows[row]
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in keys.indices {
            let distance = abs(keyCenterUnits(row: row, column: index) - centerUnits)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    // MARK: - iPhone, iPad and Apple TV

    #if canImport(UIKit) && !os(macOS) && !FIRSTROW_PORTABLE
        private func presentSystemTextEntry(title: String, prompt: String, initialText: String, isSecure: Bool, isSearch: Bool, completion: @escaping (String?) -> Void) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
            guard var presenter = window?.rootViewController else {
                completion(nil)
                return
            }
            while let presented = presenter.presentedViewController { presenter = presented }
            let alert = UIAlertController(title: title, message: prompt, preferredStyle: .alert)
            alert.addTextField { field in
                field.text = initialText
                field.isSecureTextEntry = isSecure
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                // An address gets the keyboard made for addresses; a name, a password and words
                // to search for get the usual one, the last with Search for its Return key.
                field.keyboardType = isSecure || isSearch ? .default : .URL
                if !isSecure, title.lowercased().contains("name") { field.keyboardType = .default }
                if isSearch {
                    field.returnKeyType = .search
                    field.autocorrectionType = .default
                    field.clearButtonMode = .whileEditing
                }
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                completion(nil)
                NotificationCenter.default.post(name: .firstRowTextEntryDidEnd, object: nil)
            })
            alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak alert] _ in
                completion(alert?.textFields?.first?.text ?? "")
                NotificationCenter.default.post(name: .firstRowTextEntryDidEnd, object: nil)
            })
            presenter.present(alert, animated: true)
        }
    #endif
}
