extension KontextVideo {
    /// What the publisher knows about the viewer. Every field is optional. No demographics: OpenRTB 2.6
    /// and AdCOM deprecated `user.yob` and `user.gender`; `keywords` (OpenRTB `kwarray`) and the identity
    /// fields are what buyers still read.
    public struct User: Sendable, Equatable, Hashable {
        /// The publisher's own unique identifier of the viewer. Non-empty when set: an empty id is a
        /// programmer error, which stops a debug build, and is left out of the request.
        public let id: String?
        /// Plain email address, when the viewer's consent allows it. Sent as given; the SDK neither
        /// normalizes nor hashes it.
        public let email: String?
        /// A hash of the viewer's email address, sent as given. The SDK requires no particular hash
        /// function: SHA-256 of the trimmed, lowercased address is what we suggest, and we support the
        /// one you already use; tell us which. When `email` is set too, both are sent and the server
        /// matches on `email`.
        public let emailHash: String?
        /// The viewer's interests, in the publisher's own words.
        public let keywords: [String]?

        /// Set what you know; every field may stay `nil`.
        public init(
            id: String? = nil,
            email: String? = nil,
            emailHash: String? = nil,
            keywords: [String]? = nil
        ) {
            self.id = id
            self.email = email
            self.emailHash = emailHash
            self.keywords = keywords
        }

        /// The user without what identifies the viewer (id, email, email hash), for a COPPA request; `nil`
        /// when nothing else is left.
        var withoutIdentity: User? {
            keywords == nil ? nil : User(keywords: keywords)
        }

        /// Fields set to an empty string, which the request leaves out; an empty `id` is also an assertion.
        var emptyFields: [String] {
            [("id", id), ("email", email), ("emailHash", emailHash)].compactMap { $0.1?.isEmpty == true ? $0.0 : nil }
        }
    }
}
