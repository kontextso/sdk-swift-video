/// The value types of a `VideoAd`: what the app reads before deciding (`Price`), what it passes back
/// (`RejectReason`), what it finds out (`InvalidationReason`), and the SDK's own view of where the ad goes
/// (`Size`, `Position`). The delegate's types, `Click` and `EndReason`, live with the delegate.
extension VideoAd {
    /// What an ad pays: a CPM in a currency, and whether that figure is a clearing price or a forecast.
    public struct Price: Sendable, Equatable {
        /// How firm `value` is.
        public enum Precision: Sendable {
            /// A DSP's clearing price.
            case exact
            /// Our own or house demand, a forecast.
            case estimated
        }

        /// Per 1,000 impressions.
        public let value: Double
        /// ISO 4217.
        public let currency: String
        /// Whether `value` is a DSP's clearing price or a forecast.
        public let precision: Precision
    }

    /// The box a creative was built for, in points. The SDK scales it down to 50 % of this when the view
    /// is smaller, and refuses to show below that. Internal: where and how big is the SDK's business.
    struct Size: Sendable, Equatable {
        let width: Int
        let height: Int
        /// `false`: built for exactly this size, never shown smaller.
        var scalable = true
    }

    /// Where the server placed the ad.
    enum Position: Sendable, Equatable {
        case top
        case bottom
        case fullscreen
    }

    /// Why the app did not use an ad; the server tells the DSP.
    public enum RejectReason: Sendable, Equatable {
        /// The app does not use it, for any reason: the moment passed, the viewer left, the app's own choice.
        case notUsed
        /// Another network won the publisher's auction; `winningPrice` (CPM) and `winner` (the network, in
        /// the app's own words) when the app knows them. DSPs use both.
        case outbid(winningPrice: Double? = nil, winner: String? = nil)
    }

    /// Why an ad ended before it was shown. Found out at the next call (`format`, `load`, `show`,
    /// `reject`), which throws it; nothing is delivered through the delegate.
    public enum InvalidationReason: Sendable, Equatable {
        /// The ad's lifetime ran out (or the server replaced it, which it does only after that).
        case expired
        /// The app called `reject()`.
        case rejected
        /// The `VideoAds` was destroyed.
        case destroyed
        /// The creative failed to load, or died while the ad waited to be shown (for example the web
        /// content process was terminated). `code` is the VAST error code the SDK fired.
        case creativeFailed(code: Int)
    }
}
