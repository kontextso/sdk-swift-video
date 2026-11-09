import Foundation

/// The checks of how the app uses the SDK: a call before `initialize(with:)`, an unusable configuration, a
/// video's content the server would refuse, a user with empty fields. Each is a mistake in the app's code, not a
/// runtime condition, and each is handled the same way: a debug build stops at it (`Environment.assertionFailure`,
/// with the message), a release build logs it and carries on, and what Kontext should hear of is reported
/// (`ErrorReporter`, stage `integration`).
///
/// No main-thread check: every public type is `@MainActor`, so the compiler refuses a call from elsewhere.
/// `KontextVideo` and `VideoAds` call these where the mistake is made.
@MainActor
enum IntegrationGuard {
    /// Guards a call that needs `initialize(with:)` to have been called first.
    ///
    /// Calling the SDK before initialising it is a mistake in the app's code, not a runtime condition,
    /// so it is handled the way Swift handles programmer errors: `assertionFailure` stops a debug build
    /// on the first run with the message, where a log line could be overlooked (a common choice for an
    /// SDK's configure call). A release build only logs and carries on, because the
    /// order of calls in a real app is not always deterministic and the SDK must not take the app down in
    /// front of users. Not `throws`: that would put `try` on every publisher's call for a mistake most
    /// never make.
    @discardableResult
    static func requireInitialized(_ call: String) -> Bool {
        guard !KontextVideo.shared.isInitialized else { return true }
        Environment.assertionFailure("KontextVideo: call initialize(with:) before \(call)")
        Logger.error("\(call) called before initialize(with:); no ads will load")
        // Kept in memory: it leaves if the app initializes later and `/config` turns the reports on.
        ErrorReporter.shared.report(.notInitialized, detail: call)
        return false
    }

    /// The configuration `initialize(with:)` was given: a mistake there makes every request fail. Stops a debug
    /// build here, not at a 400 later.
    static func checkConfiguration(_ configuration: KontextVideo.Configuration) {
        let problems = configuration.problems
        guard !problems.isEmpty else { return }
        Environment.assertionFailure("KontextVideo.Configuration: \(problems.joined(separator: ", "))")
        Logger.error("configuration: \(problems.joined(separator: ", ")); no ads will load")
        if configuration.publisherToken.isEmpty { ErrorReporter.shared.report(.emptyToken) }
        if problems.contains(where: { $0.hasPrefix("adServerURL") }) {
            ErrorReporter.shared.report(.badServerURL)
        }
    }

    /// A video's content, said once at `VideoAds(content:)` rather than as a server 400 later. An empty id or
    /// language makes every request fail: a programmer error, which stops a debug build. The rest is metadata the
    /// request leaves out.
    static func checkContent(_ content: KontextVideo.Content, sessionId: String) {
        let missing = content.missingRequired
        if !missing.isEmpty {
            Environment.assertionFailure("KontextVideo.Content: \(missing.joined(separator: ", "))")
            Logger.error("content \(content.id): \(missing.joined(separator: ", ")); the server will refuse its requests")
            ErrorReporter.shared.report(.badContent, sessionId: sessionId, detail: missing.joined(separator: ","))
        }
        if !content.leftOut.isEmpty {
            Logger.warning("content \(content.id): \(content.leftOut.joined(separator: ", "))")
        }
    }

    /// Said once per launch: the app asked the SDK for the ATT dialog without the Info.plist's reason.
    private static var hasWarnedAboutTrackingUsageDescription = false

    /// Whether the app's Info.plist has a non-empty `NSUserTrackingUsageDescription`, which the ATT dialog needs:
    /// iOS terminates an app that requests tracking authorization without it. Missing with
    /// `requestTrackingAuthorization: true`: a debug build stops (once), a release build logs and never shows the dialog.
    static func hasTrackingUsageDescription() -> Bool {
        if let reason = Environment.trackingUsageDescription(), !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard !hasWarnedAboutTrackingUsageDescription else { return false }
        hasWarnedAboutTrackingUsageDescription = true
        let message = "requestTrackingAuthorization: true needs NSUserTrackingUsageDescription in the app's Info.plist; the ATT dialog is not shown"
        Environment.assertionFailure("KontextVideo.Configuration: \(message)")
        Logger.error(message)
        return false
    }

    /// Tests only: the once-per-launch warning can be given again.
    static func resetForTesting() {
        hasWarnedAboutTrackingUsageDescription = false
    }

    /// The viewer the app set: an empty field is left out of the requests; an empty `id` is a programmer error.
    static func checkUser(_ user: KontextVideo.User?) {
        guard let empty = user?.emptyFields, !empty.isEmpty else { return }
        if empty.contains("id") { Environment.assertionFailure("KontextVideo.User: id is empty") }
        Logger.warning("user: \(empty.joined(separator: ", ")) empty, left out of the requests")
    }
}

/// The configuration's check, which `checkConfiguration` reports.
extension KontextVideo.Configuration {
    /// What is wrong with the options, one phrase each; empty when they are usable.
    var problems: [String] {
        var problems: [String] = []
        if publisherToken.isEmpty { problems.append("publisherToken is empty") }
        if let problem = Self.problem(with: adServerURL) { problems.append("adServerURL \(adServerURL) \(problem)") }
        return problems
    }

    /// What is wrong with a server URL, or `nil`: an `http` or `https` base with a host, a port within 1-65535 when
    /// given, and nothing the routes cannot be appended to (credentials, a query, a fragment). A path is a base
    /// the routes go under.
    private static func problem(with url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), (url.host ?? "").isEmpty == false else { return "is not absolute" }
        guard scheme == "http" || scheme == "https" else { return "is not http or https" }
        if let port = url.port, !(1...65_535).contains(port) { return "has an invalid port" }
        if url.user != nil || url.password != nil { return "carries credentials" }
        if url.query != nil || url.fragment != nil { return "has a query or a fragment" }
        return nil
    }
}
