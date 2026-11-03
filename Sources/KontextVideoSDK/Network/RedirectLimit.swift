import Foundation

/// The SDK's sessions' delegate: it stops a request after `maxRedirects` redirects, the SDK's own requests and
/// beacons alike. `URLSession` follows redirects by itself otherwise, as the SDK wants: a 307 or 308 sends a
/// POST again, body and all; `http` to `https` and back, as tracking chains do, within App Transport Security.
/// Past the limit the redirect is not followed and the task ends with that 3xx answer. The Kotlin SDK's
/// `HttpTransport` has the same limit.
class RedirectLimit: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // `@unchecked Sendable`: `counts` is only touched under `lock`; URLSession calls it on its own queue.

    /// The most redirects any request follows: tracking chains hand a beacon on through several servers, and our
    /// server could move behind another host.
    static let maxRedirects = 10

    private let lock = NSLock()
    /// Redirects followed so far, by task.
    private var counts: [Int: Int] = [:]

    /// Whether `task` may follow one more redirect; counts it when it may.
    func mayFollow(_ task: Int) -> Bool {
        lock.withLock {
            let count = counts[task, default: 0]
            guard count < Self.maxRedirects else { return false }
            counts[task] = count + 1
            return true
        }
    }

    /// The task is over: its count goes.
    func forget(_ task: Int) {
        lock.withLock { _ = counts.removeValue(forKey: task) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(mayFollow(task.taskIdentifier) ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        forget(task.taskIdentifier)
    }
}
