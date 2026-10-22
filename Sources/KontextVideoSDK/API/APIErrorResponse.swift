import Foundation

/// The ad server's error body (JSON:API-shaped, see the API's Common page). Decoded leniently: every
/// field is optional and `code` reads `unknown` when absent, so a server that sends less than the
/// contract still gets its message into the log and never makes the SDK drop the whole body. The SDK
/// acts on no code today; `title` and `detail` go to the log.
struct APIErrorResponse: Decodable, Sendable {
    /// The codes the SDK knows. An open set: the server may add codes, which reach the log as they are.
    enum Code {
        /// The SDK's own stand-in for a missing or malformed `code`.
        static let unknown = "unknown"
    }

    struct Item: Decodable, Sendable {
        let status: String?
        let code: String
        /// A short human-readable summary, for the log.
        let title: String?
        let detail: String?

        private enum CodingKeys: String, CodingKey {
            case status, code, title, detail
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? Code.unknown
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        }
    }

    let errors: [Item]
}
