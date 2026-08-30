import Foundation

/// Fires the ad server's tracking URLs for one served ad. Same rules as the
/// web tracker in video-ad-formats: `[CACHEBUSTING]` becomes a fresh random
/// number per fire, any other `[MACRO]` becomes empty (VAST forbids firing a
/// literal macro), and every URL fires at most once — the server dedupes
/// `/view` and `/click` but records each `/event` hit.
///
/// Pings are `POST`s. The URLs are pixel-shaped (VAST players GET them);
/// the ad server's `/impression/:id/{view,event,click}` accept both, and
/// `/event` reads the event from the query for GET or from the body for
/// POST — so the body repeats the query's `e=` to work either way.
@MainActor
final class AdTracker {
    enum Event: CaseIterable {
        case impression, creativeView, viewable, notViewable, viewUndetermined, close, overlayViewDuration, clickTracking
    }

    /// VAST linear events for video creatives.
    enum VideoEvent: CaseIterable {
        case start, firstQuartile, midpoint, thirdQuartile, complete, skip, mute, unmute
    }

    private let tracking: VideoAdTracking
    private var fired: Set<Event> = []
    private var firedVideo: Set<VideoEvent> = []
    private let session: URLSession
    /// Set once one of the three viewability verdicts fired.
    private(set) var viewabilityDecided = false

    init(tracking: VideoAdTracking, session: URLSession = .shared) {
        self.tracking = tracking
        self.session = session
    }

    func fire(_ event: Event) {
        guard fired.insert(event).inserted else { return }
        if [.viewable, .notViewable, .viewUndetermined].contains(event) {
            guard !viewabilityDecided else { return }
            viewabilityDecided = true
        }
        send(rawURL(for: event))
    }

    /// Fires a VAST linear event once. Mute/unmute may repeat per toggle.
    func fireVideo(_ event: VideoEvent) {
        guard let video = tracking.video else { return }
        if event != .mute, event != .unmute {
            guard firedVideo.insert(event).inserted else { return }
        }
        let raw: String?
        switch event {
        case .start: raw = video.start
        case .firstQuartile: raw = video.firstQuartile
        case .midpoint: raw = video.midpoint
        case .thirdQuartile: raw = video.thirdQuartile
        case .complete: raw = video.complete
        case .skip: raw = video.skip
        case .mute: raw = video.mute
        case .unmute: raw = video.unmute
        }
        if let raw { send(raw) }
    }

    private func send(_ raw: String) {
        guard let url = URL(string: Self.substituteMacros(in: raw)) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = [:]
        if let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "e" || $0.name == "event" })?.value {
            body["event"] = name
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: request).resume()
    }

    private func rawURL(for event: Event) -> String {
        switch event {
        case .impression: return tracking.impression
        case .creativeView: return tracking.creativeView
        case .viewable: return tracking.viewable
        case .notViewable: return tracking.notViewable
        case .viewUndetermined: return tracking.viewUndetermined
        case .close: return tracking.close
        case .overlayViewDuration: return tracking.overlayViewDuration
        case .clickTracking: return tracking.clickTracking
        }
    }

    static func substituteMacros(in url: String) -> String {
        var result = ""
        var rest = Substring(url)
        while let open = rest.firstIndex(of: "[") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "]") else {
                result += rest[open...]
                return result
            }
            let macro = rest[rest.index(after: open)..<close]
            if macro == "CACHEBUSTING" {
                result += String(Int.random(in: 10_000_000...99_999_999))
            } else if macro == "TIMESTAMP" {
                result += iso8601Now().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
