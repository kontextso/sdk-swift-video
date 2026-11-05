/// How a page's `ad.close` ends an ad, as a pure rule over plain values: the close reason the page gave, whether the
/// ad is linear, and whether its video completed. The ad's state decides it, so it lives with the state; the ad
/// carries it out (`VideoAd+FrameEvents`).
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
