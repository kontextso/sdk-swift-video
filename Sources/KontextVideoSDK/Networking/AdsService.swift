import Foundation

/// One preloaded instream ad, parsed from a `/instream/vmap` (aka `/v1/ads`)
/// ad break.
public struct InstreamAd: Sendable {
    /// Slot index within the video (0-based).
    public let index: Int
    /// When the ad should appear, in content time.
    public let startMs: Int
    /// When the ad should be dismissed, in content time.
    public let endMs: Int?
    /// `top` or `bottom` overlay position.
    public let position: String?
    public let bidId: String
    /// The render-ready JSON creative (`/api/frame/{bidId}?format=json`).
    /// May 404 for a few seconds after the ads request — ad copy is written
    /// asynchronously on the server.
    public let adJsonURL: URL?
    public let width: Int?
    public let height: Int?
    /// Server-assigned viewing-session ID carried in the kontext:Overlay
    /// extension.
    public let sessionId: String?
}

/// Minimal render-ready creative, decoded from the ad's JSON endpoint.
public struct InstreamAdCreative: Sendable, Decodable {
    public struct Image: Sendable, Decodable {
        public let url: String
        public let w: Int
        public let h: Int
    }

    public struct CTA: Sendable, Decodable {
        public let text: String
        public let mode: String
        public let url: String
    }

    public let image: Image
    public let headline: String
    public let body: String
    public let cta: CTA
}

struct InstreamAdJson: Decodable {
    let format: String
    let bidId: String
    let creative: InstreamAdCreative

    enum CodingKeys: String, CodingKey {
        case format
        case bidId = "bid_id"
        case creative
    }
}

/// Calls the existing ad-server ads endpoint: `GET /instream/vmap` on the ad
/// server's own domain (the same route partners call as `GET /v1/ads` on
/// their tenant hostnames). Returns all ads for the whole video in one
/// response, as VMAP 1.0 XML, which this service parses into `InstreamAd`s.
///
/// Today the endpoint only supports pre-analyzed videos: `titleId` is the
/// Kontext-minted id from `POST /v1/upload`, not the publisher's own video id.
struct AdsService: Sendable {
    let adServerURL: URL

    struct HTTPError: Error {
        let statusCode: Int
    }

    func fetchAds(
        publisherToken: String,
        titleId: String,
        userId: String,
        playerSize: (width: Int, height: Int)?,
        maxSlots: Int?
    ) async throws -> [InstreamAd] {
        var components = URLComponents(
            url: adServerURL.appendingPathComponent("instream/vmap"),
            resolvingAgainstBaseURL: false
        )!
        var items = [
            URLQueryItem(name: "token", value: publisherToken),
            URLQueryItem(name: "title_id", value: titleId),
            URLQueryItem(name: "user_id", value: userId),
            URLQueryItem(name: "cta_mode", value: "button"),
        ]
        if let playerSize {
            items.append(URLQueryItem(name: "sz", value: "\(playerSize.width)x\(playerSize.height)"))
        }
        if let maxSlots {
            items.append(URLQueryItem(name: "max_slots", value: String(maxSlots)))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Constants.preloadTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return VMAPParser.parse(data)
    }

    func fetchCreative(adJsonURL: URL) async throws -> InstreamAdJson {
        var request = URLRequest(url: adJsonURL)
        request.timeoutInterval = Constants.preloadTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(InstreamAdJson.self, from: data)
    }
}
