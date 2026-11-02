/// What a failing ad throws and reports: the error a call on an ad that ended before `show` throws, and a
/// creative's failure as a fault report.
extension VideoAd {
    /// What a call on an ad that ended before `show` throws. A destroyed one throws `destroyed`, never
    /// `invalidated(.destroyed)`: one error for one fact, whichever call finds it.
    static func error(for reason: InvalidationReason) -> VideoAdError {
        reason == .destroyed ? .destroyed : .invalidated(reason)
    }

    /// The creative's error as a fault report. The bridge says why it failed: the page, a load timeout, a page
    /// that could not load, or a terminated web process all fire the same VAST codes.
    func reportCreativeError(vastCode: Int) {
        let code: ErrorReporter.Code
        switch loadedBridge?.failureCause ?? .page {
        case .page: code = .creativeFailed
        case .loadTimeout: code = .loadTimeout
        case .loadFailed: code = .frameLoadFailed
        case .processTerminated: code = .processTerminated
        }
        let recovery: ErrorReporter.Recovery = wasShown ? .adEndedFailed : .adDroppedBeforeShow
        ErrorReporter.shared.report(code, stage: wasShown ? .playback : .load, sessionId: owner?.sessionId, adId: id, vastCode: vastCode,
                                    underlying: loadedBridge?.failureUnderlying, recovery: recovery)
    }
}
