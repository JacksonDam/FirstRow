import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A download's bytes as they arrive, like URLSession.AsyncBytes on Apple platforms.
public struct URLSessionByteStream: AsyncSequence, Sendable {
    public typealias Element = UInt8
    let chunks: AsyncThrowingStream<Data, Error>

    public struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: AsyncThrowingStream<Data, Error>.AsyncIterator
        var current = Data()
        var index = 0

        public mutating func next() async throws -> UInt8? {
            while index >= current.count {
                guard let chunk = try await chunks.next() else { return nil }
                current = chunk
                index = 0
            }
            defer { index += 1 }
            return current[current.startIndex + index]
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks.makeAsyncIterator())
    }
}

/// Streams every download through one session that lasts as long as First Row does. (A session
/// for each download is torn down when it ends, and this Foundation can abort the whole process
/// while doing that: "_MultiHandle deallocated with non-zero retain count".)
private final class StreamingHub: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamingHub()

    private struct Download {
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
        var responseHandler: ((Result<URLResponse, Error>) -> Void)?
    }

    private let lock = NSLock()
    private var downloads: [Int: Download] = [:]
    private var session: URLSession?

    /// Starts `request`, giving its headers to `responseHandler` and its body to `continuation`.
    func start(_ request: URLRequest, configuration: URLSessionConfiguration, continuation: AsyncThrowingStream<Data, Error>.Continuation,
               responseHandler: @escaping (Result<URLResponse, Error>) -> Void)
    {
        lock.lock()
        let session = self.session ?? URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        downloads[task.taskIdentifier] = Download(continuation: continuation, responseHandler: responseHandler)
        lock.unlock()
        // Whoever was reading has stopped: the rest isn't wanted.
        continuation.onTermination = { [weak task] reason in
            if case .cancelled = reason { task?.cancel() }
        }
        task.resume()
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let handler = downloads[dataTask.taskIdentifier]?.responseHandler
        downloads[dataTask.taskIdentifier]?.responseHandler = nil
        lock.unlock()
        handler?(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let continuation = downloads[dataTask.taskIdentifier]?.continuation
        lock.unlock()
        continuation?.yield(data)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let download = downloads.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let download else { return }
        if let error {
            download.responseHandler?(.failure(error))
            download.continuation.finish(throwing: error)
        } else {
            download.continuation.finish()
        }
    }
}

extension URLSession {
    /// Streams a response body, returning once the headers have arrived.
    public func bytes(for request: URLRequest) async throws -> (URLSessionByteStream, URLResponse) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error> { continuation = $0 }
        let configuration = configuration
        let response: URLResponse = try await withCheckedThrowingContinuation { waiter in
            StreamingHub.shared.start(request, configuration: configuration, continuation: continuation) { waiter.resume(with: $0) }
        }
        return (URLSessionByteStream(chunks: stream), response)
    }
}

/// Objective-C's autorelease pools don't exist here; the body just runs.
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
