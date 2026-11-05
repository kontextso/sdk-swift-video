import AppTrackingTransparency
import Foundation

/// One ads request at a time for one `VideoAds`, shared by every `format(_:)` that waits meanwhile.
///
/// Why its own type: the request is a sequence of waits and checks the `VideoAds` must not be inside of. It belongs
/// to the `VideoAds`, not to a caller: nobody cancels it but `destroy()` or the release. It holds its owner weakly
/// and only between its waits, so releasing the owner mid-request reaches its `deinit`, which cancels it.
///
/// `fetch()` runs, once per request:
/// 1. wait for `/config` (switched off or failed: no request);
/// 2. the ATT dialog, when the publisher left it to the SDK, before the first request;
/// 3. the body (`AdsRequest`), with the held ids read after the waits, so an ad shown, rejected or expired during
///    them is not sent as held;
/// 4. the POST; an answer that brings, under one format, the id of an ad held under another is malformed;
/// 5. a failure is reported once here, and thrown as the request error every caller gets;
/// 6. the answer: the kill switch switches the SDK off and drops every ad; each dropped ad is reported; the rest
///    goes to the owner, which follows it (`AdStore.plan`) and returns the no-fill reasons by format.
@MainActor
final class AdsFetcher {
    /// The no-fill reasons by format of one answer.
    typealias NoFills = [AdFormat: VideoAdError.NoFillReason]

    private weak var owner: VideoAds?
    /// The request in flight: every `format(_:)` meanwhile waits for it instead of sending another.
    private var request: Task<NoFills, Error>?

    init(owner: VideoAds) {
        self.owner = owner
    }

    /// The request in flight, or a new one.
    func fetch() -> Task<NoFills, Error> {
        request ?? start()
    }

    /// `destroy()` or the release: the request in flight stops at its next wait.
    func cancel() {
        request?.cancel()
    }

    private func start() -> Task<NoFills, Error> {
        guard let owner else { return Task { throw VideoAdError.destroyed } }
        let content = owner.content
        let labels = owner.labels
        let sessionId = owner.sessionId
        let task = Task { [weak self, weak owner] () throws -> NoFills in
            defer { self?.request = nil }
            /// The owner, for one synchronous step; `destroyed` once it was destroyed or released.
            @MainActor func current() throws -> VideoAds {
                guard let owner, !owner.isDestroyed else { throw VideoAdError.destroyed }
                return owner
            }
            // 1. `/config`.
            let isEnabled: Bool
            do {
                isEnabled = try await KontextVideo.shared.waitUntilEnabled()
            } catch {
                // Only `destroy()` or the release cancels the request: it stops waiting for `/config`, which goes on.
                throw VideoAdError.destroyed
            }
            // Destroyed while waiting: `destroyed`, whatever `/config` said meanwhile.
            _ = try current()
            guard isEnabled else {
                Logger.warning("\(content.id): not requested, the SDK is \(KontextVideo.shared.state)")
                if let reason = KontextVideo.shared.disabledReason { throw VideoAdError.disabled(reason: reason) }
                throw VideoAdError.initializationFailed
            }
            guard let configuration = KontextVideo.shared.configuration else { throw VideoAdError.notInitialized }
            // 2. The ATT dialog. Its answer is read with the rest of the privacy fields, after the last wait.
            let answered: ATTrackingManager.AuthorizationStatus?
            do {
                answered = try await TrackingInfo.authorizeIfNeeded(requestAuthorization: configuration.requestTrackingAuthorization)
            } catch {
                // Its callers stop waiting for the dialog, which goes on.
                throw VideoAdError.destroyed
            }
            // 3. What is held is read after the waits (`/config`, the ATT dialog): an ad shown, rejected or expired
            // during them is not sent as held, or the server would re-serve it and the format answer no-fill.
            let held = try current().validHeldIds()
            let playhead = try current().playhead
            let body = await AdsRequest.make(sdk: KontextVideo.shared, configuration: configuration, tracking: TrackingInfo.read(answered: answered), content: content,
                                             labels: labels, player: .make(playhead: playhead), sessionId: sessionId, held: held)
            // Another video's response may have switched the SDK off during the dialog or the build: nothing leaves.
            try current().checkStillUsable()
            try current().requestWasSent(body.requestId)
            Logger.debug("\(content.id): requesting at playhead \(body.player.playhead) ms, holding \(held.count)")
            DebugReporter.shared.event("ads.request", state: ["held": .number(Double(held.count)), "playhead": .number(Double(body.player.playhead))])

            // 4. The POST, and the ids against what is held.
            let response: AdsResponse
            do {
                response = try await APIClient(baseURL: body.adServerURL).post("video/ads", body: body)
                try Self.checkIdsAgainstHeld(response, held: current().store.ads)
            } catch {
                // 5. Once per request, here in the request every caller shares, not once per waiting caller.
                try current().checkStillUsable()
                Logger.error("\(content.id): request \(body.requestId) failed, \(error)")
                let failure = ErrorReport.FailedRequest(error)
                let isDecoding: Bool = (error as? APIError)?.isDecoding ?? false
                let recovery: ErrorReport.Recovery = try current().holdsAds ? .heldAdsKept : .noAd
                ErrorReporter.shared.report(isDecoding ? .adsDecodeFailed : .adsRequestFailed, stage: .request, requestId: body.requestId,
                                            sessionId: sessionId, failure: failure, recovery: recovery)
                throw VideoAdError.request(VideoAdError.RequestFailure(error))
            }
            // 6. The answer.
            return try Self.receive(response, requestId: body.requestId, owner: current())
        }
        request = task
        return task
    }

