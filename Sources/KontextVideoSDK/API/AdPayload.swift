import Foundation

/// One served ad as the wire sends it: everything the SDK needs to place, show, time and track it.
/// `VideoAd` is the public object built from it.
struct AdPayload: Decodable, Sendable {
    /// When the server meant the ad to be shown. Decoded so a timed-mode answer is still a valid ad; not
    /// acted on: the SDK has no timed mode yet, and the app picks every moment.
    enum Trigger: Sendable, Equatable {
        /// The app decides the moment.
        case manual
        /// Timed mode: meant for `from`…`to`, milliseconds in content time.
        case window(from: Int, to: Int)
    }

    /// What the page renders. The viewability clock (1 s for an image, 2 s for a video), the video events
    /// and the `complete` beacon depend on it.
    enum Creative: String, Decodable, Sendable {
        case image
        case video
    }

    enum Rendering: Sendable, Equatable {
        /// The page to show in a WebView.
        case frame(URL)
    }

    struct Price: Decodable, Sendable, Equatable {
        enum Precision: String, Decodable, Sendable {
            /// A DSP's clearing price.
            case exact
            /// Our own or house demand, a forecast.
            case estimated
        }

        /// Per 1,000 impressions.
        let value: Double
        /// ISO 4217.
        let currency: String
        let precision: Precision
    }

    /// One beacon of the ad. The SDK fires every entry once, when its moment happens; the page never does.
    struct TrackingEvent: Decodable, Sendable, Equatable {
        /// A VAST event name: `impression`, `creativeView`, `start`, `complete`, `close`, ... The SDK ignores names it does not know.
        let event: String
        let url: String
        /// `progress` only: milliseconds into the ad video at which to fire.
        let offset: Int?
        /// `endCard` for the linear ad's end card; `nil` for the main creative.
        let part: String?
    }

    /// The nominal box the creative was built for, in points; the VAST NonLinear attributes.
    struct Size: Decodable, Sendable, Equatable {
        let width: Int
        let height: Int
        let scalable: Bool
        let maintainAspectRatio: Bool
    }

    /// `sizes`, at least one entry, the first built for the request's player.
    private static func sizes(from container: KeyedDecodingContainer<CodingKeys>) throws -> [Size] {
        let sizes = try container.decode([Size].self, forKey: .sizes)
        guard !sizes.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sizes, in: container, debugDescription: "sizes must have at least one entry")
        }
        return sizes
    }

    struct Reward: Decodable, Sendable, Equatable {
        let label: String
        let amount: Double
    }

    /// What each format adds to the common fields.
    enum Details: Sendable, Equatable {
        /// `duration`: milliseconds to keep it on screen; absent, the overlay stays until the app ends it.
        /// `sizes`: every variant the creative carries
        /// assets for, at least one, the first built for the request's player; the SDK picks the best fit
        /// for the real box at show.
        case overlay(position: AdPosition, sizes: [Size], duration: Int?)
        /// `sizes` is empty for the fullscreen variant.
        case pause(position: PauseOptions.Position, sizes: [Size])
        /// `skipOffset`: milliseconds until the Close may appear; `nil` means no Close before complete.
        case linear(duration: Int, skipOffset: Int?, reward: Reward?)
    }

    let id: String
    /// The placement it was requested for.
    let placementId: String
    let format: AdFormat
    let creative: Creative
    let trigger: Trigger
    let price: Price
    /// Milliseconds from receipt.
    let expires: Int
    let rendering: Rendering
    let tracking: [TrackingEvent]
    let vastUrl: URL
    let details: Details

    private enum CodingKeys: String, CodingKey {
        case id, placementId, format, creative, trigger, price, expires, rendering, tracking, vastUrl
        case position, sizes, duration, skipOffset, reward
    }

    private enum TriggerKeys: String, CodingKey {
        case kind, from, to
    }

    private enum RenderingKeys: String, CodingKey {
        case kind, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        placementId = try container.decode(String.self, forKey: .placementId)
        format = try container.decode(AdFormat.self, forKey: .format)
        creative = try container.decode(Creative.self, forKey: .creative)
        price = try container.decode(Price.self, forKey: .price)
        expires = try container.decode(Int.self, forKey: .expires)
        tracking = try container.decode([TrackingEvent].self, forKey: .tracking)
        vastUrl = try container.decode(URL.self, forKey: .vastUrl)

        let trigger = try container.nestedContainer(keyedBy: TriggerKeys.self, forKey: .trigger)
        switch try trigger.decode(String.self, forKey: .kind) {
        case "manual":
            self.trigger = .manual
        case "window":
            self.trigger = .window(from: try trigger.decode(Int.self, forKey: .from), to: try trigger.decode(Int.self, forKey: .to))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: trigger, debugDescription: "unknown trigger kind \(kind)")
        }

        let rendering = try container.nestedContainer(keyedBy: RenderingKeys.self, forKey: .rendering)
        switch try rendering.decode(String.self, forKey: .kind) {
        case "frame":
            self.rendering = .frame(try rendering.decode(URL.self, forKey: .url))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: rendering, debugDescription: "unknown rendering kind \(kind)")
        }

        switch format {
        case .overlay:
            details = .overlay(
                position: try container.decode(AdPosition.self, forKey: .position),
                sizes: try Self.sizes(from: container),
                duration: try container.decodeIfPresent(Int.self, forKey: .duration)
            )
        case .pause:
            let position = try container.decode(PauseOptions.Position.self, forKey: .position)
            details = .pause(position: position, sizes: position == .fullscreen ? [] : try Self.sizes(from: container))
        case .linear:
            details = .linear(
                duration: try container.decode(Int.self, forKey: .duration),
                skipOffset: try container.decodeIfPresent(Int.self, forKey: .skipOffset),
                reward: try container.decodeIfPresent(Reward.self, forKey: .reward)
            )
        }
    }
}
