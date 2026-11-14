import Foundation

/// The time left, as "-m:ss", worked out from the whole seconds shown for the time played,
/// so the two change together.
func formatfirstRowRemainingTime(duration: Double, elapsed: Double) -> String {
    let duration = max(0, duration.isFinite ? duration : 0)
    let elapsed = max(0, elapsed.isFinite ? elapsed : 0)
    return "-" + formatfirstRowPlaybackTime(max(0, duration.rounded() - elapsed.rounded()))
}

/// Times already written out, by their whole seconds: the system's formatter takes tens of
/// microseconds, and the same few times are asked for on every pass.
private final class PlaybackTimeTexts: @unchecked Sendable {
    static let shared = PlaybackTimeTexts()
    private let lock = NSLock()
    private var texts: [Int: String] = [:]

    func text(for seconds: Int, make: (Int) -> String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let known = texts[seconds] { return known }
        let made = make(seconds)
        if texts.count > 8192 { texts.removeAll(keepingCapacity: true) }
        texts[seconds] = made
        return made
    }
}

func formatfirstRowPlaybackTime(_ totalSeconds: Double) -> String {
    let seconds = max(0, totalSeconds.isFinite ? totalSeconds : 0)
    return PlaybackTimeTexts.shared.text(for: Int(seconds.rounded()), make: writeOutPlaybackTime)
}

private func writeOutPlaybackTime(_ totalInt: Int) -> String {
    let hours = totalInt / 3600
    let minutes = (totalInt % 3600) / 60
    let secs = totalInt % 60
    if hours > 0 {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
            let duration = Duration.seconds(totalInt)
            return duration.formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1)))
        }
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
        let duration = Duration.seconds(totalInt)
        return duration.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1)))
    }
    return String(format: "%d:%02d", minutes, secs)
}
