/// What a failing ad throws and reports: the error a call on an ad that ended before `show` throws, and a
/// creative's failure as a fault report.
extension VideoAd {
    /// What a call on an ad that ended before `show` throws. A destroyed one throws `destroyed`, never
    /// `invalidated(.destroyed)`: one error for one fact, whichever call finds it.
    static func error(for reason: InvalidationReason) -> VideoAdError {
        reason == .destroyed ? .destroyed : .invalidated(reason)
    }

    /// `show(in:)` on a linear ad, `show(from:)` on an overlay or pause ad: a programmer error, found as early as
    /// the single `VideoAd` type allows, at the call. It stops a debug build with the call to use; a release
    /// build logs it and throws, and the ad stays as it was.
    func wrongShowMethod(_ call: String, use other: String) -> VideoAdError {
        Environment.assertionFailure("VideoAd.\(call) on a \(format) ad; use \(other)")
        Logger.error("ad \(id.prefix(8)): \(call) on a \(format) ad does nothing; a \(format) ad is shown with \(other)")
        return .wrongShowMethod
    }

    /// The creative's error as a fault report. The bridge says why it failed: the page, a load timeout, a page
    /// that could not load, or a terminated web process all fire the same VAST codes.
    func reportCreativeError(vastCode: Int) {
        let code: ErrorReport.Code
        switch loadedBridge?.failureCause ?? .page {
        case .page: code = .creativeFailed
        case .loadTimeout: code = .loadTimeout
        case .loadFailed: code = .frameLoadFailed
        case .processTerminated: code = .processTerminated
        }
        let recovery: ErrorReport.Recovery = wasShown ? .adEndedFailed : .adDroppedBeforeShow
        ErrorReporter.shared.report(code, stage: wasShown ? .playback : .load, sessionId: owner?.sessionId, adId: id, vastCode: vastCode,
                                    underlying: loadedBridge?.failureUnderlying, recovery: recovery)
    }
}
