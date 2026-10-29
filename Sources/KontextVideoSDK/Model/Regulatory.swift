extension KontextVideo {
    /// Privacy and consent signals sent with every ads request.
    ///
    /// Except for `coppa`, the SDK reads these from the consent management platform's shared storage
    /// (the IAB keys in `UserDefaults`); a usable CMP value is the live consent and wins. A value set here
    /// fills in where the CMP has none usable (a key it did not write, an empty or malformed one), for an
    /// app without an IAB-writing CMP. The SDK carries the signals and interprets none: a `gpp` and `gppSid`
    /// set here must describe the same context. `nil` everywhere means unknown, never `false`.
    public struct Regulatory: Encodable, Sendable, Equatable {
        /// Whether the request is subject to GDPR; `nil` is unknown, which is not the same as `false`.
        public let gdpr: Bool?
        /// The IAB Transparency and Consent Framework consent string.
        public let gdprConsent: String?
        /// Whether the request is subject to COPPA; `nil` is unspecified, not `false`. Cannot be read from
        /// the device, so only the publisher sets it.
        public let coppa: Bool?
        /// The IAB Global Privacy Platform consent string.
        public let gpp: String?
        /// The sections of the GPP string that apply to this request.
        public let gppSid: [Int]?
        /// The legacy IAB US Privacy (CCPA) string. Some DSPs still read it.
        public let usPrivacy: String?

        /// Set only what your consent platform did not write; `coppa` can only come from you.
        public init(
            gdpr: Bool? = nil,
            gdprConsent: String? = nil,
            coppa: Bool? = nil,
            gpp: String? = nil,
            gppSid: [Int]? = nil,
            usPrivacy: String? = nil
        ) {
            self.gdpr = gdpr
            self.gdprConsent = gdprConsent
            self.coppa = coppa
            self.gpp = gpp
            self.gppSid = gppSid
            self.usPrivacy = usPrivacy
        }
    }
}
