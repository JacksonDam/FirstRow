#if os(iOS)
    import UIKit
    import UniformTypeIdentifiers

    /// The Files picker, for bringing movies in from anywhere Files reaches, which takes in
    /// Dropbox, Google Drive and the like where their apps are installed.
    enum IOSFolderPicker {
        private final class Delegate: NSObject, UIDocumentPickerDelegate {
            let onPick: ([URL]) -> Void
            let onCancel: () -> Void
            init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
                self.onPick = onPick
                self.onCancel = onCancel
            }

            func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                IOSFolderPicker.activeDelegate = nil
                guard !urls.isEmpty else {
                    onCancel()
                    return
                }
                onPick(urls)
            }

            func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
                IOSFolderPicker.activeDelegate = nil
                onCancel()
            }
        }

        private static var activeDelegate: Delegate?

        /// Asks for movies, or folders of them: files of the kinds given (by their
        /// extensions) and folders can both be picked, and several at once. What comes back
        /// is where each one is, with leave to read it there (a folder is kept where it is,
        /// and a copy of it can't be asked for).
        static func presentForMovies(
            ofKinds extensions: Set<String>,
            from presenter: UIViewController,
            onPick: @escaping ([URL]) -> Void,
            onCancel: @escaping () -> Void,
        ) {
            var kinds: [UTType] = [.folder, .movie]
            for kind in extensions.sorted() {
                if let type = UTType(filenameExtension: kind), !kinds.contains(type) {
                    kinds.append(type)
                }
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: kinds, asCopy: false)
            let delegate = Delegate(onPick: onPick, onCancel: onCancel)
            activeDelegate = delegate
            picker.delegate = delegate
            picker.allowsMultipleSelection = true
            picker.shouldShowFileExtensions = true
            presenter.present(picker, animated: true)
        }
    }
#endif
