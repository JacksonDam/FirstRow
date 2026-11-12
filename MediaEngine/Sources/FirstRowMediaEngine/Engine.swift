import AetherEngine
import AVFoundation
import Foundation
import QuartzCore

/// The engine, as First Row finds it: the framework's one class it knows the name of (see
/// `MediaEngineProviding`).
@MainActor
@objc(FirstRowMediaEngine)
public final class Engine: NSObject, MediaEngineProviding {
    private var thePlayer: EnginePlayer?

    @objc override public init() {
        super.init()
    }

    var interfaceVersion: Int { MediaEngineInterface.version }

    var engineDescription: String { "AetherEngine " + AetherEngine.version }

    func player() -> NSObject? {
        if let thePlayer { return thePlayer }
        guard let engine = try? AetherEngine() else { return nil }
        let made = EnginePlayer(engine: engine)
        thePlayer = made
        return made
    }

    func describe(_ url: URL, then answer: @escaping ([String: Any]) -> Void) {
        Task.detached(priority: .utility) {
            var found: [String: Any] = [:]
            do {
                let source = try await MediaSources.source(for: url, user: nil, password: nil)
                let probe = try AetherEngine.probe(source: source)
                found[MediaEngineKey.duration] = probe.durationSeconds
                found[MediaEngineKey.hasVideo] = probe.videoWidth > 0 && probe.videoHeight > 0
                found[MediaEngineKey.width] = Double(probe.videoWidth)
                found[MediaEngineKey.height] = Double(probe.videoHeight)
                if let title = probe.metadata.title { found[MediaEngineKey.title] = title }
                if let artwork = probe.metadata.artworkData { found[MediaEngineKey.artwork] = artwork }
            } catch {
                found[MediaEngineKey.error] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            let result = found
            await MainActor.run { answer(result) }
        }
    }

    func picture(of url: URL, details: [String: Any], then answer: @escaping (CGImage?) -> Void) {
        let seconds = (details[MediaEngineKey.seconds] as? Double) ?? 0
        let side = (details[MediaEngineKey.longestSide] as? Double) ?? 1100
        Task.detached(priority: .utility) {
            var image: CGImage?
            if let source = try? await MediaSources.source(for: url, user: nil, password: nil) {
                let extractor: FrameExtractor
                switch source {
                case let .url(url): extractor = FrameExtractor(url: url)
                case let .custom(reader, hint): extractor = FrameExtractor(reader: reader, formatHint: hint)
                }
                image = await extractor.snapshot(at: seconds, maxSize: CGSize(width: side, height: side))
                await extractor.shutdown()
            }
            let result = image
            await MainActor.run { answer(result) }
        }
    }

    func ask(_ question: String, details: [String: Any], then answer: @escaping ([String: Any]) -> Void) {
        let server = (details[MediaEngineKey.server] as? String) ?? ""
        let user = details[MediaEngineKey.user] as? String
        let password = details[MediaEngineKey.password] as? String
        switch question {
        case MediaEngineQuestion.sharedFolders:
            // The folders a computer or network drive shares.
            Task.detached(priority: .userInitiated) {
                let found = await SharedFolders.answer {
                    [MediaEngineKey.names: try await SharedFolders.shares(server: server, user: user, password: password)]
                }
                await MainActor.run { answer(found) }
            }
        case MediaEngineQuestion.sharedFolderContents:
            // What a folder on one of them holds.
            let share = (details[MediaEngineKey.share] as? String) ?? ""
            let path = (details[MediaEngineKey.path] as? String) ?? ""
            Task.detached(priority: .userInitiated) {
                let found = await SharedFolders.answer {
                    [MediaEngineKey.entries: try await SharedFolders.contents(server: server, share: share, path: path, user: user, password: password)]
                }
                await MainActor.run { answer(found) }
            }
        default:
            answer([MediaEngineKey.error: "The engine doesn't know \"\(question)\"."])
        }
    }
}
