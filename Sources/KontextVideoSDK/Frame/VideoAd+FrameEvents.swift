import Foundation

/// What the ad does with each event its page reports: its state, its beacons (`Tracker.record`), the delegate and
/// its end. `VideoAd`'s half of the frame protocol: `FrameBridge` accepts a message under `FrameProtocol`'s rules
/// and hands the event here (`handle`); a click goes on to `VideoAd.click`, a close through `CloseOutcome`.
extension VideoAd {
    /// What the page reports, mapped to the beacons and the delegate: `handleNow` with the content playhead
    /// read once first, when any URL of the moment asks for it (`[CONTENTPLAYHEAD]`), so every beacon of one
    /// event carries the same time and the app's player is asked once. The tracking URLs came from the ad
    /// server, and the tracker knows by itself whether one asks. A click is the one event that brings URLs of its
    /// own, the click-through and its fallback, which the SDK fills in too (`Tracker.clickThrough`): they are
    /// passed so a macro in them alone is found. An `open`'s URL is opened as it is, with no macros.
    func handle(_ event: FrameEvent) {
        var urls: [URL] = []
        if case .click(let url, let fallbackUrl, _) = event { urls = [url] + (fallbackUrl.map { [$0] } ?? []) }
        tracker.withContentPlayhead(alsoFor: urls) { handleNow(event) }
    }

    private func handleNow(_ event: FrameEvent) {
        // The bridge stops delivering once hidden; this is the same rule at the ad's own door.
        guard !hasEnded, invalidationReason == nil else { return }
        switch event {
        case .loaded:
            state.markLoaded()
            tracker.record(event)
            loadContinuation?.resume()
            loadContinuation = nil
        case .error(let code):
            tracker.record(event)
            reportCreativeError(vastCode: code)
            if let continuation = loadContinuation {
                loadContinuation = nil
                Logger.warning("ad \(id.prefix(8)): creative failed to load, VAST error \(code)")
                continuation.resume(throwing: VideoAdError.creativeFailed(code: code))
            } else if wasShown {
                Logger.warning("ad \(id.prefix(8)): creative failed after show, VAST error \(code)")
                fail(.creativeFailed(code: code))
            } else {
                // Died while waiting to be shown: the ad ends; `show` will throw.
                invalidate(.creativeFailed(code: code))
            }
        case .click(let url, let fallbackUrl, let area):
            click(url, fallback: fallbackUrl, area: area)
        case .open(let url, let purpose):
            Logger.info("ad \(id.prefix(8)): open (\(purpose)) \(url.absoluteString)")
            tracker.record(event)
            LinkOpener.open(url, fallback: nil)
        case .close(let reason):
            // The page's own close control; not fired for the app's dismiss() or destroy(), except as the
            // outcome of a video that never started (`endNow`). A fact of the linear format, not of its screen.
            //
            // How a page's close and skip end an ad, and why a linear ad's close can be a skip:
            //
            //   what the viewer does (linear ad)        message        result
            //   taps Skip, after the skip offset        video.skip     `skip` beacon, .skipped
            //   taps Close before the video finished    ad.close       `skip` beacon, .skipped
            //   closes the end card after the video     ad.close       `close` beacon, .closed
            //   nothing: the video ended, no end card   ad.close       .completed, no `close` (nobody closed anything)
            //
            // For a video ad what counts is whether the viewer watched it to the end. Leaving early is a skip, through
            // Skip or through Close alike, as video ad tracking counts it; `close` is for closing what already finished.
            // `isCompleted` is set only by the page's `complete` event, never by a close. Overlay and pause ads have no
            // "watch to the end": a close is .closed, or .resumed when it resumed the content.
            let outcome = reason.outcome(isLinear: format == .linear, isCompleted: isCompleted)
            if outcome.endReason == .completed { state.markCompleted() }
            if let beacon = outcome.beacon { tracker.fire(beacon) }
            end(outcome.endReason)
        case .skip:
            tracker.record(event)
            end(.skipped)
        case .video(let moment, _):
            Logger.debug("ad \(id.prefix(8)): video.\(moment.rawValue)")
            switch moment {
            case .start, .resume: state.markVideoPlaying(true)
            case .pause: state.markVideoPlaying(false)
            default: break
            }
            meter?.countsTime = state.isVideoPlaying
            tracker.record(event)
            // The delegate last: it may end the ad on the spot, and everything above was the event's own.
            if moment == .start {
                recordImpression()
            }
        case .progress:
            tracker.record(event)
        case .complete:
            state.markCompleted()
            state.markVideoPlaying(false)
            meter?.countsTime = false   // the end card is not the video playing
            tracker.record(event)
            Logger.info("ad \(id.prefix(8)): complete")
        }
    }
}
