// The viewer as the app describes them (`KontextVideo.User`): a public value only. How it goes on the wire, and
// what a COPPA request leaves out, is `Payloads/AppInputs.swift`; `IntegrationGuard.checkUser` says what is empty.

extension KontextVideo {
    /// What the publisher knows about the viewer. `id` is required: the server keys its frequency caps and
    /// reports on it, so no ads request leaves without a user. No demographics: OpenRTB 2.6 and AdCOM deprecated
    /// `user.yob` and `user.gender`; `keywords` (OpenRTB `kwarray`) and the identity fields are what buyers still read.
    public struct User: Sendable, Equatable, Hashable {
        /// The publisher's own unique identifier of the viewer: the account id once they signed in, or a guest
        /// id the app keeps for the install before that. Required and non-empty: an empty id is a programmer
        /// error, which stops a debug build, and no ads request is sent with it. Sent for a child too (COPPA):
        /// the server keeps it from buyers.
        public let id: String
        /// Plain email address, when the viewer's consent allows it. Sent as given; the SDK neither
        /// normalizes nor hashes it. Never sent for a child (COPPA).
        public let email: String?
        /// A hash of the viewer's email address, sent as given. The SDK requires no particular hash
        /// function: SHA-256 of the trimmed, lowercased address is what we suggest, and we support the
        /// one you already use; tell us which. When `email` is set too, both are sent and the server
        /// matches on `email`. Never sent for a child (COPPA).
        public let emailHash: String?
        /// The viewer's interests, in the publisher's own words.
        public let keywords: [String]?

        /// `id` is required; set what else you know.
        public init(
            id: String,
            email: String? = nil,
            emailHash: String? = nil,
            keywords: [String]? = nil
        ) {
            self.id = id
            self.email = email
            self.emailHash = emailHash
            self.keywords = keywords
        }
    }
}
