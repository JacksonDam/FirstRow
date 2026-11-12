#if os(iOS)
    import UIKit
    import UniformTypeIdentifiers

    /// The Files picker: for choosing the folder where movies live, and for bringing movies
    /// in from anywhere Files reaches, which takes in Dropbox, Google Drive and the like
    /// where their apps are installed.
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

        static func present(from presenter: UIViewController, onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            let delegate = Delegate(onPick: { onPick($0[0]) }, onCancel: onCancel)
            activeDelegate = delegate
            picker.delegate = delegate
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            presenter.present(picker, animated: true)
        }

        /// Asks for files of the kinds given, by their extensions. What comes back are copies
        /// for First Row to keep: the picker fetches a file that is with a service first, and
        /// shows how far it has got.
        static func presentForFiles(
            ofKinds extensions: Set<String>,
            from presenter: UIViewController,
            onPick: @escaping ([URL]) -> Void,
            onCancel: @escaping () -> Void,
        ) {
            var kinds: [UTType] = [.movie]
            for kind in extensions.sorted() {
                if let type = UTType(filenameExtension: kind), !kinds.contains(type) {
                    kinds.append(type)
                }
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: kinds, asCopy: true)
            let delegate = Delegate(onPick: onPick, onCancel: onCancel)
            activeDelegate = delegate
            picker.delegate = delegate
            picker.allowsMultipleSelection = true
            picker.shouldShowFileExtensions = true
            presenter.present(picker, animated: true)
        }
    }
#endif
