import Foundation
import KontextKit

/// `POST /init` — fired once at session creation, in the background.
///
/// Reports the app's SKAdNetwork IDs (from `Info.plist`, via KontextKit) so
/// the server can attribute installs from directly-served campaigns, and
/// lets the server override client defaults or disable the session. Never
/// throws and never blocks: any failure returns `nil` and the SDK keeps its
/// defaults.
struct InitService: Sendable {
    let adServerURL: URL

    struct InitRequest: Encodable {
        struct App: Encodable {
            let bundleId: String
            let version: String
        }
        struct Skan: Encodable {
            /// SKAdNetwork IDs from `Info.plist`; an empty array is a valid
            /// positive signal.
            let items: [String]
        }

        let publisherToken: String
        let userId: String
        let installId: String
        let sdk: SDKInfo
        let app: App
        let skan: Skan
    }

    struct InitResponse: Decodable {
        /// `false` = the server permanently disabled this session; stop
        /// requesting ads. Defaults to `true` when missing.
        let enabled: Bool
        /// Preload request timeout override, in milliseconds.
        let preloadTimeoutMs: Int?

        enum CodingKeys: String, CodingKey {
            case enabled
            case preloadTimeoutMs = "preloadTimeout"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
            preloadTimeoutMs = try? c.decodeIfPresent(Int.self, forKey: .preloadTimeoutMs)
        }
    }

    func fetchInit(_ body: InitRequest) async -> InitResponse? {
        var request = URLRequest(url: adServerURL.appendingPathComponent("init"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Constants.initTimeout
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let httpBody = try? encoder.encode(body) else { return nil }
        request.httpBody = httpBody
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(InitResponse.self, from: data)
    }
}
