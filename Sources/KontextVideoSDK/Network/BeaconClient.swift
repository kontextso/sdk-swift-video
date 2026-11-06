import Foundation

/// Sends beacons: a GET of a tracking URL, once, with no retries, fire and forget. Only the status is read, never
/// the body. Which beacons fire and when is `Tracker`'s; this only delivers a finished URL. Redirects are followed
/// as `URLSession` does, at most `RedirectLimit.maxRedirects`. One deadline bounds a beacon's whole exchange, redirects
/// included: the session's `timeoutIntervalForResource` (`Environment.makeSession`, 10 s); the request's
/// `timeoutInterval` is idle time only. The Kotlin SDK's `BeaconClient` is the same.
@MainActor
enum BeaconClient {
    /// GETs `url` through `session` (the SDK's, `Environment.session`); `label` names it in the log
    /// (`ad f1a2b3c4: impression`).
    static func send(_ url: URL, label: String, over session: URLSession = Environment.session) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        Logger.debug("\(label) beacon")
        let task = BeaconTransport.session(over: session).dataTask(with: request)
        task.taskDescription = "\(label) beacon"
        task.resume()
    }
}

/// Fires beacons without keeping what the server answers: the status is all a beacon needs, and a body
/// (a tracking pixel, or a misconfigured endpoint sending megabytes) must never be accumulated in the app.
/// A completion-handler task buffers the whole body before it calls back, so beacons go through a session
/// whose delegate cancels each transfer as soon as the response head arrives, after logging an error
/// status. Fire and forget: nothing waits for the outcome. A session delegate rather than a per-task one
/// (iOS 15+), so iOS 14 behaves the same. It limits redirects as every SDK session does (`RedirectLimit`).
final class BeaconTransport: RedirectLimit, URLSessionDataDelegate, @unchecked Sendable {
    /// The beacon session derived from `base` (the SDK's session, `Environment.session`): its configuration,
    /// this delegate. Made again only when the base changes, which only the tests do.
    @MainActor private static var current: (base: URLSession, beacons: URLSession)?

    @MainActor
    static func session(over base: URLSession) -> URLSession {
        if let current, current.base === base { return current.beacons }
        current?.beacons.finishTasksAndInvalidate()
        // A tracking chain may hand a beacon on to a plain `http` server.
        let beacons = URLSession(configuration: base.configuration, delegate: BeaconTransport(allowsDowngrade: true), delegateQueue: nil)
        current = (base, beacons)
        return beacons
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            Logger.warning("\(dataTask.taskDescription ?? "beacon") answered \(status)")
        }
        // The server answered: the beacon arrived. The body is never read.
        completionHandler(.cancel)
    }

    override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        super.urlSession(session, task: task, didCompleteWithError: error)
        guard let error else { return }
        let nsError = error as NSError
        // Our own cancellation after the response head, not a failure.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        Logger.warning("\(task.taskDescription ?? "beacon") failed, \(error.localizedDescription)")
    }
}
