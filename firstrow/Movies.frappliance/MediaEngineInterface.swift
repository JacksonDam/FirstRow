#if !FIRSTROW_PORTABLE && canImport(ObjectiveC)
    import AVFoundation
    import Foundation
    import QuartzCore

    // What the system's player can open, First Row plays with the system's player. For the rest
    // (Matroska, AVI, Windows Media, MPEG transport streams, pictures of DVDs and Blu-rays, and
    // the sounds and subtitles that come in them) it carries an engine of its own, in a
    // framework of its own that is loaded as First Row runs, on the systems new enough for it
    // (see MediaEngine/README.md). The two are built apart, so they know each other only by
    // what's here, in Objective-C's terms: this one file is compiled into both.

    /// The names of what is passed between the two in dictionaries.
    enum MediaEngineKey {
        // Asking for a movie to be opened.
        /// The movie: a file, an address on the web, or a folder holding a disc's files.
        static let url = "url"
        /// What to send with each request for it, when it's on a server.
        static let headers = "headers"
        /// Where to start, in seconds.
        static let start = "start"
        /// True to open it without playing it.
        static let paused = "paused"
        /// Subtitle files kept beside the movie: each a dictionary with `url` and, if they're
        /// known, `name` and `language`.
        static let subtitleFiles = "subtitleFiles"
        /// Who to sign in to a shared folder as, when the movie is on one.
        static let user = "user"
        static let password = "password"

        // A track of sound or of subtitles.
        static let id = "id"
        static let name = "name"
        static let language = "language"
        /// How it's stored ("ac3", "subrip"...).
        static let codec = "codec"
        static let channels = "channels"
        static let isChosen = "isChosen"
        static let isForced = "isForced"

        // A chapter.
        static let title = "title"
        // (and `start`)

        // A subtitle that is showing: words, or a picture with its place.
        static let text = "text"
        /// The words in pieces that differ in style: each a dictionary with `text`, and
        /// `isBold`, `isItalic`, `isUnderlined` and `color` (0xRRGGBBAA) where they're set.
        static let runs = "runs"
        static let isBold = "isBold"
        static let isItalic = "isItalic"
        static let isUnderlined = "isUnderlined"
        static let color = "color"
        /// Where the words ask to go, as on a number pad: 2 is the middle of the foot, 8 the
        /// middle of the top. Absent for the usual place.
        static let alignment = "alignment"
        static let image = "image"
        /// The picture's place in its canvas, each from 0 to 1, measured from the top left.
        static let x = "x"
        static let y = "y"
        static let width = "width"
        static let height = "height"
        /// The canvas's shape, in the movie's own pixels (0 when it is the movie's).
        static let canvasWidth = "canvasWidth"
        static let canvasHeight = "canvasHeight"

        // What a file is, for the menus.
        static let duration = "duration"
        static let hasVideo = "hasVideo"
        static let artwork = "artwork"
        static let error = "error"
        static let seconds = "seconds"
        static let longestSide = "longestSide"

        // Looking in shared folders.
        /// The computer or network drive: its name or address, with ":port" if it's an unusual one.
        static let server = "server"
        static let share = "share"
        /// A folder's place in its share, with "/" between the names.
        static let path = "path"
        /// The answer's list of names (of shares).
        static let names = "names"
        /// The answer's list of what a folder holds: each with `name`, `isFolder` and `size`.
        static let entries = "entries"
        static let isFolder = "isFolder"
        static let size = "size"
        /// In a question about what a folder holds: the kinds of file First Row would open
        /// (the endings of their names, in small letters). Those and the folders are tried,
        /// and what the computer won't open is left out of the answer: a folder it keeps to
        /// itself, a file that only points to one somewhere else.
        static let opens = "opens"
        /// True in an answer that failed because a name and password are wanted.
        static let needsSignIn = "needsSignIn"
        /// True in an answer that failed because the computer couldn't be reached at all.
        static let isUnreachable = "isUnreachable"
    }

    /// What can be asked of the engine by name (see `MediaEngineProviding.ask`).
    enum MediaEngineQuestion {
        /// The folders a computer shares: `server`, and `user` and `password` if it wants them.
        static let sharedFolders = "sharedFolders"
        /// What a shared folder holds: `server`, `share`, `path`, and `user` and `password`,
        /// and `opens` to have only what can be opened.
        static let sharedFolderContents = "sharedFolderContents"
    }

    /// The engine playing a movie.
    @MainActor
    @objc(FirstRowMediaEnginePlaying)
    protocol MediaEnginePlaying: NSObjectProtocol {
        /// The picture. First Row puts it among its own layers and gives it its place.
        var pictureLayer: CALayer { get }
        /// Called when anything but the time has changed: what it's doing, its tracks, its
        /// chapters, its length.
        var onChange: (() -> Void)? { get set }

        /// Opens a movie, and plays it unless asked not to (see `MediaEngineKey`).
        func open(_ request: [String: Any])
        /// Lets go of the movie.
        func close()

        func play()
        func pause()
        /// "idle", "opening", "playing", "paused", "ended" or "failed".
        var phase: String { get }
        /// It has been asked to play and isn't yet: it's opening, moving to another place or
        /// waiting for more of the movie.
        var isWaiting: Bool { get }
        /// Why it failed, in words for a person.
        var failure: String? { get }
        /// It has a first frame to show.
        var hasPicture: Bool { get }
        var position: Double { get }
        /// The movie's length in seconds, 0 until it's known.
        var duration: Double { get }
        func seek(to seconds: Double, exactly: Bool, then done: ((Bool) -> Void)?)
        /// 1 is normal.
        var speed: Double { get set }
        var isMuted: Bool { get set }

        var audioTracks: [[String: Any]] { get }
        var subtitleTracks: [[String: Any]] { get }
        func chooseAudioTrack(_ id: Int)
        /// A negative number turns subtitles off.
        func chooseSubtitleTrack(_ id: Int)
        var chapters: [[String: Any]] { get }

        /// The subtitles to show now. First Row draws them.
        var captions: [[String: Any]] { get }
        /// Goes up whenever `captions` would answer something else, so it needn't be asked
        /// for more often than it changes.
        var captionsRevision: Int { get }

        /// "sdr", "hdr10", "hdr10+", "dolbyvision" or "hlg".
        var pictureKind: String { get }
        /// The picture's shape, 0 by 0 until it's known.
        var pictureSize: CGSize { get }
        /// The system's player, when it is what's showing the picture (it isn't for the kinds
        /// of video the engine has to decode itself).
        var systemPlayer: AVPlayer? { get }

        /// On iPhone and iPad, has the system's picture in picture ready while this is set: a
        /// movie that is playing goes into the system's small window by itself as First Row is
        /// left. Nothing happens on other systems.
        var keepsPictureInPictureReady: Bool { get set }
        /// The picture is in the system's small window.
        var isInPictureInPicture: Bool { get }
        /// Brings the picture back from the small window to its place in First Row.
        func leavePictureInPicture()
    }

    /// The engine itself: the one object First Row makes of the framework's own class.
    @MainActor
    @objc(FirstRowMediaEngineProviding)
    protocol MediaEngineProviding: NSObjectProtocol {
        /// Goes up when this file changes in a way the two sides must agree on.
        var interfaceVersion: Int { get }
        /// The engine's own name and version, for the About screen and for reports.
        var engineDescription: String { get }
        /// The player. There is one, used for one movie after another.
        func player() -> NSObject?
        /// What a file is (see `MediaEngineKey`): its length, whether it has a picture, its
        /// title, its cover. Answered on the main thread.
        func describe(_ url: URL, then answer: @escaping ([String: Any]) -> Void)
        /// A frame of a movie for the menus, or nil. Answered on the main thread.
        func picture(of url: URL, details: [String: Any], then answer: @escaping (CGImage?) -> Void)
        /// Anything else asked of the engine, by name. Answered on the main thread.
        func ask(_ question: String, details: [String: Any], then answer: @escaping ([String: Any]) -> Void)
    }

    enum MediaEngineInterface {
        static let version = 3
        /// The framework's class that is the engine.
        static let providerClassName = "FirstRowMediaEngine"
        static let frameworkName = "FirstRowMediaEngine"
        /// The engine for the systems older than the main engine runs on (MediaEngine/Older).
        static let olderProviderClassName = "FirstRowMediaEngineOlder"
        static let olderFrameworkName = "FirstRowMediaEngineOlder"
    }
#endif
