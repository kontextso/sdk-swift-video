import Foundation

/// The ad server's error body (JSON:API-shaped, see the API's Common page). Decoded leniently: every
/// field is optional, so a server that sends less than the contract still gets its message into the
/// log and never makes the SDK drop the whole body. The SDK acts on no code today; the item goes to the
/// log as its `title`, else `detail`, else `code`.
struct APIErrorResponse: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let status: String?
        let code: String?
        /// A short human-readable summary, for the log.
        let title: String?
        let detail: String?

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

extension APIErrorResponse.Item {
    /// The item as one log phrase; `nil` when the server sent none of the three.
    var summary: String? {
        title ?? detail ?? code
    }
}
