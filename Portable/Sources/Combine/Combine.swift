import Foundation

// The slice of Combine First Row uses: ObservableObject, @Published and a sink on
// objectWillChange.

public protocol Cancellable {
    func cancel()
}

public final class AnyCancellable: Cancellable, Hashable {
    private var onCancel: (() -> Void)?

    public init(_ cancel: @escaping () -> Void) {
        onCancel = cancel
    }

    public init<C: Cancellable>(_ canceller: C) {
        onCancel = canceller.cancel
    }

    deinit { cancel() }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }

    public func store(in set: inout Set<AnyCancellable>) {
        set.insert(self)
    }

    public static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public final class ObservableObjectPublisher: @unchecked Sendable {
    public typealias Output = Void
    private var subscribers: [Int: () -> Void] = [:]
    private var nextID = 0

    public init() {}

    public func send() {
        for (_, subscriber) in subscribers.sorted(by: { $0.key < $1.key }) {
            subscriber()
        }
    }

    public func sink(receiveValue: @escaping (()) -> Void) -> AnyCancellable {
        nextID += 1
        let id = nextID
        subscribers[id] = { receiveValue(()) }
        return AnyCancellable { [weak self] in
            self?.subscribers.removeValue(forKey: id)
        }
    }
}

private enum PublisherStore {
    nonisolated(unsafe) static var publishers: [ObjectIdentifier: ObservableObjectPublisher] = [:]
    static let lock = NSLock()
}

public protocol ObservableObject: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
}

public extension ObservableObject {
    /// One publisher per object, made on first use.
    var objectWillChange: ObservableObjectPublisher {
        PublisherStore.lock.lock()
        defer { PublisherStore.lock.unlock() }
        let id = ObjectIdentifier(self)
        if let publisher = PublisherStore.publishers[id] { return publisher }
        let publisher = ObservableObjectPublisher()
        PublisherStore.publishers[id] = publisher
        return publisher
    }
}

/// Tells the enclosing ObservableObject before the value changes.
@propertyWrapper
public struct Published<Value> {
    private var value: Value

    public init(wrappedValue: Value) {
        value = wrappedValue
    }

    @available(*, unavailable, message: "@Published is only available on properties of classes")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    public static subscript<EnclosingSelf: AnyObject>(
        _enclosingInstance object: EnclosingSelf,
        wrapped _: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Published<Value>>,
    ) -> Value {
        get { object[keyPath: storageKeyPath].value }
        set {
            (object as? any ObservableObject)?.objectWillChange.send()
            object[keyPath: storageKeyPath].value = newValue
        }
    }
}
