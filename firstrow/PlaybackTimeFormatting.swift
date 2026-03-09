import Foundation

func formatfirstRowPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let clamped = Int(max(0, seconds.rounded(.down)))
    let hours = clamped / 3600
    let minutes = (clamped % 3600) / 60
    let remainder = clamped % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%d:%02d", minutes, remainder)
}
