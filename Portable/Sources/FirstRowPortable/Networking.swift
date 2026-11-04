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

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var responseHandler: ((Result<URLResponse, Error>) -> Void)?

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        responseHandler?(.success(response))
        responseHandler = nil
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            responseHandler?(.failure(error))
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        responseHandler = nil
        session.finishTasksAndInvalidate()
    }
}

extension URLSession {
    /// Streams a response body, returning once the headers have arrived.
    public func bytes(for request: URLRequest) async throws -> (URLSessionByteStream, URLResponse) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error> { continuation = $0 }
        let delegate = StreamingDelegate(continuation: continuation)
        let response: URLResponse = try await withCheckedThrowingContinuation { waiter in
            delegate.responseHandler = { waiter.resume(with: $0) }
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: request).resume()
        }
        return (URLSessionByteStream(chunks: stream), response)
    }
}

/// Objective-C's autorelease pools don't exist here; the body just runs.
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
