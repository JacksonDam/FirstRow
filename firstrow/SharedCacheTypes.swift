import Foundation

final class BoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Key: Value] = [:]
    private let maxEntryCount: Int
    init(maxEntryCount: Int) {
        self.maxEntryCount = maxEntryCount
    }

    func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func store(_ value: Value, for key: Key) {
        lock.lock()
        if entries.count >= maxEntryCount { entries.removeAll(keepingCapacity: true) }
        entries[key] = value
        lock.unlock()
    }
}

final class BlockingResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?
    func set(_ value: Value?) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func value() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
