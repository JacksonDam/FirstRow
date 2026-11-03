#if os(macOS)
    import AppKit

    /// The window where people choose extra media folders and older libraries (Settings… in the
    /// app menu, or Settings > Media Folders inside First Row).
    final class MediaSourcesSettingsWindow: NSWindow {}

    @MainActor
    final class MediaSourcesWindowController: NSWindowController, NSWindowDelegate {
        static let shared = MediaSourcesWindowController()

        private var folderLists: [MediaSources.FolderKind: FolderListView] = [:]
        private var libraryRows: [MediaSources.LibraryKind: LibraryRowView] = [:]
        private var changeObserver: NSObjectProtocol?

        private init() {
            let window = MediaSourcesSettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false,
            )
            window.title = "First Row Settings"
            window.isReleasedWhenClosed = false
            super.init(window: window)
            window.delegate = self
            window.contentView = makeContent()
            changeObserver = NotificationCenter.default.addObserver(
                forName: MediaSources.didChangeNotification,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible { self?.reload() }
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        func show() {
            reload()
            guard let window else { return }
            NSCursor.unhide()
            window.center()
            window.level = .floating
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        func windowWillClose(_: Notification) {
            NSCursor.hide()
            if let mainWindow = NSApplication.shared.windows.first(where: { !($0 is MediaSourcesSettingsWindow) && !($0 is NSPanel) && $0.isVisible }) {
                mainWindow.makeKeyAndOrderFront(nil)
            }
        }

        private func reload() {
            for (kind, list) in folderLists {
                list.folders = MediaSources.shared.folders(kind)
            }
            for (kind, row) in libraryRows {
                row.url = MediaSources.shared.library(kind)
            }
        }

        private func makeContent() -> NSView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

            stack.addArrangedSubview(Self.label(
                "First Row always looks in your Music, TV and Photos libraries, your Movies folder, and Movies or Music folders at the top level of connected drives. Add other places here.",
                secondary: true,
            ))
            for kind in MediaSources.FolderKind.allCases {
                let list = FolderListView(kind: kind)
                folderLists[kind] = list
                stack.addArrangedSubview(Self.label("\(kind.title) Folders", secondary: false))
                stack.addArrangedSubview(list)
                list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            }
            stack.addArrangedSubview(Self.label("Older Libraries", secondary: false))
            for kind in MediaSources.LibraryKind.allCases {
                let row = LibraryRowView(kind: kind)
                libraryRows[kind] = row
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            }
            return stack
        }

        static func label(_ text: String, secondary: Bool) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            if secondary {
                label.textColor = .secondaryLabelColor
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            } else {
                label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            }
            label.preferredMaxLayoutWidth = 520
            return label
        }
    }

    /// A list of folders with Add and Remove buttons.
    @MainActor
    private final class FolderListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
        let kind: MediaSources.FolderKind
        var folders: [URL] = [] {
            didSet {
                table.reloadData()
                removeButton.isEnabled = false
            }
        }

        private let table = NSTableView()
        private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

        init(kind: MediaSources.FolderKind) {
            self.kind = kind
            super.init(frame: .zero)
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.dataSource = self
            table.delegate = self
            table.usesAlternatingRowBackgroundColors = true
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let addButton = NSButton(title: "Add Folder…", target: self, action: #selector(addFolder))
            removeButton.target = self
            removeButton.action = #selector(removeFolder)
            removeButton.isEnabled = false
            let buttons = NSStackView(views: [addButton, removeButton])
            buttons.orientation = .horizontal
            for view in [scroll, buttons] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroll.heightAnchor.constraint(equalToConstant: 70),
                buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
                buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
                buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        func numberOfRows(in _: NSTableView) -> Int { folders.count }

        func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let field = NSTextField(labelWithString: (folders[row].path as NSString).abbreviatingWithTildeInPath)
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }

        func tableViewSelectionDidChange(_: Notification) {
            removeButton.isEnabled = table.selectedRow >= 0
        }

        @objc private func addFolder() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.prompt = "Add"
            panel.message = "Choose folders of \(kind.title.lowercased()) for First Row."
            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                MediaSources.shared.addFolder(url, kind: kind)
            }
        }

        @objc private func removeFolder() {
            let row = table.selectedRow
            guard row >= 0 else { return }
            MediaSources.shared.removeFolder(at: row, kind: kind)
        }
    }

    /// One older library (iTunes XML or iPhoto): where it is, and Choose / Clear buttons.
    @MainActor
    private final class LibraryRowView: NSView {
        let kind: MediaSources.LibraryKind
        var url: URL? {
            didSet {
                pathLabel.stringValue = url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not chosen"
                clearButton.isEnabled = url != nil
            }
        }

        private let pathLabel = NSTextField(labelWithString: "Not chosen")
        private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

        init(kind: MediaSources.LibraryKind) {
            self.kind = kind
            super.init(frame: .zero)
            let title = NSTextField(labelWithString: kind == .iTunesXML ? "iTunes Library XML:" : "iPhoto Library:")
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.textColor = .secondaryLabelColor
            pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(choose))
            clearButton.target = self
            clearButton.action = #selector(clear)
            clearButton.isEnabled = false
            let row = NSStackView(views: [title, pathLabel, chooseButton, clearButton])
            row.orientation = .horizontal
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        @objc private func choose() {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            switch kind {
            case .iTunesXML:
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowedFileTypes = ["xml"]
                panel.message = "Choose an iTunes library file (iTunes Music Library.xml or iTunes Library.xml). In iTunes or Music, File > Library > Export Library makes one."
            case .iPhoto:
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.treatsFilePackagesAsDirectories = false
                panel.message = "Choose your iPhoto Library."
            }
            panel.prompt = "Choose"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            MediaSources.shared.setLibrary(url, kind: kind)
        }

        @objc private func clear() {
            MediaSources.shared.setLibrary(nil, kind: kind)
        }
    }

    extension MainActor {
        /// Runs main-actor work from a callback that AppKit always delivers on the main thread.
        static func assumeIsolatedIfPossible(_ body: @escaping @MainActor () -> Void) {
            if #available(macOS 14.0, *) {
                MainActor.assumeIsolated(body)
            } else {
                Task { @MainActor in body() }
            }
        }
    }
#endif
