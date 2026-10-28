/// The ad server's error body (JSON:API-shaped, see the API's Common page). Each item's fields are
/// decoded leniently: a missing, null or wrongly typed field is `nil`, so an item with less than the
/// contract still reaches the log. The list itself is not: an entry that is not an object fails the
/// whole body, and the client then reports the HTTP status alone, which still decides everything. The
/// SDK acts on no code today; the item goes to the log as its `title`, else `detail`, else `code`.
struct ErrorResponse: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let status: String?
        let code: String?
        /// A short human-readable summary, for the log.
        let title: String?
        let detail: String?

        /// The item as one log phrase; `nil` when the server sent none of the three. The first one present
        /// wins even when it is empty, on purpose: the contract always sets `title`, so an empty one is a
        /// server bug, and `HTTP 400: ` in the log shows it where a quiet fallback to `detail` would hide it.
        /// The SDK decides nothing on this text; the status and the item stay intact for anyone reading.
        var summary: String? {
            title ?? detail ?? code
        }

        private enum CodingKeys: String, CodingKey {
            case status, code, title, detail
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            code = try? container.decodeIfPresent(String.self, forKey: .code)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        }
    }

    let errors: [Item]
}
