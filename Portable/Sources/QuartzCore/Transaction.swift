import Foundation

/// One transaction's completion block and the animations it waits for.
final class TransactionRecord {
    var completion: (() -> Void)?
    var pendingAnimations = 0
    var committed = false
    var fired = false

    func animationEnded() {
        pendingAnimations -= 1
        fireIfDone()
    }

    func fireIfDone() {
        guard committed, !fired, pendingAnimations <= 0 else { return }
        fired = true
        if let completion {
            CATransaction.scheduleCompletion(completion)
        }
    }
}

/// Batches layer changes. The outermost implicit transaction is committed by the host once
/// per frame, before the layers are drawn.
public final class CATransaction: NSObject {
    struct Frame {
        var disableActions = false
        var duration: CFTimeInterval = 0.25
        var timingFunction: CAMediaTimingFunction?
        var values: [String: Any] = [:]
        let record = TransactionRecord()
        let implicit: Bool
    }

    nonisolated(unsafe) static var stack: [Frame] = []
    nonisolated(unsafe) static var pendingCompletions: [() -> Void] = []
    nonisolated(unsafe) static var commitTime: CFTimeInterval = CACurrentMediaTime()
    /// Called when something changes that needs a new frame.
    nonisolated(unsafe) public static var onChange: (() -> Void)?

    static var current: Frame {
        get {
            ensureFrame()
            return stack[stack.count - 1]
        }
        set {
            ensureFrame()
            stack[stack.count - 1] = newValue
        }
    }

    /// (Opening a transaction changes nothing on screen, so it doesn't ask for a frame: the
    /// renderer opens one every pass, and each frame would ask for the next for ever.)
    private static func ensureFrame() {
        if stack.isEmpty {
            stack.append(Frame(implicit: true))
        }
    }

    public static func begin() {
        ensureFrame()
        var frame = Frame(implicit: false)
        // Nested transactions inherit their parent's settings.
        if let parent = stack.last {
            frame.disableActions = parent.disableActions
            frame.duration = parent.duration
            frame.timingFunction = parent.timingFunction
        }
        stack.append(frame)
    }

    public static func commit() {
        guard let frame = stack.last, !frame.implicit else { return }
        stack.removeLast()
        frame.record.committed = true
        frame.record.fireIfDone()
    }

    /// Commits the implicit transaction; the host calls this once per frame.
    public static func flush() {
        commitTime = CACurrentMediaTime()
        while let frame = stack.last {
            stack.removeLast()
            frame.record.committed = true
            frame.record.fireIfDone()
        }
    }

    public static func setDisableActions(_ flag: Bool) { current.disableActions = flag }
    public static func disableActions() -> Bool { stack.last?.disableActions ?? false }
    public static func setAnimationDuration(_ duration: CFTimeInterval) { current.duration = duration }
    public static func animationDuration() -> CFTimeInterval { stack.last?.duration ?? 0.25 }
    public static func setAnimationTimingFunction(_ function: CAMediaTimingFunction?) { current.timingFunction = function }
    public static func animationTimingFunction() -> CAMediaTimingFunction? { stack.last?.timingFunction }
    public static func setCompletionBlock(_ block: (() -> Void)?) {
        current.record.completion = block
        // It runs after a frame, so there has to be one.
        if block != nil { onChange?() }
    }
    public static func completionBlock() -> (() -> Void)? { stack.last?.record.completion }
    public static func setValue(_ value: Any?, forKey key: String) { current.values[key] = value }
    public static func value(forKey key: String) -> Any? { stack.last?.values[key] }
    public static func lock() {}
    public static func unlock() {}

    static var currentRecord: TransactionRecord { current.record }

    static func scheduleCompletion(_ block: @escaping () -> Void) {
        pendingCompletions.append(block)
        onChange?()
    }

    /// Runs completion blocks whose animations have all ended; the host calls this each frame.
    public static func runCompletions() {
        let blocks = pendingCompletions
        pendingCompletions.removeAll()
        for block in blocks { block() }
    }
}
