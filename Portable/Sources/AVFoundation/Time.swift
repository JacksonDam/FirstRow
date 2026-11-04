import Foundation

public typealias CMTimeValue = Int64
public typealias CMTimeScale = Int32

public struct CMTime: Equatable, Comparable, Hashable, Sendable {
    public var value: CMTimeValue
    public var timescale: CMTimeScale
    public var isValid: Bool
    public var isIndefinite: Bool

    public init(value: CMTimeValue, timescale: CMTimeScale) {
        self.value = value
        self.timescale = timescale
        isValid = timescale != 0
        isIndefinite = false
    }

    public init(seconds: Double, preferredTimescale: CMTimeScale) {
        if seconds.isFinite {
            self.init(value: CMTimeValue((seconds * Double(preferredTimescale)).rounded()), timescale: preferredTimescale)
        } else {
            self.init(value: 0, timescale: 0)
            isValid = seconds.isInfinite
            isIndefinite = seconds.isInfinite
        }
    }

    public var seconds: Double {
        if isIndefinite { return .nan }
        guard isValid, timescale != 0 else { return .nan }
        return Double(value) / Double(timescale)
    }

    public var isNumeric: Bool { isValid && !isIndefinite }

    public static let zero = CMTime(value: 0, timescale: 1)
    public static let invalid = CMTime(value: 0, timescale: 0)
    public static let indefinite: CMTime = {
        var t = CMTime(value: 0, timescale: 0)
        t.isValid = true
        t.isIndefinite = true
        return t
    }()

    public static let positiveInfinity = CMTime.indefinite

    public static func < (lhs: CMTime, rhs: CMTime) -> Bool {
        let a = lhs.seconds, b = rhs.seconds
        return a < b
    }

    public static func + (lhs: CMTime, rhs: CMTime) -> CMTime {
        CMTime(seconds: lhs.seconds + rhs.seconds, preferredTimescale: max(lhs.timescale, rhs.timescale, 600))
    }

    public static func - (lhs: CMTime, rhs: CMTime) -> CMTime {
        CMTime(seconds: lhs.seconds - rhs.seconds, preferredTimescale: max(lhs.timescale, rhs.timescale, 600))
    }
}

public func CMTimeMake(value: CMTimeValue, timescale: CMTimeScale) -> CMTime {
    CMTime(value: value, timescale: timescale)
}

public func CMTimeMakeWithSeconds(_ seconds: Double, preferredTimescale: CMTimeScale) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: preferredTimescale)
}

public func CMTimeGetSeconds(_ time: CMTime) -> Double { time.seconds }
