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
        let externalId: String
        let title: String?
        let description: String?
        let formats: [VideoAdFormat]
        let context: Context?
        let sdk: SDKInfo
    }

    struct PreloadResponse: Decodable {
        let sessionId: String?
        let ads: [VideoAd]
        let noFillReason: String?
        let nextRequestAt: String?
    }

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
