/// What one `VideoAds` holds: its unshown ad of each format, the ids that left, and its ad on screen; and what an
/// ads answer does to them, as a plan of steps over plain values.
///
/// Why a plan: the server owns the bids, and the SDK follows each answer. Which bid stays, which is replaced, and
/// why a format answers no-fill is a decision over ids alone; `plan(_:)` makes it with no side effect, so it reads
/// as a table, and `VideoAds` carries the steps out (ending the ads that leave, making the new ones).
///
/// ```
///   held   the answer for its format      steps
///   none   ad X                           replace X
///   X      ad X (re-served)               keep (the payload is ignored)
///   X      ad Y                           drop X, replace Y
///   X      no-fill R                      drop X, no-fill R
///   X      ad Y, Y already used           drop X, ignore Y (no-fill alreadyUsed)
///   none   left out                       left out (no-fill unknown)
///   X      left out                       keep
/// ```
///
/// A held ad that expired leaves before the plan, silently, whatever the answer says. `VideoAds` holds one
/// `AdStore`, and `AdsFetcher` reads the held ids from it for the request.
@MainActor
struct AdStore {
    /// One step of an answer, for one format.
    enum Step {
        /// The held ad stays as it is.
        case keep(AdFormat)
        /// A new ad for the format, from this payload.
        case replace(AdFormat, AdPayload)
        /// The held ad leaves: replaced, or the format has no fill now.
        case drop(AdFormat)
        /// The server answered the format with no fill, for this reason.
        case noFill(AdFormat, VideoAdError.NoFillReason)
        /// The answer left the format out and nothing is held: a no-fill, reason unknown.
        case leftOut(AdFormat)
        /// The answer brings an ad already shown or rejected (the request listed it before the app used it):
        /// ignored, a no-fill `alreadyUsed`.
        case ignoreUsed(AdFormat, id: String)
    }

    /// The unshown ad of each format, at most one.
    var ads: [AdFormat: VideoAd] = [:]
    /// Ids that left: shown, rejected, expired, failed, destroyed. An answer that brings one back is ignored for its
    /// format: the request listed the ad before the app used it.
    var spentIds: Set<String> = []
    /// The ad of this `VideoAds` on screen. `ScreenSlot` retains it too.
    var showing: VideoAd?

    /// The steps `response` takes, for every format, from what is held now.
    func plan(_ response: AdsResponse) -> [Step] {
        Self.plan(response, held: ads.mapValues(\.id), spent: spentIds)
    }

    /// The same over plain values: `held` the id held per format, `spent` the ids that left.
    nonisolated static func plan(_ response: AdsResponse, held: [AdFormat: String], spent: Set<String>) -> [Step] {
        var steps: [Step] = []
        for format in AdFormat.allCases {
            let current = held[format]
            guard let result = response.result(for: format) else {
                // A format the answer leaves out decides nothing: its held ad stays, until its own expiry.
                steps.append(current == nil ? .leftOut(format) : .keep(format))
                continue
            }
            guard let ad = result.ads.first else {
                if current != nil { steps.append(.drop(format)) }
                steps.append(.noFill(format, result.noFillReason ?? .unknown))
                continue
            }
            // Re-served (and valid: the expired left before): kept unchanged, the payload is ignored.
            if current == ad.id {
                steps.append(.keep(format))
                continue
            }
            // Replaced, no longer served, or re-served after it expired: it never comes back.
            if current != nil { steps.append(.drop(format)) }
            steps.append(spent.contains(ad.id) ? .ignoreUsed(format, id: ad.id) : .replace(format, ad))
        }
        return steps
    }
}
