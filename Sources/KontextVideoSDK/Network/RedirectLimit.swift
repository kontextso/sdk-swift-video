import Foundation

/// The SDK's sessions' delegate: it stops a request after `maxRedirects` redirects, the SDK's own requests and
/// beacons alike, and never follows one to a scheme other than `http` or `https`. `URLSession` follows redirects
/// by itself otherwise, as the SDK wants: a 307 or 308 sends a POST again, body and all. From `https` to `http`
/// only where `allowsDowngrade`: beacons, as tracking chains hand them on through plain servers (within App
/// Transport Security); never the SDK's own API requests, whose body (identifiers, consent) a re-sent POST would
/// carry in clear in an app that allows arbitrary loads. Past the limit, or refused, the redirect is not followed
/// and the task ends with that 3xx answer. The Kotlin SDK's `HttpTransport` has the same rules.
class RedirectLimit: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // `@unchecked Sendable`: `counts` is only touched under `lock`; URLSession calls it on its own queue.

    /// The most redirects any request follows: tracking chains hand a beacon on through several servers, and our
    /// server could move behind another host.
    static let maxRedirects = 10

    /// Whether a redirect from `https` to `http` is followed.
    let allowsDowngrade: Bool
    private let lock = NSLock()
    /// Redirects followed so far, by task.
    private var counts: [Int: Int] = [:]

    init(allowsDowngrade: Bool) {
        self.allowsDowngrade = allowsDowngrade
    }

    /// Whether a redirect from `from` to `to` may be followed, by its schemes alone.
    static func allows(from: URL?, to: URL?, allowsDowngrade: Bool) -> Bool {
        guard let target = to?.scheme?.lowercased(), ["http", "https"].contains(target) else { return false }
        return allowsDowngrade || from?.scheme?.lowercased() != "https" || target == "https"
    }

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
        let isAllowed = Self.allows(from: response.url, to: request.url, allowsDowngrade: allowsDowngrade)
        completionHandler(isAllowed && mayFollow(task.taskIdentifier) ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        forget(task.taskIdentifier)
    }
}
