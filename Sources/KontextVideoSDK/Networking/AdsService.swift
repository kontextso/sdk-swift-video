import Foundation

/// `POST /preload` — one call per video, returns every ad prepared for it.
///
/// The endpoint is being designed against the mock server
/// (github.com/kontextso/sdk-video-mock-server); the real ad server does not
/// implement it yet.
struct AdsService: Sendable {
    let adServerURL: URL

    struct HTTPError: Error {
        let statusCode: Int
    }

    struct PreloadRequest: Encodable {
        let publisherToken: String
        let userId: String
        let userEmail: String?
        let sessionId: String?
        let externalId: String
        let title: String?
        let description: String?
        let enabledFormats: [VideoAdFormat]
        let sdk: SDKInfo
    }

    struct PreloadResponse: Decodable {
        let sessionId: String?
        let ads: [VideoAd]
    }

    func preload(_ body: PreloadRequest) async throws -> PreloadResponse {
        var request = URLRequest(url: adServerURL.appendingPathComponent("preload"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = Constants.preloadTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(PreloadResponse.self, from: data)
    }
}