    /// The answer, for a `VideoAds` still in use. The kill switch in it switches the whole SDK off and drops every
    /// ad, with no notices: the server knows. Switched off meanwhile by another video's response: the answer is
    /// dropped, the ads it carries are never held.
    private static func receive(_ response: AdsResponse, requestId: String, owner: VideoAds) throws -> NoFills {
        if case .disabled(let reason) = response {
            KontextVideo.shared.disable(reason: reason)
            // The reason is never seen: load() and show throw `.disabled` first.
            for ad in Array(owner.store.ads.values) { ad.invalidate(.destroyed) }
            throw VideoAdError.disabled(reason: reason)
        }
        try owner.checkStillUsable()
        reportDroppedAds(response, requestId: requestId, owner: owner)
        return owner.follow(response)
    }

    /// One id is one bid, across answers as within one: an answer that brings, under one format, the id of an ad
    /// held under another (whose format the answer may leave out, so it stays) is malformed as a whole, before
    /// anything held or spent changes, as an id listed twice in one answer is. Otherwise rejecting one copy would
    /// leave the other valid, to be shown after its `notUsed`.
    private static func checkIdsAgainstHeld(_ response: AdsResponse, held: [AdFormat: VideoAd]) throws {
        guard case .formats(let results) = response else { return }
        for result in results {
            for payload in result.ads {
                guard let other = held.first(where: { $0.key != result.format && $0.value.id == payload.id }) else { continue }
                throw APIError.decoding(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "ad \(payload.id) is \(result.format), and held as \(other.key)")))
            }
        }
    }

    /// An ad that did not decode was dropped from its format, the rest of the answer stands: each is reported once
    /// here, in the request every caller shares, with its format and the field that failed.
    private static func reportDroppedAds(_ response: AdsResponse, requestId: String, owner: VideoAds) {
        guard case .formats(let results) = response else { return }
        for result in results {
            for path in result.dropped {
                Logger.error("\(result.format) for \(owner.content.id): an ad of request \(requestId) is malformed at \(path); dropped")
                ErrorReporter.shared.report(.adsDecodeFailed, stage: .request, requestId: requestId, sessionId: owner.sessionId,
                                            detail: "\(result.format.rawValue):\(path)", recovery: result.ads.isEmpty ? .noAd : nil)
            }
        }
    }
}
