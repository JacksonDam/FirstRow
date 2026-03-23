import Foundation

func formatfirstRowPlaybackTime(_ totalSeconds: Double) -> String {
    let seconds = max(0, totalSeconds.isFinite ? totalSeconds : 0)
    let totalInt = Int(seconds.rounded())
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
