extension KontextVideo {
    /// What the publisher knows about the viewer. Every field is optional.
    public struct User: Encodable, Sendable, Equatable {
        public enum Gender: String, Encodable, Sendable {
            case male
            case female
            case other
        }

        /// The publisher's own unique identifier of the viewer.
        public let id: String?
        /// Plain email address, when the viewer's consent allows it.
        /// The server hashes it on arrival and never stores the plain address.
        public let email: String?
        /// SHA-256 of the normalized address (trimmed, lowercased, UTF-8), as 64 lowercase hex characters.
        /// When `email` is also set, the server uses `email` and ignores this.
        public let emailHash: String?
        /// For example `1994`.
        public let yearOfBirth: Int?
        public let gender: Gender?
        /// The viewer's interests, in the publisher's own words.
        public let keywords: [String]?

        public init(
            id: String? = nil,
            email: String? = nil,
            emailHash: String? = nil,
            yearOfBirth: Int? = nil,
            gender: Gender? = nil,
            keywords: [String]? = nil
        ) {
            self.id = id
            self.email = email
            self.emailHash = emailHash
            self.yearOfBirth = yearOfBirth
            self.gender = gender
            self.keywords = keywords
        }
    }
}
