extension KontextVideo {
    /// Privacy and consent signals sent with every ads request.
    ///
    /// Except for `coppa`, the SDK reads these from the consent management platform's shared storage
    /// (the IAB keys in `UserDefaults`); the CMP's values are the live consent and win. A value set here
    /// fills in what the CMP did not write, for an app without an IAB-writing CMP.
    public struct Regulatory: Encodable, Sendable, Equatable {
        /// Whether the request is subject to GDPR.
        public let gdpr: Bool?
        /// The IAB Transparency and Consent Framework consent string.
        public let gdprConsent: String?
        /// Whether the request is subject to COPPA. Cannot be read from the device, so the publisher sets it.
        public let coppa: Bool?
        /// The IAB Global Privacy Platform consent string.
        public let gpp: String?
        /// The sections of the GPP string that apply to this request.
        public let gppSid: [Int]?
        /// The legacy IAB US Privacy (CCPA) string. Some DSPs still read it.
        public let usPrivacy: String?

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
