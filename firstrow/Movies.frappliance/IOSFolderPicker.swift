#if os(iOS)
    import UIKit
    import UniformTypeIdentifiers

    /// The Files folder picker, for choosing where movies live.
    enum IOSFolderPicker {
        private final class Delegate: NSObject, UIDocumentPickerDelegate {
            let onPick: (URL) -> Void
            let onCancel: () -> Void
            init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
                self.onPick = onPick
                self.onCancel = onCancel
            }

            func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                IOSFolderPicker.activeDelegate = nil
                guard let url = urls.first else {
                    onCancel()
                    return
                }
                onPick(url)
            }

            func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
                IOSFolderPicker.activeDelegate = nil
                onCancel()
            }
        }

        private static var activeDelegate: Delegate?

        static func present(from presenter: UIViewController, onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            let delegate = Delegate(onPick: onPick, onCancel: onCancel)
            activeDelegate = delegate
            picker.delegate = delegate
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            presenter.present(picker, animated: true)
        }
    }
#endif
