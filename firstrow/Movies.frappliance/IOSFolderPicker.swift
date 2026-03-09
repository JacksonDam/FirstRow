#if os(iOS)
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

    struct IOSFolderPicker: UIViewControllerRepresentable {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        func makeCoordinator() -> Coordinator {
            Coordinator(onPick: onPick, onCancel: onCancel)
        }

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [.folder],
                asCopy: false,
            )
            picker.delegate = context.coordinator
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            return picker
        }

        func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}
    }

    extension IOSFolderPicker {
        final class Coordinator: NSObject, UIDocumentPickerDelegate {
            private let onPick: (URL) -> Void
            private let onCancel: () -> Void
            init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
                self.onPick = onPick
                self.onCancel = onCancel
            }

            func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                guard let selectedURL = urls.first else {
                    onCancel()
                    return
                }
                onPick(selectedURL)
            }

            func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
                onCancel()
            }
        }
    }
#endif
