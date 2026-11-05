import Foundation

/// What the frame page reports, as beacons, the ad's state and the delegate: `VideoAd`'s half of the frame
/// protocol, the bridge (`FrameBridge`) being the other.
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
        withContentPlayhead(alsoFor: urls) { handleNow(event) }
    }

    private func handleNow(_ event: FrameEvent) {
        // The bridge stops delivering once hidden; this is the same rule at the ad's own door.
        guard !hasEnded, invalidationReason == nil else { return }
        switch event {
        case .loaded:
            state.markLoaded()
            tracker.fire("loaded")
            loadContinuation?.resume()
            loadContinuation = nil
        case .error(let code):
            tracker.fire("error", errorCode: code)
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
            if purpose == "adChoices" {
                tracker.fire("iconClick")
            }
            Self.open(url, fallback: nil)
        case .close(let reason):
            // The page's own close control; not fired for the app's dismiss() or destroy(), except as the
            // outcome of a video that never started (`endNow`). A fact of the linear format, not of its screen.
            //
            // How a page's close and skip end an ad, and why a linear ad's close can be a skip:
            //
            //   what the viewer does (linear ad)        message        result
            //   taps Skip, after the skip offset        ad.skip        `skip` beacon, .skipped
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
        case .skip(let playhead):
            tracker.adPlayhead = playhead
            // Checkpoints the video passed before the skip that the page never reported, then the skip.
            tracker.fireProgress(upTo: playhead)
            tracker.fire("skip")
            end(.skipped)
        case .video(let event, let playhead):
            tracker.adPlayhead = playhead
            Logger.debug("ad \(id.prefix(8)): video.\(event.rawValue)")
            switch event {
            case .start, .resume: isVideoPlaying = true
            case .pause: isVideoPlaying = false
            default: break
            }
            meter?.countsTime = isVideoPlaying
            tracker.fire(event.rawValue)
            tracker.fireProgress(upTo: playhead)
            // The delegate last: it may end the ad on the spot, and everything above was the event's own.
            if event == .start {
                recordImpression()
            }
        case .progress(let offset, let playhead):
            tracker.adPlayhead = playhead
            tracker.fireProgress(upTo: max(offset, playhead))
        case .complete(let playhead):
            tracker.adPlayhead = playhead
            state.markCompleted()
            isVideoPlaying = false
            meter?.countsTime = false   // the end card is not the video playing
            // Checkpoints before the end that the page never reported, then the end itself.
            tracker.fireProgress(upTo: playhead)
            tracker.fire("complete")
            // The end card, when there is one, becomes visible now.
            tracker.fire("creativeView", part: "endCard")
            Logger.info("ad \(id.prefix(8)): complete")
        }
    }
}

extension FrameEvent.CloseReason {
    /// What a page's `ad.close` does to an ad: the beacon it fires, if any, how the ad ends, and whether it completes it.
    /// `self` is the close reason the page gave: close (the viewer's close button), resume (a pause ad's Resume button) or
    /// complete (the page ended itself after the video, with no end card). `isLinear`: a linear (video) ad. `isCompleted`:
    /// the video already reached its end, which the SDK knows from the page's `complete` event, never from a close.
    ///
    /// The rows are checked top to bottom; the first that matches wins:
    ///
    /// ```
    ///   #  when                          beacon  ends as       meaning
    ///   1  linear and not completed      skip    .skipped      the viewer left a video ad before it finished: a skip for
    ///      (any reason)                                        tracking, by the close button or anything else
    ///   2  reason complete               none    .completed    the ad ended by itself after its video ran out (it also
    ///                                            (completes)   marks the ad completed); nobody closed it, so no close
    ///   3  reason resume                 close   .resumed      a pause ad's Resume button: closed to continue watching
    ///   4  anything else (close)         close   .closed       closed with the close button: an overlay, a pause ad, or a
    ///                                                          linear ad's end card after the video finished
    /// ```
    ///
    /// Examples:
    /// - A linear ad closed at second 10 of 30: row 1, `skip`, .skipped.
    /// - A linear ad, video finished, the end card's close button: not row 1 (completed); reason close, row 4: `close`, .closed.
    /// - A linear ad, video finished, no end card: the page sends complete, row 2: no beacon, .completed.
    /// - An overlay's close button: not linear, row 4: `close`, .closed.
    /// - A pause ad's Resume: row 3: `close`, .resumed.
    ///
    /// Row 1 comes first on purpose: a linear ad whose page says complete without the SDK having seen the video's
    /// `complete` is a skip. The SDK trusts its own record of what was watched, which is what advertisers pay for.
    func outcome(isLinear: Bool, isCompleted: Bool) -> (beacon: String?, endReason: VideoAd.EndReason) {
        if isLinear, !isCompleted { return ("skip", .skipped) }
        switch self {
        case .complete: return (nil, .completed)
        case .resume: return ("close", .resumed)
        case .close: return ("close", .closed)
        }
    }
}
