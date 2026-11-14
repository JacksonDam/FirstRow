import Foundation

enum MoviePlaybackGlyphState: Equatable {
    case pause
    case play
    case loading
    case rewind(Int)
    case fastForward(Int)
}
