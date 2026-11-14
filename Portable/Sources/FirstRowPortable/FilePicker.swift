import CSDL3
import Foundation

/// The system's folder and file pickers (GTK or the desktop portal on Linux, the common item
/// dialog on Windows), shown over First Row with the pointer until they're answered.
@MainActor
public enum PortableFilePicker {
    private final class Request {
        let completion: @MainActor ([URL]) -> Void
        let filters: [(name: UnsafeMutablePointer<CChar>?, pattern: UnsafeMutablePointer<CChar>?)]
        init(completion: @escaping @MainActor ([URL]) -> Void, filters: [(String, String)]) {
            self.completion = completion
            self.filters = filters.map { (strdup($0.0), strdup($0.1)) }
        }

        deinit {
            for filter in filters {
                free(filter.name)
                free(filter.pattern)
            }
        }
    }

    private static let callback: SDL_DialogFileCallback = { userdata, files, _ in
        guard let userdata else { return }
        let request = Unmanaged<Request>.fromOpaque(userdata).takeRetainedValue()
        var urls: [URL] = []
        if let files {
            var index = 0
            while let file = files[index] {
                urls.append(URL(fileURLWithPath: String(cString: file)))
                index += 1
            }
        }
        DispatchQueue.main.async {
            PortableApplication.hideCursorIfFullscreen()
            request.completion(urls)
        }
    }

    /// Asks for folders, with the chooser starting in the home folder or in the one given.
    public static func chooseFolders(allowMany: Bool, startingIn folder: URL? = nil, completion: @escaping @MainActor ([URL]) -> Void) {
        SDL_ShowCursor()
        let request = Request(completion: completion, filters: [])
        let start = folder.map { $0.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? $0.path }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        SDL_ShowOpenFolderDialog(callback, Unmanaged.passRetained(request).toOpaque(), PortableApplication.windowHandle, start, allowMany)
    }

    /// `filters` are (description, semicolon-separated extensions) pairs, such as ("XML", "xml").
    public static func chooseFile(filters: [(String, String)], completion: @escaping @MainActor ([URL]) -> Void) {
        chooseFiles(filters: filters, allowMany: false, completion: completion)
    }

    /// Asks for a file, or for as many as are wanted.
    public static func chooseFiles(filters: [(String, String)], allowMany: Bool, completion: @escaping @MainActor ([URL]) -> Void) {
        SDL_ShowCursor()
        let request = Request(completion: completion, filters: filters)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list = request.filters.map { SDL_DialogFileFilter(name: $0.name, pattern: $0.pattern) }
        list.withUnsafeMutableBufferPointer { buffer in
            SDL_ShowOpenFileDialog(callback, Unmanaged.passRetained(request).toOpaque(), PortableApplication.windowHandle, buffer.baseAddress, Int32(buffer.count), home, allowMany)
        }
    }
}
