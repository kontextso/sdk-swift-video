extension KontextVideo {
    /// What the publisher knows about the viewer. Every field is optional. No demographics: OpenRTB 2.6
    /// and AdCOM deprecated `user.yob` and `user.gender`, and AdMob and MAX dropped them from their
    /// requests; `keywords` (OpenRTB `kwarray`) and the identity fields are what buyers still read.
    public struct User: Encodable, Sendable, Equatable {
        /// The publisher's own unique identifier of the viewer.
        public let id: String?
        /// Plain email address, when the viewer's consent allows it.
        /// The server hashes it on arrival and never stores the plain address.
        public let email: String?
        /// SHA-256 of the normalized address (trimmed, lowercased, UTF-8), as 64 lowercase hex characters.
        /// When `email` is also set, the server uses `email` and ignores this.
        public let emailHash: String?
        /// The viewer's interests, in the publisher's own words.
        public let keywords: [String]?

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
    }
}
