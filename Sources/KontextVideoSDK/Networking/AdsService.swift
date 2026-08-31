import Foundation

/// `POST /instream/preload` — one call per video, returns every ad prepared
/// for it. Wire format is snake_case, the ad server's `/instream/*`
/// vocabulary; the endpoint itself is being designed against the mock
/// server (github.com/kontextso/sdk-video-mock-server).
struct AdsService: Sendable {
    let adServerURL: URL

    struct HTTPError: Error {
        let statusCode: Int
    }

    struct PreloadRequest: Encodable {
        struct Context: Encodable {
            let playerWidth: Int?
            let playerHeight: Int?
        }

        let publisherToken: String
        let userId: String
        let userEmail: String?
        let sessionId: String?
        /// The publisher's unique video id.
        let id: String
        let title: String?
        let description: String?
        let durationMs: Int?
        let language: String?
        let episodeNumber: Int?
        let series: VideoSeries?
        let formats: [VideoAdFormat]
        let context: Context?
        let sdk: SDKInfo
    }

    struct PreloadResponse: Decodable {
        struct FormatResult: Decodable {
            let format: String
            let noFillReason: String?
        }

        let sessionId: String?
        let ads: [VideoAd]
        let results: [FormatResult]?
        let noFillReason: String?
        let nextRequestAt: String?

        enum CodingKeys: String, CodingKey {
            case sessionId, ads, results, noFillReason, nextRequestAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
            results = try c.decodeIfPresent([FormatResult].self, forKey: .results)
            noFillReason = try c.decodeIfPresent(String.self, forKey: .noFillReason)
            nextRequestAt = try c.decodeIfPresent(String.self, forKey: .nextRequestAt)
            // Lossy: one malformed ad must not throw away the rest of the fill.
            var list: [VideoAd] = []
            if var arr = try? c.nestedUnkeyedContainer(forKey: .ads) {
                while !arr.isAtEnd {
                    if let ad = try? arr.decode(VideoAd.self) {
                        list.append(ad)
                    } else {
                        _ = try? arr.decode(AnyDecodable.self)   // skip the bad element
                    }
                }
            }
            ads = list
        }
    }

    /// Consumes one element of an unkeyed container to advance past it.
    private struct AnyDecodable: Decodable {}

    func preload(_ body: PreloadRequest) async throws -> PreloadResponse {
        var request = URLRequest(url: adServerURL.appendingPathComponent("instream/preload"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = Constants.preloadTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PreloadResponse.self, from: data)
    }
}
