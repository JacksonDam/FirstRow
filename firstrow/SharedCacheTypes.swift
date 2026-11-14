import Foundation

/// Keeps the `maxEntryCount` most recently used entries.
final class LRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Key: (value: Value, lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0
    private let maxEntryCount: Int
    init(maxEntryCount: Int) {
        self.maxEntryCount = max(1, maxEntryCount)
    }

    subscript(key: Key) -> Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key] else { return nil }
            clock &+= 1
            entries[key] = (entry.value, clock)
            return entry.value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            guard let newValue else {
                entries[key] = nil
                return
            }
            clock &+= 1
            entries[key] = (newValue, clock)
            if entries.count > maxEntryCount,
               let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
            {
                entries[oldest] = nil
            }
        }
    }
}

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
