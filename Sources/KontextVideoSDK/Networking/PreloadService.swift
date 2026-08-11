import Foundation

/// Everything the SDK knows about one starting video, sent to the server
/// to preload ads for all enabled formats.
struct PreloadRequest: Encodable, Sendable {
    let publisherToken: String
    let userId: String
    let userEmail: String?
    let installId: String
    let sessionId: String
    let externalId: String
    let title: String?
    let description: String?
    let enabledFormats: [VideoAdFormat]
    let sdk: SDKInfo
}

/// One preloaded ad. The `ad` payload shape is still being designed on the
/// server side; for now the SDK only consumes the format.
struct PreloadedAd: Decodable, Sendable {
    let format: VideoAdFormat
}

struct PreloadResponse: Decodable, Sendable {
    let sessionId: String?
    let ads: [PreloadedAd]
}

/// Calls the ad server's video preload endpoint.
///
/// The endpoint is tentative (`/preload`, per the design doc) and does not
/// exist on the server yet — until it does, every call fails and the
/// session reports it as a `.error` event. The request/response shapes
/// here are the SDK-side sketch of the contract.
struct PreloadService: Sendable {
    let adServerURL: URL

    func preload(_ request: PreloadRequest) async throws -> PreloadResponse {
        var urlRequest = URLRequest(url: adServerURL.appendingPathComponent("preload"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = Constants.preloadTimeout
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(PreloadResponse.self, from: data)
    }
}
